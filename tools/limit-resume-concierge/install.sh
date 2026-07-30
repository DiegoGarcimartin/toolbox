#!/bin/bash
# limit-resume-concierge installer.
# 1. Copies the hook to ~/.claude/hooks/
# 2. Adds the StopFailure hooks to ~/.claude/settings.json (with backup, idempotent)
# 3. Pre-allows the permission rules unattended runs need (idempotent, announced)
# 4. Prints the one remaining manual step: creating the scheduled task in the desktop app
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq / apt install jq)"; exit 1; }
if ! command -v claude >/dev/null; then
  echo "⚠ 'claude' CLI not found on PATH — the desktop app does NOT bundle it."
  echo "  The concierge's unattended delivery runs 'claude --resume' from Bash and"
  echo "  will fail without it. Install the CLI and re-check:"
  echo "  https://code.claude.com/docs/en/quickstart"
elif [ "$(claude auth status 2>/dev/null | jq -r '.loggedIn' 2>/dev/null)" != "true" ]; then
  echo "⚠ The 'claude' CLI is installed but NOT logged in — desktop-app login does"
  echo "  not carry over to the CLI. Run 'claude' in a terminal and do /login once,"
  echo "  then re-run this installer to confirm the check passes."
fi

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DST="$CLAUDE_DIR/hooks/limit-interrupted.sh"

# 1. Hook
mkdir -p "$CLAUDE_DIR/hooks"
cp hooks/limit-interrupted.sh "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "✓ Hook copied to $HOOK_DST"

# 2. settings.json
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak.limit-resume-concierge" ] || cp "$SETTINGS" "$SETTINGS.bak.limit-resume-concierge"
if grep -q 'limit-interrupted.sh' "$SETTINGS"; then
  echo "✓ settings.json already has the StopFailure hook (left untouched)"
else
  jq --arg cmd "$HOOK_DST" '
    .hooks //= {} | .hooks.StopFailure //= [] |
    .hooks.StopFailure += [{
      matcher: "",
      hooks: [
        {type: "command", command: $cmd, timeout: 10},
        {type: "mcp_tool", server: "scheduled-tasks", tool: "update_scheduled_task",
         input: {taskId: "limit-resume-concierge", enabled: true}, timeout: 15}
      ]
    }]' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
  echo "✓ settings.json updated (backup at $SETTINGS.bak.limit-resume-concierge)"
fi

# 3. Permissions — the concierge runs UNATTENDED: any tool call that needs an
# approval stalls the run forever AND blocks every future pass (the scheduler
# won't fire while a run is stuck). Pre-allow the minimum it needs.
# NOTE: MCP wildcard rules ("mcp__server__*") are NOT valid permission syntax
# and match nothing — the bare server name is what allows all its tools.
PERMS=(
  "mcp__scheduled-tasks"      # self-disarm (update_scheduled_task)
  "mcp__ccd_session_mgmt"     # list_sessions / send_message (when available)
  "Bash(grep *)"              # manifest cleanup
  "Bash(mv *)"                # manifest cleanup
  "Bash(claude --resume *)"   # headless fallback resume
)
added=()
for p in "${PERMS[@]}"; do
  if ! jq -e --arg p "$p" '.permissions.allow // [] | index($p)' "$SETTINGS" >/dev/null; then
    jq --arg p "$p" '.permissions //= {} | .permissions.allow //= [] | .permissions.allow += [$p]' \
      "$SETTINGS" > "$SETTINGS.tmp"
    mv "$SETTINGS.tmp" "$SETTINGS"
    added+=("$p")
  fi
done
if [ ${#added[@]} -gt 0 ]; then
  echo "✓ Pre-allowed ${#added[@]} permission rule(s) in settings.json so unattended runs don't stall:"
  printf '    %s\n' "${added[@]}"
  echo "  Remove any of them if you'd rather approve by hand — but know that a run"
  echo "  needing approval sits waiting in the app sidebar and NO further passes"
  echo "  fire until you approve or kill it."
else
  echo "✓ Permission rules already present (left untouched)"
fi

# 4. Concierge prompt with the real home path substituted in
PROMPT_OUT="$CLAUDE_DIR/limit-resume-concierge.prompt.md"
sed "s|__HOME__|$HOME|g" concierge.SKILL.md > "$PROMPT_OUT"
echo "✓ Concierge prompt generated at $PROMPT_OUT"

cat <<'EOF'

── ONE manual step left (scheduled tasks can only be created from the app) ──

Open Claude Code (desktop app) and ask it:

  "Create a scheduled task NAMED EXACTLY 'limit-resume-concierge',
   cron */5 * * * *, INITIALLY DISABLED, whose prompt is the content of the
   file ~/.claude/limit-resume-concierge.prompt.md (read it and use it as-is)."

The taskId is derived from the name (lowercase kebab-case), and the arming
hook targets the id "limit-resume-concierge" — so the name must match. Verify:
ask Claude to "list my scheduled tasks and show their taskIds"; if the id came
out different, either recreate the task with the exact name or edit the
"taskId" inside the StopFailure mcp_tool hook in ~/.claude/settings.json.

Then click "Run now" on the task ONCE: with an empty manifest it just
self-disarms, and any tool approval you grant during that run is stored on
the task and auto-applied to every future unattended run.

From then on: when you hit the usage limit, the hook records the interrupted
sessions in ~/.claude/limit-interrupted.jsonl and arms the task; as soon as
quota returns, the concierge wakes the sessions up and disarms itself.

Quick test (without waiting for a real limit):
  echo '{"session_id":"test-1","cwd":"/tmp","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"resets 2:40pm"}' | ~/.claude/hooks/limit-interrupted.sh
  cat ~/.claude/limit-interrupted.jsonl   # should contain the entry with resets_at
  # ("test-*" entries are cleaned up by the concierge itself without messaging anyone)
EOF
