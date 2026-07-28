#!/bin/bash
# limit-resume-concierge installer.
# 1. Copies the hook to ~/.claude/hooks/
# 2. Adds the StopFailure hooks to ~/.claude/settings.json (with backup, idempotent)
# 3. Prints the one remaining manual step: creating the scheduled task in the desktop app
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq / apt install jq)"; exit 1; }

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
if grep -q 'limit-interrupted.sh' "$SETTINGS"; then
  echo "✓ settings.json already has the StopFailure hook (left untouched)"
else
  cp "$SETTINGS" "$SETTINGS.bak.limit-resume-concierge"
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

# 3. Concierge prompt with the real home path substituted in
PROMPT_OUT="$CLAUDE_DIR/limit-resume-concierge.prompt.md"
sed "s|__HOME__|$HOME|g" concierge.SKILL.md > "$PROMPT_OUT"
echo "✓ Concierge prompt generated at $PROMPT_OUT"

cat <<'EOF'

── ONE manual step left (scheduled tasks can only be created from the app) ──

Open Claude Code (desktop app) and ask it:

  "Create a scheduled task with the exact taskId 'limit-resume-concierge',
   cron */5 * * * *, INITIALLY DISABLED, whose prompt is the content of the
   file ~/.claude/limit-resume-concierge.prompt.md (read it and use it as-is)."

From then on: when you hit the usage limit, the hook records the interrupted
sessions in ~/.claude/limit-interrupted.jsonl and arms the task; as soon as
quota returns, the concierge wakes the sessions up and disarms itself.

Quick test (without waiting for a real limit):
  echo '{"session_id":"test-1","cwd":"/tmp","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"resets 2:40pm"}' | ~/.claude/hooks/limit-interrupted.sh
  cat ~/.claude/limit-interrupted.jsonl   # should contain the entry with resets_at
  # ("test-*" entries are cleaned up by the concierge itself without messaging anyone)
EOF
