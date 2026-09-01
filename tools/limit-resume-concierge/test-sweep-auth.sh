#!/bin/bash
# Tests for concierge-sweep.sh auth-vs-quota classification of a rejected probe.
# Sandboxes HOME, stubs osascript, injects the probe via CONCIERGE_TEST_PROBE.
set -u
SWEEP="$(cd "$(dirname "$0")" && pwd)/concierge-sweep.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

AUTH_PROBE='{"is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}'
QUOTA_PROBE='{"is_error":true,"result":"5-hour limit reached, resets 7pm"}'
OK_PROBE='{"is_error":false,"result":"ok"}'

# osascript stub: records each invocation
mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho "$@" >> "$OSA_LOG"\n' > "$TMP/bin/osascript"
chmod +x "$TMP/bin/osascript"

new_home() {  # fresh sandbox HOME with a one-session manifest
  local h="$TMP/$1"
  mkdir -p "$h/.claude/hooks"
  echo '{"session_id":"fake-1","cwd":"/tmp"}' > "$h/.claude/limit-interrupted.jsonl"
  echo "$h"
}

run_sweep() {  # $1=home $2=probe json
  HOME="$1" OSA_LOG="$1/osascript.log" CONCIERGE_TEST_PROBE="$2" \
    PATH="$TMP/bin:$PATH" bash "$SWEEP" >/dev/null 2>&1
}

check() {  # $1=description $2=condition (eval'd)
  if eval "$2"; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi
}

# 1. Auth failure: classified as logged-out, marker created, notification sent
H=$(new_home t1)
run_sweep "$H" "$AUTH_PROBE"
check "auth failure logged as logged-out, not quota" \
  "grep -q 'logged out' '$H/.claude/concierge-sweep.log' 2>/dev/null"
check "auth failure does NOT log 'quota not back yet'" \
  "! grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' 2>/dev/null"
check "marker file created" "[ -e '$H/.claude/concierge-auth-alerted' ]"
check "macOS notification sent once" \
  "[ -f '$H/osascript.log' ] && [ \$(wc -l < '$H/osascript.log') -eq 1 ]"
check "manifest untouched (session not lost)" \
  "grep -q fake-1 '$H/.claude/limit-interrupted.jsonl'"

# 2. Second tick with marker present: no second notification
run_sweep "$H" "$AUTH_PROBE"
check "no repeat notification while marker exists" \
  "[ \$(wc -l < '$H/osascript.log') -eq 1 ]"

# 3. Probe succeeds again: marker cleared (next incident notifies again)
run_sweep "$H" "$OK_PROBE"
check "marker cleared when probe succeeds" \
  "[ ! -e '$H/.claude/concierge-auth-alerted' ]"

# 4. Plain quota rejection: old behavior intact, no notification
H=$(new_home t4)
run_sweep "$H" "$QUOTA_PROBE"
check "quota rejection still logs 'quota not back yet'" \
  "grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' 2>/dev/null"
check "quota rejection sends no notification" "[ ! -f '$H/osascript.log' ]"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
