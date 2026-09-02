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
#  - One line per interrupted MAIN session (no agent_id in the payload) and one
#    line per interrupted SUBAGENT (payload carries agent_id/agent_type; its
#    session_id is the PARENT session's). Subagents do not resume on their own:
#    the sweep hands the list to the parent, which re-drives them (SendMessage
#    to the agentId, or a relaunch).
#  - DEDUPE by (session_id, agent_id): a single limit event can fire hundreds
#    of StopFailures; each session and each subagent is recorded once.
#  - resets_at: if the payload carries the reset time as text ("resets 2:40pm"),
#    it is parsed to ISO and stored in the entry and in ~/.claude/limit-reset-at.
#  - Self-guard: the sweep's own quota probes are not recorded (the probe is
#    the one session that dies from the limit by design, every tick). Resumed
#    work sessions that hit the limit again ARE recorded: they have work pending.
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
  [.error?, .error_type?, .message?, .reason?, .stop_reason?, .last_assistant_message?]
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
aid=$(echo "$input" | jq -r '.agent_id // empty' 2>/dev/null)

# Self-guard: the sweep's probe prompt carries this marker (see concierge-sweep.sh).
if [ -n "$tp" ] && [ -f "$tp" ] && head -c 20000 "$tp" | grep -q 'limit-resume-concierge probe'; then
  exit 0
fi

# Reset-time parsing: "resets 2:40pm" / "resets at 3pm" / "resets 2:40pm (Europe/Madrid)".
#
# The message states the hour in the timezone of the ACCOUNT, which is not
# necessarily the timezone of the machine (travel, server in another region, a
# laptop that never got its TZ set). When the message names the zone, we honour
# it; otherwise we fall back to the machine's local time and hope they match.
resets_at=""
reset_raw=$(echo "$haystack" | grep -oiE 'resets( at)? [0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)( \([A-Za-z]+/[A-Za-z_]+\))?' | head -1)
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

# Dedupe by (session_id, agent_id). A main-session line has no agent_id; a
# subagent line has its own. The literal match relies on the compact key order
# jq emits below (session_id first, agent_id right after).
if [ -n "$sid" ] && [ -f "$MANIFEST" ]; then
  if [ -n "$aid" ]; then
    grep -qF "\"session_id\":\"$sid\",\"agent_id\":\"$aid\"" "$MANIFEST" && exit 0
  else
    grep -qF "\"session_id\":\"$sid\",\"agent_id\":null" "$MANIFEST" && exit 0
  fi
fi

# Subagent extras. The payload's cwd is the SUBAGENT's (an isolated worktree
# that is deleted when the agent ends), so the resume must run from the PARENT
# session's cwd: the first entry of the parent transcript carries it. The agent's
# own transcript and metadata live next to the parent transcript; the sweep
# reads them at resume time (they persist after the agent dies).
parent_cwd=""; agent_transcript=""; agent_desc=""
if [ -n "$aid" ]; then
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    parent_cwd=$(head -n 50 "$tp" | jq -Rr 'fromjson? | select(type == "object" and .cwd? and .cwd != "") | .cwd' 2>/dev/null | head -1)
    agent_dir="$(dirname "$tp")/$sid/subagents"
    agent_transcript="$agent_dir/agent-$aid.jsonl"
    agent_desc=$(jq -r '.description // empty' "$agent_dir/agent-$aid.meta.json" 2>/dev/null | head -c 200)
  fi
fi

entry=$(echo "$input" | jq -c \
  --arg ts "$(date -Iseconds)" --arg ra "$resets_at" --arg pcwd "$parent_cwd" \
  --arg atp "$agent_transcript" --arg adesc "$agent_desc" '
  {session_id,
   agent_id: (.agent_id // null),
   agent_type: (.agent_type // null),
   agent_description: (if $adesc == "" then null else $adesc end),
   agent_transcript: (if $atp == "" then null else $atp end),
   cwd: (if (.agent_id // "") != "" and $pcwd != "" then $pcwd else .cwd end),
   transcript_path: (.transcript_path // null),
   logged_at: $ts,
   resets_at: (if $ra == "" then null else $ra end),
   error: (.error // .error_type // .message // .reason // null)}' 2>/dev/null)
if [ -n "$entry" ]; then
  echo "$entry" >> "$MANIFEST"
else
  echo "$input" >> "$MANIFEST"
fi
exit 0
