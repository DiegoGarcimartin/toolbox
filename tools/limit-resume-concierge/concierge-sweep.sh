#!/bin/bash
# limit-resume-concierge — deterministic sweep, run by launchd every 5 minutes.
#
# No LLM, no desktop app in the loop: reads the manifest the StopFailure hook
# writes, resumes each interrupted session headless (claude --resume -p) and
# removes its line. An empty manifest exits immediately: idle ticks are free.
#
# Crash-safe like the v1 skill: lines are removed one by one, right after
# their resume is LAUNCHED — never all at once at the end.
set -u
MANIFEST="$HOME/.claude/limit-interrupted.jsonl"
LOCK="$HOME/.claude/limit-resume-concierge.lock"
SWEEPLOG="$HOME/.claude/concierge-sweep.log"
MSG="[Automatic message from the limit concierge] The usage limit has recovered. Continue exactly where you left off with the task you had in progress when the limit hit. If nothing was in progress, reply briefly that there is nothing pending and do nothing else."

[ -s "$MANIFEST" ] || exit 0

log() { echo "$(date -Iseconds) $*" >> "$SWEEPLOG"; }

# Single-instance guard: resumed work can outlive one 5-min tick.
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

# If the manifest carries a reset time that is still in the future, don't even
# probe: quota is known to be exhausted until then. (Free early exit.)
latest_reset=$(jq -rs '[.[] | .resets_at // empty] | max // empty' "$MANIFEST" 2>/dev/null)
if [ -n "$latest_reset" ]; then
  reset_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${latest_reset%%[+Z]*}" +%s 2>/dev/null \
    || date -d "$latest_reset" +%s 2>/dev/null)
  if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$(date +%s)" ]; then
    log "reset expected at $latest_reset; waiting"
    exit 0
  fi
fi

# Quota probe: one minimal headless call. While the limit is active this call
# is rejected (and costs nothing); the sweep retries on the next tick.
# CONCIERGE_TEST_PROBE lets tests inject a canned probe result.
probe=${CONCIERGE_TEST_PROBE:-$(claude -p "Reply with exactly: ok" --output-format json 2>/dev/null | tail -1)}
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

# Sweep: up to 5 sessions per pass (self-guard and dedupe already happen in
# the StopFailure hook; test- entries are dropped here without resuming).
# Order per session: launch the resume, THEN remove its lines — if the script
# dies mid-pass, everything already delivered is clean and won't be re-sent.
drop_sid() { grep -v "\"session_id\":\"$1\"" "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"; }

processed=0
while [ "$processed" -lt 5 ]; do
  line=$(head -n1 "$MANIFEST" 2>/dev/null)
  [ -n "$line" ] || break
  sid=$(echo "$line" | jq -r '.session_id // empty' 2>/dev/null)
  dir=$(echo "$line" | jq -r '.cwd // empty' 2>/dev/null)

  if [ -z "$sid" ]; then
    tail -n +2 "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"
    log "dropped malformed manifest line"
    continue
  fi
  case "$sid" in test-*) drop_sid "$sid"; log "dropped test entry $sid"; continue;; esac

  log "resuming $sid (cwd: $dir)"
  "$HOME/.claude/hooks/concierge-resume.sh" "$sid" "$dir" "$MSG"
  drop_sid "$sid"
  processed=$((processed+1))
done

left=$(grep -c . "$MANIFEST" 2>/dev/null); left=${left:-0}
log "sweep done: $processed resumed, $left pending"
exit 0
