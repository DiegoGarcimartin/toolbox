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

# Is this a usage-limit error?
#
# Search ONLY the fields that can carry the reason, never the whole payload:
# session_id, cwd and transcript_path are attacker-free but user-chosen, and a
# session living in ~/dev/rate-limit-tool is not a quota failure. If the schema
# ever changes and none of these fields exist, fall back to the whole blob —
# a false positive costs one useless nudge, a false negative loses a session.
haystack=$(echo "$input" | jq -r '
  [.error?, .message?, .reason?, .stop_reason?, .last_assistant_message?]
  | map(select(type == "string")) | join(" ")' 2>/dev/null)
[ -z "$haystack" ] && haystack="$input"

# Patterns are anchored to phrases, not to bare words: "quota" or "reset" on
# their own also appear in ordinary prose Claude writes ("I checked your quota
# dashboard"), which used to arm the concierge on unrelated failures.
if ! echo "$haystack" | grep -Eiq '(session|weekly|opus|usage) limit|usage allowance|rate[_ -]?limit|limit reached|quota (exceeded|exhausted)|out of (quota|credits?)|resets?( at)? [0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)'; then
  exit 0
fi

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
tp=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# Self-guard: if the transcript belongs to a concierge run, don't record it.
if [ -n "$tp" ] && [ -f "$tp" ] && head -c 20000 "$tp" | grep -q 'recovery concierge'; then
  exit 0
fi

# Reset-time parsing: "resets 2:40pm" / "resets at 3pm" / "resets 2:40pm (Europe/Madrid)".
#
# The message states the hour in the timezone of the ACCOUNT, which is not
# necessarily the timezone of the machine (travel, server in another region, a
# laptop that never got its TZ set). When the message names the zone, we honour
# it; otherwise we fall back to the machine's local time and hope they match.
resets_at=""
reset_raw=$(echo "$input" | grep -oiE 'resets( at)? [0-9]{1,2}(:[0-9]{2})?(am|pm)( \([A-Za-z]+/[A-Za-z_]+\))?' | head -1)
if [ -n "$reset_raw" ]; then
  hm=$(echo "$reset_raw" | grep -oE '[0-9]{1,2}(:[0-9]{2})?')
  ampm=$(echo "$reset_raw" | grep -oiE '(am|pm)' | tr 'A-Z' 'a-z')
  h=${hm%%:*}; m=$(echo "$hm" | grep -oE ':[0-9]{2}' | tr -d :); m=${m:-0}
  h=$((10#$h)); m=$((10#$m))
  [ "$ampm" = "pm" ] && [ "$h" -ne 12 ] && h=$((h+12))
  [ "$ampm" = "am" ] && [ "$h" -eq 12 ] && h=0

  # Zone named in the message, only if the system actually knows it.
  tz=$(echo "$reset_raw" | grep -oE '\([A-Za-z]+/[A-Za-z_]+\)' | tr -d '()')
  [ -n "$tz" ] && [ ! -f "/usr/share/zoneinfo/$tz" ] && tz=""

  # BSD date (macOS) and GNU date (Linux) build "today at h:m" with different
  # flags. Both emit an absolute epoch, so the comparison below is
  # timezone-proof either way. NOTE: the TZ= prefix is applied only when a zone
  # was named — an empty TZ="" would silently mean UTC, not "local".
  if [ -n "$tz" ]; then
    target=$(TZ="$tz" date -j -v${h}H -v${m}M -v0S +%s 2>/dev/null) \
      || target=$(TZ="$tz" date -d "today $(printf '%02d:%02d' "$h" "$m"):00" +%s 2>/dev/null)
  else
    target=$(date -j -v${h}H -v${m}M -v0S +%s 2>/dev/null) \
      || target=$(date -d "today $(printf '%02d:%02d' "$h" "$m"):00" +%s 2>/dev/null)
  fi
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
