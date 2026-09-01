#!/bin/bash
# Tests for the sweep and the StopFailure hook. Sandboxes HOME, stubs
# osascript, injects the quota probe via CONCIERGE_TEST_PROBE. No real API call.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$DIR/concierge-sweep.sh"
HOOK="$DIR/hooks/limit-interrupted.sh"
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

run_sweep() {  # $1=home $2=probe json; killed after 5s so a spinning loop fails instead of hanging
  HOME="$1" OSA_LOG="$1/osascript.log" CONCIERGE_TEST_PROBE="$2" PATH="$TMP/bin:$PATH" \
    perl -e 'alarm 5; exec @ARGV' bash "$SWEEP" >/dev/null 2>&1
}

run_hook() {  # $1=home, payload on stdin
  HOME="$1" bash "$HOOK" >/dev/null 2>&1
}

check() {  # $1=description $2=condition (eval'd)
  if eval "$2"; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi
}

echo "# sweep: auth failure vs quota"
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
run_sweep "$H" "$AUTH_PROBE"
check "no repeat notification while marker exists" \
  "[ \$(wc -l < '$H/osascript.log') -eq 1 ]"
run_sweep "$H" "$OK_PROBE"
check "marker cleared when probe succeeds" \
  "[ ! -e '$H/.claude/concierge-auth-alerted' ]"
H=$(new_home t4)
run_sweep "$H" "$QUOTA_PROBE"
check "quota rejection still logs 'quota not back yet'" \
  "grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' 2>/dev/null"
check "quota rejection sends no notification" "[ ! -f '$H/osascript.log' ]"

echo "# sweep: lock"
H=$(new_home t5)
mkdir "$H/.claude/limit-resume-concierge.lock"
touch -t 202001010000 "$H/.claude/limit-resume-concierge.lock"
run_sweep "$H" "$QUOTA_PROBE"
check "stale lock (from a crash) is cleared and the tick runs" \
  "grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' 2>/dev/null"
check "no lock left behind" "[ ! -d '$H/.claude/limit-resume-concierge.lock' ]"
H=$(new_home t6)
mkdir "$H/.claude/limit-resume-concierge.lock"
run_sweep "$H" "$QUOTA_PROBE"
check "fresh lock still skips the tick" \
  "grep -q 'another sweep is still running' '$H/.claude/concierge-sweep.log' 2>/dev/null"

echo "# sweep: manifest lines the literal grep cannot remove"
H=$(new_home t7)
echo '{"session_id": "test-loop", "cwd": "/tmp"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"; rc=$?
check "non-compact manifest line does not spin forever (exit 0, not killed)" "[ $rc -eq 0 ]"
check "the line was dropped anyway" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"

echo "# sweep: reset-time gate"
H=$(new_home t8)
far=$(date -v+10H -Iseconds)
echo "{\"session_id\":\"fake-1\",\"cwd\":\"/tmp\",\"resets_at\":\"$far\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$QUOTA_PROBE"
check "reset more than 5h ahead (mis-parsed zone) does not gate: probe runs" \
  "grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' 2>/dev/null"
H=$(new_home t9)
near=$(date -v+1H -Iseconds)
echo "{\"session_id\":\"fake-1\",\"cwd\":\"/tmp\",\"resets_at\":\"$near\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$QUOTA_PROBE"
check "reset within 5h still gates (free exit, no probe)" \
  "grep -q 'reset expected' '$H/.claude/concierge-sweep.log' 2>/dev/null && ! grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log'"

echo "# hook: self-guard"
H="$TMP/h1"; mkdir -p "$H/.claude"
echo '{"type":"user","message":{"role":"user","content":"[limit-resume-concierge probe] Reply with exactly: ok"}}' > "$H/probe-transcript.jsonl"
echo "{\"session_id\":\"probe-1\",\"cwd\":\"/\",\"transcript_path\":\"$H/probe-transcript.jsonl\",\"error\":\"rate_limit\"}" | run_hook "$H"
check "the sweep's own quota probe is never recorded" \
  "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"
echo '{"type":"user","message":{"role":"user","content":"fix the failing test"}}' > "$H/work-transcript.jsonl"
echo "{\"session_id\":\"work-1\",\"cwd\":\"/tmp\",\"transcript_path\":\"$H/work-transcript.jsonl\",\"error\":\"rate_limit\"}" | run_hook "$H"
check "a real work session is recorded" \
  "grep -q work-1 '$H/.claude/limit-interrupted.jsonl'"

echo "# hook: reset-time parsing"
H="$TMP/h2"; mkdir -p "$H/.claude"
echo '{"session_id":"s1","cwd":"/tmp","error":"rate_limit","last_assistant_message":"resets 2:40 pm"}' | run_hook "$H"
check "'resets 2:40 pm' (space before pm) yields a parsed resets_at" \
  "jq -e '.resets_at != null' '$H/.claude/limit-interrupted.jsonl' >/dev/null"
H="$TMP/h3"; mkdir -p "$H/.claude"
echo '{"session_id":"s2","cwd":"/Users/x/resets 9pm/app","error":"rate_limit","last_assistant_message":"limit reached"}' | run_hook "$H"
check "a reset time is not read from cwd/paths, only from message fields" \
  "jq -e '.resets_at == null' '$H/.claude/limit-interrupted.jsonl' >/dev/null"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
