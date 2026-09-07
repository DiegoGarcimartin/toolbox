#!/bin/bash
# limit-resume-concierge — deterministic sweep, run by launchd every 5 minutes.
#
# No LLM, no desktop app in the loop: reads the manifests the StopFailure hook
# writes, wakes each interrupted session and removes its lines. An empty
# manifest exits immediately: idle ticks are free.
#
# Two manifests (v3):
#   ~/.claude/limit-interrupted.jsonl         one line per interrupted MAIN session
#   ~/.claude/limit-interrupted-agents.jsonl  one line per SUBAGENT killed by the
#                                             limit, under its parent's session_id
# Lines are grouped by session: each parent is woken ONCE, with a message that
# lists the subagents killed by the limit — they never resume on their own,
# only the parent can re-drive them (relaunch from the same worktree, or
# SendMessage to the agentId).
#
# How a session is woken depends on whether it is still ALIVE:
#   alive (registered in ~/.claude/sessions/, process running, inbox socket)
#     → the message is POSTED INTO the live session over its inbox socket
#       (hooks/concierge-notify.sh); when the session is idle, Claude Code
#       starts a new turn with it. A live session is never resumed headless:
#       that ran a second, invisible copy of the conversation (2026-09-07).
#   dead
#     → claude --resume <uuid> -p "<message>" from the session's own cwd,
#       detached (hooks/concierge-resume.sh), exactly as in v2.
#
# Crash-safe like the v1 skill: a session's lines are removed right after its
# wake-up is LAUNCHED — never all at once at the end.
set -u
MANIFEST="$HOME/.claude/limit-interrupted.jsonl"
AGENTS="$HOME/.claude/limit-interrupted-agents.jsonl"
LOCK="$HOME/.claude/limit-resume-concierge.lock"
SWEEPLOG="$HOME/.claude/concierge-sweep.log"
NOTIFY="$HOME/.claude/hooks/concierge-notify.sh"
RESUME="$HOME/.claude/hooks/concierge-resume.sh"
MSG="[Automatic message from the limit concierge] The usage limit has recovered. Continue exactly where you left off with the task you had in progress when the limit hit. If nothing was in progress, reply briefly that there is nothing pending and do nothing else."

[ -s "$MANIFEST" ] || [ -s "$AGENTS" ] || exit 0

log() { echo "$(date -Iseconds) $*" >> "$SWEEPLOG"; }

# Single-instance guard. A sweep takes seconds (wake-ups are launched
# detached), so a lock older than 10 min is a crash/reboot leftover: clear it
# instead of skipping every tick forever.
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

# Every manifest read goes through this: both files, one line per entry.
all_lines() { cat "$MANIFEST" "$AGENTS" 2>/dev/null; }

# test- entries never resume; drop them before any quota gating.
if all_lines | grep -q '"session_id":"test-' 2>/dev/null; then
  for f in "$MANIFEST" "$AGENTS"; do
    [ -f "$f" ] || continue
    grep -v '"session_id":"test-' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  done
  log "dropped test entries"
  [ -s "$MANIFEST" ] || [ -s "$AGENTS" ] || { log "manifest empty after test cleanup"; exit 0; }
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

# If the manifests carry a reset time that is still in the future, don't even
# probe: quota is known to be exhausted until then. (Free early exit.) Only
# trusted up to 5h ahead — the limit window is 5h, so anything further is a
# mis-parsed timezone and would wrongly hold every pending session.
latest_reset=$(all_lines | jq -Rrs '[split("\n")[] | fromjson? | .resets_at // empty] | max // empty' 2>/dev/null)
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

# Build the wake-up message for one session from its manifest lines ($1 = the
# lines, newline-separated; $2 = "live" when it will be posted into a live
# session, "resume" when it opens a headless resume).
# Main-session-only → the legacy message, verbatim (a live main session that
# merely lost its last turn gets it too: that is what it needs to hear).
# With subagents → the list, plus the "continue" sentence when the parent's own
# turn died too. A live parent is told to relaunch from the SAME worktree.
build_message() {
  local lines="$1" mode="${2:-resume}" parent_dead agents n
  parent_dead=$(echo "$lines" | jq -r 'select((.agent_id // "") == "") | .session_id' 2>/dev/null | head -1)
  agents=$(echo "$lines" | jq -r 'select((.agent_id // "") != "") | .agent_id' 2>/dev/null)
  if [ -z "$agents" ]; then echo "$MSG"; return; fi

  n=$(echo "$agents" | grep -c .)
  local out="[Automatic message from the limit concierge] The usage limit has recovered."
  [ -n "$parent_dead" ] && out="$out Your own last turn was cut by the limit too: continue exactly where you left off with the task you had in progress."
  out="$out The following $n subagent(s) of this session were killed by the limit (HTTP 429) and do NOT resume on their own:"
  local aid atype adesc atp awt abr last
  while IFS= read -r aid; do
    [ -n "$aid" ] || continue
    atype=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_type // "agent"' 2>/dev/null | head -1)
    adesc=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_description // empty' 2>/dev/null | head -1)
    atp=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_transcript // empty' 2>/dev/null | head -1)
    awt=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_worktree // empty' 2>/dev/null | head -1)
    abr=$(echo "$lines" | jq -r --arg a "$aid" 'select(.agent_id == $a) | .agent_branch // empty' 2>/dev/null | head -1)
    last=$(agent_last_line "$atp" | tr '"' "'")
    adesc=$(echo "$adesc" | tr '"' "'")
    out="$out
- agentId $aid ($atype${adesc:+, \"$adesc\"})${awt:+ — worktree: $awt}${abr:+ (branch $abr)} — last line before dying: \"${last:-(no text yet)}\"${atp:+ — transcript: $atp}"
  done <<< "$agents"
  if [ "$mode" = "live" ]; then
    out="$out
For each of them: look at its worktree and transcript first — if it already finished, or you already relaunched it, leave it alone. Otherwise relaunch it FROM THE SAME WORKTREE AND BRANCH (an Agent call whose prompt names that worktree path and says to continue the unfinished work there, keeping any uncommitted changes), or re-send it its last instruction with SendMessage to its agentId. If any of them left an iOS simulator booted (xcrun simctl list devices booted), shut it down and delete it before relaunching. Then continue with the task in progress."
  else
    out="$out
For each of them: check its transcript first — if it already finished or was already resumed, leave it alone. Otherwise re-send it its last instruction with SendMessage to its agentId, or relaunch it from the same worktree and branch. If any of them left an iOS simulator booted (xcrun simctl list devices booted), shut it down and delete it before relaunching. Then continue with the task in progress."
  fi
  echo "$out"
}

# The desktop app can revive an interrupted session by itself once the limit
# resets (it appends a synthetic "Continue from where you left off." turn with
# entrypoint claude-desktop). Resuming that session headless on top of it runs
# the same work twice on the same transcript (seen live on 2026-09-02). If the
# parent transcript shows such a revival AFTER the limit hit, skip our resume:
# that live session already holds the subagents' failure notifications.
# (v3: a revived session is normally still alive and gets the socket message
# instead; this guard only matters for the dead path.)
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

# Remove every line of a session from both manifests. Literal match on the
# compact JSON the hook writes first; then a parsed pass so a hand-edited
# (non-compact) line is removed too and the loop can't spin on it.
drop_sid() {
  local f
  for f in "$MANIFEST" "$AGENTS"; do
    [ -f "$f" ] || continue
    grep -vF "\"session_id\":\"$1\"" "$f" \
      | jq -Rr --arg s "$1" '. as $l | (fromjson? // {}) as $o | select(($o.session_id // "") != $s) | $l' 2>/dev/null \
      > "$f.tmp"; mv "$f.tmp" "$f"
  done
}

# Drop lines that are not JSON objects with a session_id (both files).
drop_malformed() {
  local f
  for f in "$MANIFEST" "$AGENTS"; do
    [ -f "$f" ] || continue
    jq -Rr '. as $l | (fromjson? // {}) as $o | select(($o.session_id // "") != "") | $l' "$f" 2>/dev/null > "$f.tmp"; mv "$f.tmp" "$f"
  done
}

# Sweep: up to 5 sessions per pass (self-guard and dedupe already happen in
# the StopFailure hook; test- entries are dropped above without resuming).
# Order per session: launch the wake-up, THEN remove its lines — if the script
# dies mid-pass, everything already delivered is clean and won't be re-sent.
processed=0; iterations=0
while [ "$processed" -lt 5 ]; do
  iterations=$((iterations+1))
  if [ "$iterations" -gt 50 ]; then log "loop guard tripped; leaving the rest for the next tick"; break; fi
  sid=$(all_lines | jq -Rr 'fromjson? | .session_id // empty' 2>/dev/null | head -1)
  if [ -z "$sid" ]; then
    # Nothing parsable left; if bytes remain they are malformed lines.
    if all_lines | grep -q .; then drop_malformed; log "dropped malformed manifest line(s)"; fi
    break
  fi
  case "$sid" in test-*) drop_sid "$sid"; log "dropped test entry $sid"; continue;; esac

  # All lines of this session: the main-session line (if its turn died) and one
  # per dead subagent. cwd: the main-session line's, else the first line's (the
  # hook already rewrote a subagent line's cwd to the parent's when it could).
  # (normalised through jq so one unparsable line cannot abort the group's jq calls)
  lines=$(all_lines | jq -Rc --arg s "$sid" 'fromjson? | select(type == "object" and .session_id == $s)' 2>/dev/null)
  dir=$(echo "$lines" | jq -r 'select((.agent_id // "") == "") | .cwd // empty' 2>/dev/null | head -1)
  [ -n "$dir" ] || dir=$(echo "$lines" | jq -r '.cwd // empty' 2>/dev/null | head -1)
  tp=$(echo "$lines" | jq -r '.transcript_path // empty' 2>/dev/null | head -1)
  agents=$(echo "$lines" | jq -r 'select((.agent_id // "") != "") | .agent_id' 2>/dev/null | tr '\n' ' ')

  # 1. Alive? Post the message into the live session and move on.
  msg=$(build_message "$lines" live)
  "$NOTIFY" "$sid" "$msg"; rc=$?
  if [ "$rc" -eq 0 ]; then
    log "posted into live session $sid over its inbox socket${agents:+ with dead subagents: $agents}"
    drop_sid "$sid"
    processed=$((processed+1))
    continue
  fi
  [ "$rc" -eq 3 ] && log "session $sid looks alive but its inbox socket refused the message; falling back to a headless resume"

  # 2. Dead. Latest limit hit in the group, as an epoch: a fresh death must
  # never be hidden behind an older app revival.
  latest_hit=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    e=$(to_epoch "$l"); [ -n "$e" ] || continue
    [ -z "$latest_hit" ] || [ "$e" -gt "$latest_hit" ] && latest_hit="$e"
  done <<< "$(echo "$lines" | jq -r '.logged_at // empty' 2>/dev/null)"

  revived=$(app_revived_at "$tp" "$latest_hit")
  if [ -n "$revived" ]; then
    log "skipping $sid: the desktop app already revived it at $revived${agents:+ (dead subagents left to that live session: $agents)}"
    drop_sid "$sid"
    continue
  fi

  msg=$(build_message "$lines" resume)
  log "resuming $sid (cwd: $dir)${agents:+ with dead subagents: $agents}"
  "$RESUME" "$sid" "$dir" "$msg"
  drop_sid "$sid"
  processed=$((processed+1))
done

left=$(all_lines | grep -c . 2>/dev/null); left=${left:-0}
log "sweep done: $processed woken, $left pending"
exit 0
