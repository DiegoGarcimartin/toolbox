#!/bin/bash
# Tests for the sweep and the StopFailure hook. Sandboxes HOME, stubs
# osascript and the claude CLI, injects the quota probe via
# CONCIERGE_TEST_PROBE. No real API call.
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
# claude stub: records the session it was asked to resume and the message
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
# args: --resume <sid> -p <msg>
echo "$2" >> "$CLAUDE_STUB_LOG.sid"
printf '%s\n' "$4" >> "$CLAUDE_STUB_LOG.msg"
printf '%s\n' "$4" > "$CLAUDE_STUB_LOG.msg.$2"
EOF
chmod +x "$TMP/bin/claude"

new_home() {  # fresh sandbox HOME with a one-session manifest and the resume helper
  local h="$TMP/$1"
  mkdir -p "$h/.claude/hooks"
  cp "$DIR/hooks/concierge-resume.sh" "$h/.claude/hooks/"
  echo '{"session_id":"fake-1","cwd":"/tmp"}' > "$h/.claude/limit-interrupted.jsonl"
  echo "$h"
}

run_sweep() {  # $1=home $2=probe json; killed after 5s so a spinning loop fails instead of hanging
  HOME="$1" OSA_LOG="$1/osascript.log" CLAUDE_STUB_LOG="$1/claude-stub" CONCIERGE_TEST_PROBE="$2" PATH="$TMP/bin:$PATH" \
    perl -e 'alarm 5; exec @ARGV' bash "$SWEEP" >/dev/null 2>&1
  sleep 1  # the resume is launched detached; give the stub time to write
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

echo "# sweep: main session only (legacy message, unchanged)"
H=$(new_home t10)
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "main session resumed by its own id" "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ]"
check "message is the legacy 'continue' text, verbatim" \
  "grep -qF 'The usage limit has recovered. Continue exactly where you left off' '$H/claude-stub.msg' && ! grep -q 'subagent' '$H/claude-stub.msg'"
check "manifest emptied" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"

echo "# sweep: subagents killed by the limit, parent alive"
H=$(new_home t11)
mkdir -p "$H/proj/parent-1/subagents"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"Fix the failing test in foo.ts"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running the suite now, two files left."}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 7:40pm (Europe/Madrid)"}]}}' \
  > "$H/proj/parent-1/subagents/agent-aaa111.jsonl"
cat > "$H/.claude/limit-interrupted.jsonl" <<EOF
{"session_id":"parent-1","agent_id":"aaa111","agent_type":"general-purpose","agent_description":"Fix foo test","agent_transcript":"$H/proj/parent-1/subagents/agent-aaa111.jsonl","cwd":"/parent/cwd","transcript_path":"$H/proj/parent-1.jsonl","logged_at":"2026-09-02T19:02:27+02:00"}
{"session_id":"parent-1","agent_id":"bbb222","agent_type":"Explore","agent_description":null,"agent_transcript":"$H/proj/parent-1/subagents/agent-bbb222.jsonl","cwd":"/parent/cwd","transcript_path":"$H/proj/parent-1.jsonl","logged_at":"2026-09-02T19:03:47+02:00"}
{"session_id":"other-2","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:03:49+02:00"}
EOF
run_sweep "$H" "$OK_PROBE"
check "parent resumed once (not once per subagent), other session resumed too" \
  "[ \"\$(grep -c parent-1 '$H/claude-stub.sid')\" -eq 1 ] && grep -q other-2 '$H/claude-stub.sid'"
check "message says the subagents do not resume on their own" \
  "grep -q 'do NOT resume on their own' '$H/claude-stub.msg'"
check "message lists both agentIds with type and description" \
  "grep -q 'agentId aaa111 (general-purpose, \"Fix foo test\")' '$H/claude-stub.msg' && grep -q 'agentId bbb222 (Explore)' '$H/claude-stub.msg'"
check "message carries the subagent's last REAL line, not the limit message itself" \
  "grep -q 'last line before dying: \"Running the suite now, two files left.' '$H/claude-stub.msg'"
check "missing subagent transcript is reported, not fatal" \
  "grep -q 'transcript not found' '$H/claude-stub.msg'"
check "message asks to check for booted simulators" \
  "grep -q 'xcrun simctl list devices booted' '$H/claude-stub.msg'"
check "parent alive: its message does NOT include the 'continue where you left off' sentence" \
  "! grep -q 'Continue exactly where you left off' '$H/claude-stub.msg.parent-1'"
check "sweep log names the dead subagents" \
  "grep -q 'resuming parent-1 (cwd: /parent/cwd) with dead subagents: aaa111 bbb222' '$H/.claude/concierge-sweep.log'"
check "all lines of the session removed" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"

echo "# sweep: parent AND subagents killed"
H=$(new_home t12)
cat > "$H/.claude/limit-interrupted.jsonl" <<EOF
{"session_id":"parent-1","agent_id":"aaa111","agent_type":"general-purpose","cwd":"/agent/worktree","logged_at":"2026-09-02T19:02:27+02:00"}
{"session_id":"parent-1","agent_id":null,"cwd":"/parent/cwd","logged_at":"2026-09-02T19:02:29+02:00"}
EOF
run_sweep "$H" "$OK_PROBE"
check "message has both the continue sentence and the subagent list" \
  "grep -q 'Continue exactly where you left off' '$H/claude-stub.msg' && grep -q 'agentId aaa111' '$H/claude-stub.msg'"
check "resume runs from the main session's cwd, not the agent worktree" \
  "grep -q 'resuming parent-1 (cwd: /parent/cwd)' '$H/.claude/concierge-sweep.log'"

echo "# sweep: session already revived by the desktop app"
H=$(new_home t13)
now_epoch=$(date +%s)
logged=$(date -r "$now_epoch" -Iseconds)
later=$(date -u -r $((now_epoch+120)) +%Y-%m-%dT%H:%M:%S.000Z)
earlier=$(date -u -r $((now_epoch-3600)) +%Y-%m-%dT%H:%M:%S.000Z)
printf '%s\n' \
  '{"type":"user","cwd":"/parent/cwd","message":{"role":"user","content":"start"},"timestamp":"'"$earlier"'"}' \
  '{"type":"user","isMeta":true,"entrypoint":"claude-desktop","message":{"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]},"timestamp":"'"$later"'"}' \
  > "$H/proj-revived.jsonl"
echo "{\"session_id\":\"parent-1\",\"agent_id\":\"aaa111\",\"cwd\":\"/parent/cwd\",\"transcript_path\":\"$H/proj-revived.jsonl\",\"logged_at\":\"$logged\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "no headless resume on top of the app's own revival" "[ ! -f '$H/claude-stub.sid' ]"
check "skip is logged with the dead subagents left to the live session" \
  "grep -q 'skipping parent-1: the desktop app already revived it at .* (dead subagents left to that live session: aaa111' '$H/.claude/concierge-sweep.log'"
check "its lines are removed anyway" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"
H=$(new_home t14)
printf '%s\n' \
  '{"type":"user","isMeta":true,"entrypoint":"claude-desktop","message":{"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]},"timestamp":"'"$earlier"'"}' \
  > "$H/proj-old.jsonl"
echo "{\"session_id\":\"parent-1\",\"agent_id\":null,\"cwd\":\"/parent/cwd\",\"transcript_path\":\"$H/proj-old.jsonl\",\"logged_at\":\"$logged\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "a revival OLDER than the limit hit does not block the resume" \
  "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ]"
H=$(new_home t15)
old_hit=$(date -r $((now_epoch-7200)) -Iseconds)
mid=$(date -u -r $((now_epoch-3600)) +%Y-%m-%dT%H:%M:%S.000Z)
printf '%s\n' \
  '{"type":"user","isMeta":true,"entrypoint":"claude-desktop","message":{"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]},"timestamp":"'"$mid"'"}' \
  > "$H/proj-mid.jsonl"
cat > "$H/.claude/limit-interrupted.jsonl" <<EOF
{"session_id":"parent-1","agent_id":"aaa111","cwd":"/parent/cwd","transcript_path":"$H/proj-mid.jsonl","logged_at":"$old_hit"}
{"session_id":"parent-1","agent_id":null,"cwd":"/parent/cwd","transcript_path":"$H/proj-mid.jsonl","logged_at":"$logged"}
EOF
run_sweep "$H" "$OK_PROBE"
check "subagent died 2h ago, app revived 1h ago, parent died again now: the fresh death is NOT hidden behind the old revival" \
  "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ] && grep -q 'agentId aaa111' '$H/claude-stub.msg'"
H=$(new_home t16)
printf '%s\n' '{"session_id":"parent-1","agent_id":"a1","cwd":"/p","logged_at":"2026-09-02T19:02:27+02:00"}' \
  'garbage line mentioning "session_id":"parent-1" that is not JSON' \
  '{"session_id":"parent-1","agent_id":"a2","cwd":"/p","logged_at":"2026-09-02T19:02:28+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "an unparsable line inside a session's group does not truncate the subagent list" \
  "grep -q 'agentId a1' '$H/claude-stub.msg' && grep -q 'agentId a2' '$H/claude-stub.msg'"
check "and the group (garbage included) is fully removed" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"

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

echo "# hook: subagent killed by the limit (payload shape seen live on 2026-09-02)"
H="$TMP/h4"; mkdir -p "$H/.claude" "$H/proj/parent-1/subagents"
printf '%s\n' 'not json at all' '{"type":"user","cwd":"/parent/cwd","message":{"role":"user","content":"build the feature"}}' > "$H/proj/parent-1.jsonl"
echo '{"agentType":"general-purpose","description":"Fix stored rebuild over-promise"}' > "$H/proj/parent-1/subagents/agent-aaa111.meta.json"
SUB1="{\"session_id\":\"parent-1\",\"transcript_path\":\"$H/proj/parent-1.jsonl\",\"cwd\":\"/repo/.claude/worktrees/agent-aaa111\",\"agent_id\":\"aaa111\",\"agent_type\":\"general-purpose\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your session limit · resets 7:40pm (Europe/Madrid)\"}"
echo "$SUB1" | run_hook "$H"
M="$H/.claude/limit-interrupted.jsonl"
check "recorded under the PARENT session id with the agent id" \
  "jq -e 'select(.session_id == \"parent-1\" and .agent_id == \"aaa111\" and .agent_type == \"general-purpose\")' '$M' >/dev/null"
check "cwd rewritten to the parent's (from its transcript, past a non-JSON first line), not the agent worktree" \
  "jq -e '.cwd == \"/parent/cwd\"' '$M' >/dev/null"
check "agent description and transcript path recorded" \
  "jq -e '.agent_description == \"Fix stored rebuild over-promise\" and (.agent_transcript | endswith(\"/parent-1/subagents/agent-aaa111.jsonl\"))' '$M' >/dev/null"
check "resets_at parsed from the subagent's message" "jq -e '.resets_at != null' '$M' >/dev/null"
echo "$SUB1" | run_hook "$H"
check "same subagent again: deduped" "[ \$(grep -c . '$M') -eq 1 ]"
echo "${SUB1//aaa111/bbb222}" | run_hook "$H"
check "a second subagent of the same session: its own line" \
  "[ \$(grep -c . '$M') -eq 2 ] && jq -e 'select(.agent_id == \"bbb222\")' '$M' >/dev/null"
PARENT="{\"session_id\":\"parent-1\",\"transcript_path\":\"$H/proj/parent-1.jsonl\",\"cwd\":\"/parent/cwd\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your session limit · resets 7:40pm (Europe/Madrid)\"}"
echo "$PARENT" | run_hook "$H"
check "the parent's own death is a third line (agent_id null)" \
  "[ \$(grep -c . '$M') -eq 3 ] && jq -e 'select(.agent_id == null and .session_id == \"parent-1\")' '$M' >/dev/null"
echo "$PARENT" | run_hook "$H"
check "the parent again: deduped (no 300-line manifests)" "[ \$(grep -c . '$M') -eq 3 ]"
echo '{"session_id":"parent-1","agent_id":"ccc333","agent_type":"Explore","cwd":"/x","error_type":"rate_limit"}' | run_hook "$H"
check "documented field name error_type is honoured too" \
  "jq -e 'select(.agent_id == \"ccc333\") | .error == \"rate_limit\"' '$M' >/dev/null"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
