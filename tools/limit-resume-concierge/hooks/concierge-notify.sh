#!/bin/bash
# limit-resume-concierge — post a message into a LIVE session (v3).
# Usage: concierge-notify.sh <session-uuid> <message>
#
# A session that is still open in the desktop app (or in a terminal) must not
# be resumed headless: `claude --resume -p` would run a second copy of the same
# conversation, invisible to the live one (seen on 2026-09-07: the copy
# relaunched the dead subagents, hit the 10-minute headless ceiling and was
# killed; the live session learnt nothing until the owner typed at 08:30).
#
# Instead we post into the live session's inbox socket — the documented path
# for "a script or hook to post into a session" (docs: cross-session-messaging,
# "The session's inbox socket"). Each session registers itself in
# ~/.claude/sessions/<pid>.json with its sessionId, pid, procStart and
# messagingSocketPath. The wire format is one JSON line per message, the same
# shape Claude Code itself prints in its debug log:
#   {"type":"user","message":{"role":"user","content":"..."}}
# On macOS/Linux the auth line is optional, so a launchd script needs no token.
# When the session is idle, Claude Code starts a new turn with the message.
#
# Exit codes: 0 delivered · 2 session not alive (no registration, dead pid or
# no socket) · 3 socket write failed (the sweep then falls back to a resume).
set -u
sid="$1"; msg="$2"
SESSIONS="$HOME/.claude/sessions"

reg=$(grep -lF "\"sessionId\":\"$sid\"" "$SESSIONS"/*.json 2>/dev/null | head -1)
[ -n "$reg" ] || exit 2
pid=$(jq -r '.pid // empty' "$reg" 2>/dev/null)
sock=$(jq -r '.messagingSocketPath // empty' "$reg" 2>/dev/null)
pstart=$(jq -r '.procStart // empty' "$reg" 2>/dev/null)
[ -n "$pid" ] && [ -n "$sock" ] || exit 2

# Alive = the registered pid is a running claude process. When the registry
# recorded the process start time, require it to match too (pid reuse guard).
# The registry writes procStart in UTC ("Mon Sep  7 10:04:32 2026") while
# `ps -o lstart` prints local time, so both go through epoch (±2 s slack).
comm=$(ps -p "$pid" -o comm= 2>/dev/null)
case "$comm" in *claude*) ;; *) exit 2;; esac
to_epoch_ctime() {  # $1 = ctime-style stamp, $2 = TZ for parsing ("" = local)
  local s; s=$(echo "$1" | sed -E 's/^ +//; s/ +$//; s/ +/ /g')
  if [ -n "$2" ]; then TZ="$2" date -j -f "%a %b %d %H:%M:%S %Y" "$s" +%s 2>/dev/null \
    || TZ="$2" date -d "$s" +%s 2>/dev/null
  else date -j -f "%a %b %d %H:%M:%S %Y" "$s" +%s 2>/dev/null \
    || date -d "$s" +%s 2>/dev/null; fi
}
if [ -n "$pstart" ]; then
  want=$(to_epoch_ctime "$pstart" UTC)
  have=$(to_epoch_ctime "$(ps -p "$pid" -o lstart= 2>/dev/null)" "")
  if [ -n "$want" ] && [ -n "$have" ]; then
    d=$((want - have)); [ "${d#-}" -le 2 ] || exit 2
  fi
fi
[ -S "$sock" ] || exit 2

line=$(jq -cn --arg m "$msg" '{type:"user",message:{role:"user",content:$m}}')
# nc: connect, write the line, wait briefly for the peer to close, exit.
# The EXIT STATUS decides: macOS nc prints NOTHING when a UNIX socket refuses
# the connection (a session that died leaving its registration and socket file
# behind), it only exits non-zero — trusting the error text alone reported a
# stale socket as delivered and the session was never woken. The text match
# stays for the cases where nc does complain while still exiting 0.
err=$(printf '%s\n' "$line" | nc -U -w 5 "$sock" 2>&1 >/dev/null) || exit 3
case "$err" in
  *"refused"*|*"No such file"*|*"Operation timed out"*|*"failed"*) exit 3;;
esac
exit 0
