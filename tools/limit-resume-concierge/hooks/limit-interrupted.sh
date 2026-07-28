#!/bin/bash
# limit-resume-concierge — StopFailure hook.
#
# Fires on ANY StopFailure (empty matcher in settings.json), because the docs
# don't guarantee which matcher classifies the 5h usage limit. This script
# filters by content: it only records the session in the manifest if the error
# looks like a usage/quota limit (session/weekly limit, resets, rate_limit...).
# Other failures (auth, billing, invalid_request) are ignored: not worth resuming.
#
# Behavior:
#  - DEDUPE: a session already present in the manifest is not recorded again
#    (a single limit event can fire hundreds of StopFailures, one per
#    interrupted subagent).
#  - resets_at: if the payload carries the reset time as text ("resets 2:40pm"),
#    it is parsed to ISO and stored in the entry and in ~/.claude/limit-reset-at.
#  - Self-guard: the concierge's own runs that die from the limit are not
#    recorded (prevents the concierge from trying to "resume" itself).
MANIFEST="$HOME/.claude/limit-interrupted.jsonl"
RAWLOG="$HOME/.claude/stopfailure-raw.log"
RESETFILE="$HOME/.claude/limit-reset-at"
input=$(cat)

# --- Forensic capture: keep the RAW payload of every StopFailure (last ~200). ---
{ echo "=== $(date -Iseconds) ==="; echo "$input"; } >> "$RAWLOG"
tail -n 200 "$RAWLOG" > "$RAWLOG.tmp" 2>/dev/null && mv "$RAWLOG.tmp" "$RAWLOG"

# Is this a usage-limit error? Look for patterns anywhere in the input JSON.
if ! echo "$input" | grep -Eiq 'session limit|weekly limit|opus limit|usage limit|usage allowance|rate[_ ]?limit|quota|hit your|reset[s]?|resets at'; then
  exit 0
fi

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
tp=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# Self-guard: if the transcript belongs to a concierge run, don't record it.
if [ -n "$tp" ] && [ -f "$tp" ] && head -c 20000 "$tp" | grep -q 'recovery concierge'; then
  exit 0
fi

# Reset-time parsing: "resets 2:40pm" / "resets at 3pm" (local time).
resets_at=""
reset_raw=$(echo "$input" | grep -oiE 'resets( at)? [0-9]{1,2}(:[0-9]{2})?(am|pm)' | head -1)
if [ -n "$reset_raw" ]; then
  hm=$(echo "$reset_raw" | grep -oE '[0-9]{1,2}(:[0-9]{2})?')
  ampm=$(echo "$reset_raw" | grep -oiE '(am|pm)' | tr 'A-Z' 'a-z')
  h=${hm%%:*}; m=$(echo "$hm" | grep -oE ':[0-9]{2}' | tr -d :); m=${m:-0}
  h=$((10#$h)); m=$((10#$m))
  [ "$ampm" = "pm" ] && [ "$h" -ne 12 ] && h=$((h+12))
  [ "$ampm" = "am" ] && [ "$h" -eq 12 ] && h=0
  # BSD date (macOS) and GNU date (Linux) build "today at h:m" with different flags.
  target=$(date -j -v${h}H -v${m}M -v0S +%s 2>/dev/null) \
    || target=$(date -d "today $(printf '%02d:%02d' "$h" "$m"):00" +%s 2>/dev/null)
  if [ -n "$target" ]; then
    now=$(date +%s)
    [ "$target" -le "$now" ] && target=$((target+86400))
    resets_at=$(date -r "$target" -Iseconds 2>/dev/null || date -d "@$target" -Iseconds 2>/dev/null)
    [ -n "$resets_at" ] && echo "$resets_at" > "$RESETFILE"
  fi
fi

# Dedupe: if this session is already recorded, don't add another line.
if [ -n "$sid" ] && [ -f "$MANIFEST" ] && grep -q "\"session_id\":\"$sid\"" "$MANIFEST"; then
  exit 0
fi

entry=$(echo "$input" | jq -c --arg ts "$(date -Iseconds)" --arg ra "$resets_at" \
  '{session_id, cwd, logged_at: $ts, resets_at: (if $ra == "" then null else $ra end), error: (.error // .message // .reason // null)}' 2>/dev/null)
if [ -n "$entry" ]; then
  echo "$entry" >> "$MANIFEST"
else
  echo "$input" >> "$MANIFEST"
fi
exit 0
