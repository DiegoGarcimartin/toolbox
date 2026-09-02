#!/bin/bash
# limit-resume-concierge — deterministic sweep, run by launchd every 5 minutes.
#
# No LLM, no desktop app in the loop: reads the manifest the StopFailure hook
# writes, resumes each interrupted session headless (claude --resume -p) and
# removes its lines. An empty manifest exits immediately: idle ticks are free.
#
# The manifest holds one line per interrupted main session and one line per
# interrupted subagent (same session_id as its parent, plus agent_id). Lines
# are grouped by session: the parent is resumed ONCE, with a message that
# lists the subagents killed by the limit — they never resume on their own,
# only the parent can re-drive them (SendMessage to the agentId, or relaunch).
#
# Crash-safe like the v1 skill: a session's lines are removed right after its
# resume is LAUNCHED — never all at once at the end.
set -u
MANIFEST="$HOME/.claude/limit-interrupted.jsonl"
LOCK="$HOME/.claude/limit-resume-concierge.lock"
SWEEPLOG="$HOME/.claude/concierge-sweep.log"
MSG="[Automatic message from the limit concierge] The usage limit has recovered. Continue exactly where you left off with the task you had in progress when the limit hit. If nothing was in progress, reply briefly that there is nothing pending and do nothing else."

[ -s "$MANIFEST" ] || exit 0

log() { echo "$(date -Iseconds) $*" >> "$SWEEPLOG"; }

# Single-instance guard. A sweep takes seconds (resumes are launched detached),
# so a lock older than 10 min is a crash/reboot leftover: clear it instead of
# skipping every tick forever.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null && log "cleared stale lock left by an interrupted sweep"
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "another sweep is still running; skipping this tick"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

command -v claude >/dev/null || { log "claude CLI not on PATH; cannot sweep"; exit 1; }
command -v jq >/dev/null     || { log "jq not on PATH; cannot sweep"; exit 1; }

# test- entries never resume; drop them before any quota gating.
if grep -q '"session_id":"test-' "$MANIFEST" 2>/dev/null; then
  grep -v '"session_id":"test-' "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"
  log "dropped test entries"
  [ -s "$MANIFEST" ] || { log "manifest empty after test cleanup"; exit 0; }
fi

# ISO-8601 → epoch, BSD date (macOS) first, GNU date (Linux) as fallback.
# Accepts "2026-09-02T19:02:27+02:00" and "2026-09-02T17:55:35.790Z".
to_epoch() {
  local s e=""
  s=$(echo "$1" | sed -E 's/\.[0-9]+//')
  case "$s" in
    *Z) e=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${s%Z}" +%s 2>/dev/null) ;;
    *)  s=$(echo "$s" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
        e=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$s" +%s 2>/dev/null) ;;
  esac
  [ -n "$e" ] || e=$(date -d "$1" +%s 2>/dev/null)
  echo "$e"
}

# If the manifest carries a reset time that is still in the future, don't even
# probe: quota is known to be exhausted until then. (Free early exit.) Only
# trusted up to 5h ahead — the limit window is 5h, so anything further is a
# mis-parsed timezone and would wrongly hold every pending session.
latest_reset=$(jq -rs '[.[] | .resets_at // empty] | max // empty' "$MANIFEST" 2>/dev/null)
if [ -n "$latest_reset" ]; then
  reset_epoch=$(to_epoch "$latest_reset")
  now=$(date +%s)
  if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$now" ] && [ $((reset_epoch - now)) -le 18000 ]; then
    log "reset expected at $latest_reset; waiting"
    exit 0
  fi
fi

# Quota probe: one minimal headless call. While the limit is active this call
# is rejected (and costs nothing); the sweep retries on the next tick.
# The prompt carries a marker so the StopFailure hook never records the probe
# itself. CONCIERGE_TEST_PROBE lets tests inject a canned probe result.
probe=${CONCIERGE_TEST_PROBE:-$(claude -p "[limit-resume-concierge probe] Reply with exactly: ok" --output-format json 2>/dev/null | tail -1)}
AUTH_MARK="$HOME/.claude/concierge-auth-alerted"
if ! echo "$probe" | jq -e '.is_error == false' >/dev/null 2>&1; then
  # A logged-out CLI rejects the probe exactly like an exhausted quota, but no
  # amount of waiting fixes it — tell the user once instead of retrying silently.
  if echo "$probe" | jq -r '.result // empty' 2>/dev/null | grep -qiE 'authenticat|oauth|api key'; then
    log "CLI logged out, not a quota wait: $(echo "$probe" | jq -r '.result')"
    if [ ! -e "$AUTH_MARK" ]; then
      : > "$AUTH_MARK"
      osascript -e 'display notification "The claude CLI is logged out; interrupted sessions cannot resume. Run claude in a terminal and /login once." with title "limit-resume-concierge"' 2>/dev/null
    fi
  else
    log "quota not back yet (probe rejected); will retry next tick"
  fi
  exit 0
fi
rm -f "$AUTH_MARK"

# Last thing a subagent said before dying (its transcript persists after the
# agent ends). One line, capped, so the parent can recognise where it was. The
# limit message itself ("You've hit your session limit · resets 7:40pm") is
# written to the agent transcript as its final assistant text: skip it.
agent_last_line() {
  [ -f "$1" ] || { echo "(transcript not found)"; return; }
  tail -n 300 "$1" | jq -r '
    select(.type == "assistant" and .message.content != null) | .message.content
    | if type == "array" then map(select(.type == "text") | .text) | join(" ") else tostring end' 2>/dev/null \
    | grep -v '^$' | grep -viE "hit your .*limit|usage limit|resets? (at )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)" \
    | tail -1 | tr '\n' ' ' | cut -c1-240
}

# Build the resume message for one session from its manifest lines ($1 = the
# lines, newline-separated). Main-session-only → the legacy message, verbatim.
# With subagents → the list, plus the legacy sentence when the parent died too.
build_message() {
  local lines="$1" parent_dead agents n
  parent_dead=$(echo "$lines" | jq -r 'select((.agent_id // "") == "") | .session_id' 2>/dev/null | head -1)
  agents=$(echo "$lines" | jq -r 'select((.agent_id // "") != "") | .agent_id' 2>/dev/null)
  if [ -z "$agents" ]; then echo "$MSG"; return; fi

  n=$(echo "$agents" | grep -c .)
  local out="[Automatic message from the limit concierge] Resuming after the usage limit."
  [ -n "$parent_dead" ] && out="$out Continue exactly where you left off with the task you had in progress when the limit hit."
  out="$out The following $n subagent(s) of this session were killed by the limit (HTTP 429) and do NOT resume on their own:"
  local aid atype adesc atp last
  while IFS= read -r aid; do
    [ -n "$aid" ] || continue
    atype=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_type // "agent"' 2>/dev/null | head -1)
    adesc=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_description // empty' 2>/dev/null | head -1)
    atp=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_transcript // empty' 2>/dev/null | head -1)
    last=$(agent_last_line "$atp" | tr '"' "'")
    adesc=$(echo "$adesc" | tr '"' "'")
    out="$out
- agentId $aid ($atype${adesc:+, \"$adesc\"}) — last line before dying: \"${last:-(no text yet)}\"${atp:+ — transcript: $atp}"
  done <<< "$agents"
  out="$out
For each of them: check its transcript first — if it already finished or was already resumed, leave it alone. Otherwise re-send it its last instruction with SendMessage to its agentId, or relaunch it. If any of them left an iOS simulator booted (xcrun simctl list devices booted), shut it down and delete it before relaunching. Then continue with the task in progress."
  echo "$out"
}

# The desktop app can revive an interrupted session by itself once the limit
# resets (it appends a synthetic "Continue from where you left off." turn with
# entrypoint claude-desktop). Resuming that session headless on top of it runs
# the same work twice on the same transcript (seen live on 2026-09-02). If the
# parent transcript shows such a revival AFTER the limit hit, skip our resume:
# that live session already holds the subagents' failure notifications.
app_revived_at() {  # $1 = transcript, $2 = epoch of the latest limit hit; prints the revival timestamp or nothing
  [ -f "$1" ] || return 0
  local cut="$2" ts e
  [ -n "$cut" ] || return 0
  ts=$(grep '"entrypoint":"claude-desktop"' "$1" | grep '"isMeta":true' | grep 'Continue from where you left off' \
    | grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4)
  [ -n "$ts" ] || return 0
  e=$(to_epoch "$ts"); [ -n "$e" ] || return 0
  [ "$e" -gt "$cut" ] && echo "$ts"
  return 0
}

# Sweep: up to 5 sessions per pass (self-guard and dedupe already happen in
# the StopFailure hook; test- entries are dropped here without resuming).
# Order per session: launch the resume, THEN remove its lines — if the script
# dies mid-pass, everything already delivered is clean and won't be re-sent.
# $2 is the head line being processed: if the literal match fails to remove it
# (non-compact JSON, e.g. hand-edited), drop it by position so the loop can't spin.
drop_sid() {
  grep -vF "\"session_id\":\"$1\"" "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"
  if [ "$(head -n1 "$MANIFEST" 2>/dev/null)" = "$2" ]; then
    tail -n +2 "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"
    log "dropped head line by position (literal match failed for $1)"
  fi
}

processed=0; iterations=0
while [ "$processed" -lt 5 ]; do
  iterations=$((iterations+1))
  if [ "$iterations" -gt 50 ]; then log "loop guard tripped; leaving the rest for the next tick"; break; fi
  line=$(head -n1 "$MANIFEST" 2>/dev/null)
  [ -n "$line" ] || break
  sid=$(echo "$line" | jq -r '.session_id // empty' 2>/dev/null)

  if [ -z "$sid" ]; then
    tail -n +2 "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"
    log "dropped malformed manifest line"
    continue
  fi
  case "$sid" in test-*) drop_sid "$sid" "$line"; log "dropped test entry $sid"; continue;; esac

  # All lines of this session: the main-session line (if it died) and one per
  # dead subagent. cwd: the main-session line's, else the first line's (the
  # hook already rewrote a subagent line's cwd to the parent's when it could).
  # (normalised through jq so one unparsable line cannot abort the group's jq calls)
  lines=$(grep -F "\"session_id\":\"$sid\"" "$MANIFEST" | jq -Rc 'fromjson? | select(type == "object")' 2>/dev/null)
  dir=$(echo "$lines" | jq -r 'select((.agent_id // "") == "") | .cwd // empty' 2>/dev/null | head -1)
  [ -n "$dir" ] || dir=$(echo "$lines" | jq -r '.cwd // empty' 2>/dev/null | head -1)
  tp=$(echo "$lines" | jq -r '.transcript_path // empty' 2>/dev/null | head -1)
  agents=$(echo "$lines" | jq -r 'select((.agent_id // "") != "") | .agent_id' 2>/dev/null | tr '\n' ' ')
  # Latest limit hit in the group, as an epoch: a fresh death must never be
  # hidden behind an older app revival.
  latest_hit=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    e=$(to_epoch "$l"); [ -n "$e" ] || continue
    [ -z "$latest_hit" ] || [ "$e" -gt "$latest_hit" ] && latest_hit="$e"
  done <<< "$(echo "$lines" | jq -r '.logged_at // empty' 2>/dev/null)"

  revived=$(app_revived_at "$tp" "$latest_hit")
  if [ -n "$revived" ]; then
    log "skipping $sid: the desktop app already revived it at $revived${agents:+ (dead subagents left to that live session: $agents)}"
    drop_sid "$sid" "$line"
    continue
  fi

  msg=$(build_message "$lines")
  log "resuming $sid (cwd: $dir)${agents:+ with dead subagents: $agents}"
  "$HOME/.claude/hooks/concierge-resume.sh" "$sid" "$dir" "$msg"
  drop_sid "$sid" "$line"
  processed=$((processed+1))
done

left=$(grep -c . "$MANIFEST" 2>/dev/null); left=${left:-0}
log "sweep done: $processed resumed, $left pending"
exit 0
