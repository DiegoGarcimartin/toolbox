#!/bin/bash
# Tests for the sweep, the StopFailure hook and the live-session notifier (v3).
# Sandboxes HOME, stubs osascript and the claude CLI, injects the quota probe
# via CONCIERGE_TEST_PROBE (one fixed answer) or CONCIERGE_TEST_PROBE_SEQ (a
# file, one answer per probe). The sweep's timing knobs default to zero here
# (no hold, no retry, no margin) unless a test sets them. No real API call, no
# real session, no socket outside the sandbox.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$DIR/concierge-sweep.sh"
HOOK="$DIR/hooks/limit-interrupted.sh"
NOTIFY="$DIR/hooks/concierge-notify.sh"
TMP=$(mktemp -d)
# Background helpers (fake live processes, socket listeners) are tracked in a
# FILE, not a variable: fake_live_pid runs inside $(...) and a variable set
# there dies with the subshell — that leaked a sleeper per test.
BGPIDS="$TMP/bg.pids"; : > "$BGPIDS"
track() { echo "$1" >> "$BGPIDS"; disown "$1" 2>/dev/null || true; }  # disown: no "Terminated" noise at cleanup
cleanup() {
  local pids; pids=$(cat "$BGPIDS" 2>/dev/null)
  for p in $pids; do kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
PASS=0; FAIL=0

AUTH_PROBE='{"is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}'
QUOTA_PROBE='{"is_error":true,"result":"5-hour limit reached, resets 7pm"}'
OK_PROBE='{"is_error":false,"result":"ok"}'

# osascript stub: records each invocation
mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho "$@" >> "$OSA_LOG"\n' > "$TMP/bin/osascript"
chmod +x "$TMP/bin/osascript"
# claude stub: records the session it was asked to resume, the message, and the
# environment the resume helper handed it.
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
# args: --resume <sid> -p <msg>
echo "$2" >> "$CLAUDE_STUB_LOG.sid"
printf '%s\n' "$4" >> "$CLAUDE_STUB_LOG.msg"
printf '%s\n' "$4" > "$CLAUDE_STUB_LOG.msg.$2"
echo "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-unset}" >> "$CLAUDE_STUB_LOG.env"
EOF
chmod +x "$TMP/bin/claude"

# Fake LIVE claude process, for notify.sh's `ps -o comm=` check only. It must be
# a DIFFERENT binary from the CLI stub above (that one exits immediately) and it
# must be named "claude". A *copy* of /bin/sleep is SIGKILLed by macOS (copying
# breaks the platform binary's code signature), so symlink it instead.
mkdir -p "$TMP/live"
ln -sf /bin/sleep "$TMP/live/claude"

fake_live_pid() {  # a long-running process whose `ps -o comm=` contains "claude"
  # stdout/stderr MUST be redirected: this runs inside $(...) and a background
  # child holding that pipe open would block the command substitution forever.
  "$TMP/live/claude" 600 >/dev/null 2>&1 &
  track $!
  echo $!
}

register_session() {  # $1=home $2=sid $3=pid $4=socket path (procStart omitted on purpose)
  # -c: the real registry is ONE compact line (~/.claude/sessions/<pid>.json),
  # which is what notify.sh's literal `"sessionId":"<sid>"` grep relies on.
  mkdir -p "$1/.claude/sessions"
  jq -cn --arg s "$2" --argjson p "$3" --arg k "$4" \
    '{pid:$p,sessionId:$s,cwd:"/tmp",messagingSocketPath:$k}' > "$1/.claude/sessions/$3.json"
}

start_listener() {  # $1=socket path $2=capture file — stands in for the session's inbox
  rm -f "$1"
  nc -lU "$1" > "$2" 2>/dev/null &
  track $!
  local i=0
  while [ ! -S "$1" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i+1)); done
}

dead_socket() {  # $1=socket path — leaves a socket FILE that refuses connections
  local p i=0
  nc -lU "$1" > /dev/null 2>&1 &
  p=$!
  while [ ! -S "$1" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i+1)); done
  kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
}

new_home() {  # fresh sandbox HOME with a one-session manifest and both helpers
  local h="$TMP/$1"
  mkdir -p "$h/.claude/hooks"
  cp "$DIR/hooks/concierge-resume.sh" "$h/.claude/hooks/"
  cp "$DIR/hooks/concierge-notify.sh" "$h/.claude/hooks/"
  echo '{"session_id":"fake-1","cwd":"/tmp"}' > "$h/.claude/limit-interrupted.jsonl"
  echo "$h"
}

run_sweep() {  # $1=home $2=probe json ("" with CONCIERGE_TEST_PROBE_SEQ); killed after 10s so a spinning loop fails instead of hanging
  HOME="$1" OSA_LOG="$1/osascript.log" CLAUDE_STUB_LOG="$1/claude-stub" CONCIERGE_TEST_PROBE="$2" PATH="$TMP/bin:$PATH" \
    CONCIERGE_PROBE_WINDOW="${CONCIERGE_PROBE_WINDOW-0}" CONCIERGE_PROBE_INTERVAL="${CONCIERGE_PROBE_INTERVAL-0}" \
    CONCIERGE_RESET_MARGIN="${CONCIERGE_RESET_MARGIN-0}" \
    perl -e 'alarm 10; exec @ARGV' bash "$SWEEP" >/dev/null 2>&1
  sleep 1  # the resume is launched detached; give the stub time to write
}

probe_seq() {  # $1=home, then one probe answer per argument → the file for CONCIERGE_TEST_PROBE_SEQ
  local f="$1/probe-seq"; shift
  printf '%s\n' "$@" > "$f"
  echo "$f"
}

run_hook() {  # $1=home, payload on stdin
  HOME="$1" bash "$HOOK" >/dev/null 2>&1
}

last_log() {  # $1=home — the sweep's final line, without its timestamp
  tail -1 "$1/.claude/concierge-sweep.log" 2>/dev/null | sed 's/.* sweep done/sweep done/'
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
H=$(new_home t6b)
mkdir "$H/.claude/limit-resume-concierge.lock"
touch -t "$(date -v-12M +%Y%m%d%H%M)" "$H/.claude/limit-resume-concierge.lock"
run_sweep "$H" "$QUOTA_PROBE"
check "a 12-minute-old lock (a sweep holding for the reset) is NOT stale: the tick skips" \
  "grep -q 'another sweep is still running' '$H/.claude/concierge-sweep.log' 2>/dev/null && [ -d '$H/.claude/limit-resume-concierge.lock' ]"

echo "# sweep: manifest lines the literal grep cannot remove"
H=$(new_home t7)
echo '{"session_id": "test-loop", "cwd": "/tmp"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"; rc=$?
check "non-compact manifest line does not spin forever (exit 0, not killed)" "[ $rc -eq 0 ]"
check "the line was dropped anyway" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"
H=$(new_home t7b)
: > "$H/.claude/limit-interrupted.jsonl"
echo '{"session_id": "parent-9", "agent_id": "a9", "cwd": "/p", "logged_at": "2026-09-02T19:02:27+02:00"}' \
  > "$H/.claude/limit-interrupted-agents.jsonl"
run_sweep "$H" "$OK_PROBE"; rc=$?
check "a non-compact (hand-edited) line in the AGENTS manifest is dropped too, no spin" \
  "[ $rc -eq 0 ] && [ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ]"
H=$(new_home t7c)
printf '%s\n' 'not json' 'still not json' > "$H/.claude/limit-interrupted.jsonl"
printf '%s\n' 'garbage in the agents file too' > "$H/.claude/limit-interrupted-agents.jsonl"
run_sweep "$H" "$OK_PROBE"; rc=$?
check "malformed non-JSON lines are dropped from both files, nothing resumed" \
  "[ $rc -eq 0 ] && [ ! -s '$H/.claude/limit-interrupted.jsonl' ] && [ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ] && [ ! -f '$H/claude-stub.sid' ]"

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
H=$(new_home t9b)
: > "$H/.claude/limit-interrupted.jsonl"
echo "{\"session_id\":\"p1\",\"agent_id\":\"a1\",\"cwd\":\"/tmp\",\"resets_at\":\"$near\"}" > "$H/.claude/limit-interrupted-agents.jsonl"
run_sweep "$H" "$QUOTA_PROBE"
check "the reset time is read from the AGENTS manifest too" \
  "grep -q 'reset expected' '$H/.claude/concierge-sweep.log' 2>/dev/null"

echo "# sweep: wake-up timing (v3.1) — hold for a near reset, retry inside the tick, parse the probe"
H=$(new_home t9c)
soon=$(date -v+2S -Iseconds)
echo "{\"session_id\":\"fake-1\",\"cwd\":\"/tmp\",\"resets_at\":\"$soon\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "reset less than a tick away: the sweep HOLDS instead of exiting, then wakes the session" \
  "grep -q 'holding this tick' '$H/.claude/concierge-sweep.log' && ! grep -q '; waiting' '$H/.claude/concierge-sweep.log' && [ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = fake-1 ]"
H=$(new_home t9d)
soon=$(date -v+2S -Iseconds)
echo "{\"session_id\":\"fake-1\",\"cwd\":\"/tmp\",\"resets_at\":\"$soon\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$QUOTA_PROBE"
check "held tick whose probe is still rejected: logged as quota not back, session kept" \
  "grep -q 'holding this tick' '$H/.claude/concierge-sweep.log' && grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' && grep -q fake-1 '$H/.claude/limit-interrupted.jsonl'"
H=$(new_home t9e)
SEQ=$(probe_seq "$H" "$QUOTA_PROBE" "$QUOTA_PROBE" "$OK_PROBE")
CONCIERGE_TEST_PROBE_SEQ="$SEQ" CONCIERGE_PROBE_WINDOW=5 run_sweep "$H" ""
check "a rejected probe is retried inside the same tick and the session is woken on the third" \
  "grep -q 'retrying every 0s for up to 5s' '$H/.claude/concierge-sweep.log' && grep -q 'quota back (probe 3 accepted)' '$H/.claude/concierge-sweep.log' && [ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = fake-1 ]"
check "the rejection reason is logged verbatim" \
  "grep -q 'probe rejected: 5-hour limit reached, resets 7pm' '$H/.claude/concierge-sweep.log'"
H=$(new_home t9f)
CONCIERGE_PROBE_WINDOW=3 CONCIERGE_PROBE_INTERVAL=1 run_sweep "$H" "$QUOTA_PROBE"; rc=$?
check "probes keep failing: the tick gives up when its window closes (not killed), session kept" \
  "[ $rc -eq 0 ] && grep -q 'will retry next tick' '$H/.claude/concierge-sweep.log' && grep -q fake-1 '$H/.claude/limit-interrupted.jsonl'"
H=$(new_home t9g)
SEQ=$(probe_seq "$H" 'Update available: 9.9.9\n{"type":"result","is_error":false,"result":"ok","session_id":"x"}\nsome trailing notice')
CONCIERGE_TEST_PROBE_SEQ="$SEQ" run_sweep "$H" ""
check "the result object is found among extra stdout lines (no more tail -1): accepted" \
  "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = fake-1 ] && ! grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log'"
H=$(new_home t9h)
SEQ=$(probe_seq "$H" "<empty>" "$OK_PROBE")
CONCIERGE_TEST_PROBE_SEQ="$SEQ" CONCIERGE_PROBE_WINDOW=5 run_sweep "$H" ""
check "an empty probe output is logged as unparsable and retried, not treated as a dead end" \
  "grep -q 'no result object in the probe output: (empty)' '$H/.claude/concierge-sweep.log' && [ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = fake-1 ]"
H=$(new_home t9i)
CONCIERGE_PROBE_WINDOW=5 run_sweep "$H" '{"is_error":true,"result":"Not logged in · Please run /login"}'
check "'Not logged in' is an auth failure: notified once, no retry loop, session kept" \
  "grep -q 'CLI logged out' '$H/.claude/concierge-sweep.log' && ! grep -q 'quota not back yet' '$H/.claude/concierge-sweep.log' && [ \$(wc -l < '$H/osascript.log') -eq 1 ] && grep -q fake-1 '$H/.claude/limit-interrupted.jsonl'"

echo "# sweep: main session only (legacy message, unchanged)"
H=$(new_home t10)
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "main session resumed by its own id" "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ]"
check "message is the legacy 'continue' text, verbatim" \
  "grep -qF 'The usage limit has recovered. Continue exactly where you left off' '$H/claude-stub.msg' && ! grep -q 'subagent' '$H/claude-stub.msg'"
check "manifest emptied" "[ ! -s '$H/.claude/limit-interrupted.jsonl' ]"
check "the headless resume carries CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 (no 10-min ceiling)" \
  "grep -q 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0' '$H/claude-stub.env'"
check "the sweep's final line reports woken and pending" \
  "[ \"\$(last_log '$H')\" = 'sweep done: 1 woken, 0 pending' ]"

echo "# sweep: subagents killed by the limit (agents manifest), parent's own turn survived"
H=$(new_home t11)
mkdir -p "$H/proj/parent-1/subagents"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"Fix the failing test in foo.ts"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running the suite now, two files left."}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 7:40pm (Europe/Madrid)"}]}}' \
  > "$H/proj/parent-1/subagents/agent-aaa111.jsonl"
cat > "$H/.claude/limit-interrupted-agents.jsonl" <<EOF
{"session_id":"parent-1","agent_id":"aaa111","agent_type":"general-purpose","agent_description":"Fix foo test","agent_worktree":"/repo/.claude/worktrees/agent-aaa111","agent_branch":"claude/fix-foo","agent_transcript":"$H/proj/parent-1/subagents/agent-aaa111.jsonl","cwd":"/parent/cwd","transcript_path":"$H/proj/parent-1.jsonl","logged_at":"2026-09-02T19:02:27+02:00"}
{"session_id":"parent-1","agent_id":"bbb222","agent_type":"Explore","agent_description":null,"agent_transcript":"$H/proj/parent-1/subagents/agent-bbb222.jsonl","cwd":"/parent/cwd","transcript_path":"$H/proj/parent-1.jsonl","logged_at":"2026-09-02T19:03:47+02:00"}
EOF
echo '{"session_id":"other-2","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:03:49+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "a session present ONLY in the agents manifest is woken (both files are read)" \
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
check "parent's own turn survived: no 'continue exactly where you left off' sentence" \
  "! grep -qi 'continue exactly where you left off' '$H/claude-stub.msg.parent-1'"
check "sweep log names the dead subagents" \
  "grep -q 'resuming parent-1 (cwd: /parent/cwd) with dead subagents: aaa111 bbb222' '$H/.claude/concierge-sweep.log'"
check "both manifests are left empty" \
  "[ ! -s '$H/.claude/limit-interrupted.jsonl' ] && [ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ]"

echo "# sweep: parent AND subagents killed"
H=$(new_home t12)
echo '{"session_id":"parent-1","agent_id":"aaa111","agent_type":"general-purpose","cwd":"/agent/worktree","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted-agents.jsonl"
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/parent/cwd","logged_at":"2026-09-02T19:02:29+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "message has both the continue sentence and the subagent list" \
  "grep -qi 'continue exactly where you left off' '$H/claude-stub.msg' && grep -q 'agentId aaa111' '$H/claude-stub.msg'"
check "resume runs from the main session's cwd, not the agent worktree" \
  "grep -q 'resuming parent-1 (cwd: /parent/cwd)' '$H/.claude/concierge-sweep.log'"
check "drop_sid clears the session from BOTH manifests" \
  "[ ! -s '$H/.claude/limit-interrupted.jsonl' ] && [ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ]"

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
: > "$H/.claude/limit-interrupted.jsonl"
echo "{\"session_id\":\"parent-1\",\"agent_id\":\"aaa111\",\"cwd\":\"/parent/cwd\",\"transcript_path\":\"$H/proj-revived.jsonl\",\"logged_at\":\"$logged\"}" > "$H/.claude/limit-interrupted-agents.jsonl"
run_sweep "$H" "$OK_PROBE"
check "no headless resume on top of the app's own revival" "[ ! -f '$H/claude-stub.sid' ]"
check "skip is logged with the dead subagents left to the live session" \
  "grep -q 'skipping parent-1: the desktop app already revived it at .* (dead subagents left to that live session: aaa111' '$H/.claude/concierge-sweep.log'"
check "its lines are removed anyway" "[ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ]"
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
echo "{\"session_id\":\"parent-1\",\"agent_id\":\"aaa111\",\"cwd\":\"/parent/cwd\",\"transcript_path\":\"$H/proj-mid.jsonl\",\"logged_at\":\"$old_hit\"}" > "$H/.claude/limit-interrupted-agents.jsonl"
echo "{\"session_id\":\"parent-1\",\"agent_id\":null,\"cwd\":\"/parent/cwd\",\"transcript_path\":\"$H/proj-mid.jsonl\",\"logged_at\":\"$logged\"}" > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "subagent died 2h ago, app revived 1h ago, parent died again now: the fresh death is NOT hidden behind the old revival" \
  "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ] && grep -q 'agentId aaa111' '$H/claude-stub.msg'"
H=$(new_home t16)
: > "$H/.claude/limit-interrupted.jsonl"
printf '%s\n' '{"session_id":"parent-1","agent_id":"a1","cwd":"/p","logged_at":"2026-09-02T19:02:27+02:00"}' \
  'garbage line mentioning "session_id":"parent-1" that is not JSON' \
  '{"session_id":"parent-1","agent_id":"a2","cwd":"/p","logged_at":"2026-09-02T19:02:28+02:00"}' \
  > "$H/.claude/limit-interrupted-agents.jsonl"
run_sweep "$H" "$OK_PROBE"
check "an unparsable line inside a session's group does not truncate the subagent list" \
  "grep -q 'agentId a1' '$H/claude-stub.msg' && grep -q 'agentId a2' '$H/claude-stub.msg'"
check "and the group (garbage included) is fully removed" "[ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ]"

echo "# sweep: the session is still ALIVE (posted over its inbox socket)"
H=$(new_home t17)
LP=$(fake_live_pid)
register_session "$H" "parent-1" "$LP" "$H/inbox.sock"
start_listener "$H/inbox.sock" "$H/captured.txt"
: > "$H/.claude/limit-interrupted.jsonl"
cat > "$H/.claude/limit-interrupted-agents.jsonl" <<EOF
{"session_id":"parent-1","agent_id":"aaa111","agent_type":"general-purpose","agent_description":"Fix foo test","agent_worktree":"/repo/.claude/worktrees/agent-aaa111","agent_branch":"claude/fix-foo","cwd":"/parent/cwd","logged_at":"2026-09-02T19:02:27+02:00"}
EOF
run_sweep "$H" "$OK_PROBE"
LIVE_MSG=$(jq -r '.message.content' "$H/captured.txt" 2>/dev/null)
check "a live session is NOT resumed headless" "[ ! -f '$H/claude-stub.sid' ]"
check "the wake-up arrives on the inbox socket as one user message" \
  "[ \"\$(jq -r '.type' '$H/captured.txt' 2>/dev/null)\" = user ] && [ \"\$(jq -r '.message.role' '$H/captured.txt' 2>/dev/null)\" = user ]"
check "the delivered message announces the recovery and lists the dead subagent" \
  "printf '%s' \"\$LIVE_MSG\" | grep -q 'The usage limit has recovered' && printf '%s' \"\$LIVE_MSG\" | grep -q 'agentId aaa111'"
check "live mode tells the parent to relaunch FROM THE SAME WORKTREE AND BRANCH" \
  "printf '%s' \"\$LIVE_MSG\" | grep -q 'FROM THE SAME WORKTREE AND BRANCH'"
check "live mode names the agent's worktree path and branch" \
  "printf '%s' \"\$LIVE_MSG\" | grep -q 'worktree: /repo/.claude/worktrees/agent-aaa111 (branch claude/fix-foo)'"
check "the live path is logged, with the dead subagents" \
  "grep -q 'posted into live session parent-1 over its inbox socket with dead subagents: aaa111' '$H/.claude/concierge-sweep.log'"
check "the session's lines are removed from both manifests after posting" \
  "[ ! -s '$H/.claude/limit-interrupted-agents.jsonl' ] && [ ! -s '$H/.claude/limit-interrupted.jsonl' ]"
check "a posted session counts as woken in the final line" \
  "[ \"\$(last_log '$H')\" = 'sweep done: 1 woken, 0 pending' ]"
H=$(new_home t18)
LP=$(fake_live_pid)
register_session "$H" "parent-1" "$LP" "$H/inbox.sock"
start_listener "$H/inbox.sock" "$H/captured.txt"
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
LIVE_MSG=$(jq -r '.message.content' "$H/captured.txt" 2>/dev/null)
check "a live main-session-only wake-up is the legacy message, verbatim, in live mode too" \
  "printf '%s' \"\$LIVE_MSG\" | grep -qF 'The usage limit has recovered. Continue exactly where you left off' && ! printf '%s' \"\$LIVE_MSG\" | grep -q subagent"
check "posted into the live session, not resumed" \
  "[ ! -f '$H/claude-stub.sid' ] && grep -q 'posted into live session parent-1' '$H/.claude/concierge-sweep.log'"

echo "# sweep: not alive / socket refused → headless resume"
H=$(new_home t19)
DEADPID=$(fake_live_pid); kill "$DEADPID" 2>/dev/null; wait "$DEADPID" 2>/dev/null
register_session "$H" "parent-1" "$DEADPID" "$H/inbox.sock"
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "registered but the pid is dead: the session is resumed headless" \
  "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ]"
H=$(new_home t20)
LP=$(fake_live_pid)
register_session "$H" "parent-1" "$LP" "$H/missing.sock"   # socket never created
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "live pid but no inbox socket: resumed headless, without the 'falling back' line" \
  "[ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ] && ! grep -q 'falling back' '$H/.claude/concierge-sweep.log'"
H=$(new_home t21)
LP=$(fake_live_pid)
register_session "$H" "parent-1" "$LP" "$H/refused.sock"
dead_socket "$H/refused.sock"
echo '{"session_id":"parent-1","agent_id":null,"cwd":"/tmp","logged_at":"2026-09-02T19:02:27+02:00"}' > "$H/.claude/limit-interrupted.jsonl"
run_sweep "$H" "$OK_PROBE"
check "socket present but refusing: logged as a fallback and resumed headless" \
  "grep -q 'falling back to a headless resume' '$H/.claude/concierge-sweep.log' && [ \"\$(cat '$H/claude-stub.sid' 2>/dev/null)\" = parent-1 ]"

echo "# sweep: batch cap and the final log line"
H=$(new_home t22)
: > "$H/.claude/limit-interrupted.jsonl"
for i in 1 2 3 4 5 6; do
  echo "{\"session_id\":\"s$i\",\"agent_id\":null,\"cwd\":\"/tmp\",\"logged_at\":\"2026-09-02T19:02:2$i+02:00\"}" >> "$H/.claude/limit-interrupted.jsonl"
done
run_sweep "$H" "$OK_PROBE"
check "at most 5 sessions per pass; the rest is reported as pending" \
  "[ \"\$(last_log '$H')\" = 'sweep done: 5 woken, 1 pending' ]"

echo "# notify: exit codes (unit)"
NH="$TMP/n1"; mkdir -p "$NH/.claude"
HOME="$NH" bash "$NOTIFY" no-such-session "hi"; rc=$?
check "notify: no session registry at all → exit 2 (treat as dead)" "[ $rc -eq 2 ]"
NH="$TMP/n2"; mkdir -p "$NH/.claude"
DEADPID=$(fake_live_pid); kill "$DEADPID" 2>/dev/null; wait "$DEADPID" 2>/dev/null
register_session "$NH" "sid-2" "$DEADPID" "$NH/inbox.sock"
HOME="$NH" bash "$NOTIFY" sid-2 "hi"; rc=$?
check "notify: registered pid no longer running → exit 2" "[ $rc -eq 2 ]"
NH="$TMP/n3"; mkdir -p "$NH/.claude"
/bin/sleep 600 >/dev/null 2>&1 & SLEEPPID=$!; track "$SLEEPPID"
register_session "$NH" "sid-3" "$SLEEPPID" "$NH/inbox.sock"
start_listener "$NH/inbox.sock" "$NH/captured.txt"
HOME="$NH" bash "$NOTIFY" sid-3 "hi"; rc=$?
check "notify: pid alive but the process is not claude (pid reuse) → exit 2" "[ $rc -eq 2 ]"
NH="$TMP/n4"; mkdir -p "$NH/.claude"
LP=$(fake_live_pid)
register_session "$NH" "sid-4" "$LP" "$NH/missing.sock"
HOME="$NH" bash "$NOTIFY" sid-4 "hi"; rc=$?
check "notify: live claude but no socket file → exit 2" "[ $rc -eq 2 ]"
NH="$TMP/n5"; mkdir -p "$NH/.claude"
LP=$(fake_live_pid)
register_session "$NH" "sid-5" "$LP" "$NH/inbox.sock"
start_listener "$NH/inbox.sock" "$NH/captured.txt"
HOME="$NH" bash "$NOTIFY" sid-5 "hello from the concierge"; rc=$?
sleep 0.5
check "notify: live session → exit 0" "[ $rc -eq 0 ]"
check "notify: the exact message is delivered on the socket" \
  "[ \"\$(jq -r '.message.content' '$NH/captured.txt' 2>/dev/null)\" = 'hello from the concierge' ]"
NH="$TMP/n6"; mkdir -p "$NH/.claude"
LP=$(fake_live_pid)
register_session "$NH" "sid-6" "$LP" "$NH/refused.sock"
dead_socket "$NH/refused.sock"
HOME="$NH" bash "$NOTIFY" sid-6 "hi"; rc=$?
check "notify: socket present but refusing → exit 3 (sweep falls back)" "[ $rc -eq 3 ]"

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

echo "# hook: subagent killed by the limit → the AGENTS manifest (v3)"
H="$TMP/h4"; mkdir -p "$H/.claude" "$H/proj/parent-1/subagents"
printf '%s\n' 'not json at all' '{"type":"user","cwd":"/parent/cwd","message":{"role":"user","content":"build the feature"}}' > "$H/proj/parent-1.jsonl"
cat > "$H/proj/parent-1/subagents/agent-aaa111.meta.json" <<'EOF'
{"agentType":"general-purpose","description":"Fix stored rebuild over-promise","worktreePath":"/repo/.claude/worktrees/agent-aaa111","worktreeBranch":"claude/fix-rebuild"}
EOF
SUB1="{\"session_id\":\"parent-1\",\"transcript_path\":\"$H/proj/parent-1.jsonl\",\"cwd\":\"/repo/.claude/worktrees/agent-aaa111\",\"agent_id\":\"aaa111\",\"agent_type\":\"general-purpose\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your session limit · resets 7:40pm (Europe/Madrid)\"}"
echo "$SUB1" | run_hook "$H"
M="$H/.claude/limit-interrupted-agents.jsonl"
MM="$H/.claude/limit-interrupted.jsonl"
check "a subagent line goes to the agents manifest, not the main one" \
  "[ -s '$M' ] && [ ! -s '$MM' ]"
check "recorded under the PARENT session id with the agent id" \
  "jq -e 'select(.session_id == \"parent-1\" and .agent_id == \"aaa111\" and .agent_type == \"general-purpose\")' '$M' >/dev/null"
check "cwd rewritten to the parent's (from its transcript, past a non-JSON first line), not the agent worktree" \
  "jq -e '.cwd == \"/parent/cwd\"' '$M' >/dev/null"
check "agent description and transcript path recorded" \
  "jq -e '.agent_description == \"Fix stored rebuild over-promise\" and (.agent_transcript | endswith(\"/parent-1/subagents/agent-aaa111.jsonl\"))' '$M' >/dev/null"
check "agent worktree and branch read from the meta file (worktreePath/worktreeBranch)" \
  "jq -e '.agent_worktree == \"/repo/.claude/worktrees/agent-aaa111\" and .agent_branch == \"claude/fix-rebuild\"' '$M' >/dev/null"
check "resets_at parsed from the subagent's message" "jq -e '.resets_at != null' '$M' >/dev/null"
echo "$SUB1" | run_hook "$H"
check "same subagent again: deduped" "[ \$(grep -c . '$M') -eq 1 ]"
echo "${SUB1//aaa111/bbb222}" | run_hook "$H"
check "a second subagent of the same session: its own line" \
  "[ \$(grep -c . '$M') -eq 2 ] && jq -e 'select(.agent_id == \"bbb222\")' '$M' >/dev/null"
check "no meta file: agent_worktree falls back to the payload cwd (an agent worktree), branch null" \
  "jq -e 'select(.agent_id == \"bbb222\") | .agent_worktree == \"/repo/.claude/worktrees/agent-bbb222\" and .agent_branch == null' '$M' >/dev/null"
PARENT="{\"session_id\":\"parent-1\",\"transcript_path\":\"$H/proj/parent-1.jsonl\",\"cwd\":\"/parent/cwd\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your session limit · resets 7:40pm (Europe/Madrid)\"}"
echo "$PARENT" | run_hook "$H"
check "the parent's own death goes to the MAIN manifest (agent_id null), agents file untouched" \
  "[ \$(grep -c . '$MM') -eq 1 ] && [ \$(grep -c . '$M') -eq 2 ] && jq -e 'select(.agent_id == null and .session_id == \"parent-1\")' '$MM' >/dev/null"
echo "$PARENT" | run_hook "$H"
check "the parent again: deduped per file (no 300-line manifests)" \
  "[ \$(grep -c . '$MM') -eq 1 ] && [ \$(grep -c . '$M') -eq 2 ]"
echo '{"session_id":"parent-1","agent_id":"ccc333","agent_type":"Explore","cwd":"/x","error_type":"rate_limit"}' | run_hook "$H"
check "documented field name error_type is honoured too" \
  "jq -e 'select(.agent_id == \"ccc333\") | .error == \"rate_limit\"' '$M' >/dev/null"
check "a subagent whose cwd is no worktree and has no meta file: agent_worktree stays null" \
  "jq -e 'select(.agent_id == \"ccc333\") | .agent_worktree == null' '$M' >/dev/null"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
