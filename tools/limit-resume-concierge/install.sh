#!/bin/bash
# limit-resume-concierge installer.
# 1. Copies the hook, resume helper and sweep script to ~/.claude/hooks/
# 2. Adds the StopFailure recording hook to ~/.claude/settings.json (backup,
#    idempotent) and removes the obsolete v1 task-arming hook if present
# 3. Installs and loads the launchd agent that runs the sweep every 5 minutes
# Nothing else: no scheduled task, no permission rules, no manual steps.
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)"; exit 1; }
[ "$(uname)" = "Darwin" ] || { echo "ERROR: this tool is launchd-based; macOS only."; exit 1; }
if ! command -v claude >/dev/null; then
  echo "ERROR: 'claude' CLI not found on PATH — the desktop app does NOT bundle it."
  echo "The sweep resumes sessions with 'claude --resume'. Install the CLI first:"
  echo "https://code.claude.com/docs/en/quickstart"
  exit 1
fi
if [ "$(claude auth status 2>/dev/null | jq -r '.loggedIn' 2>/dev/null)" != "true" ]; then
  echo "⚠ The 'claude' CLI is not logged in — desktop-app login does not carry over."
  echo "  Run 'claude' in a terminal and do /login once. Installing anyway; the"
  echo "  sweep starts working as soon as the CLI is authenticated."
fi

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# 1. Scripts
mkdir -p "$CLAUDE_DIR/hooks"
cp hooks/limit-interrupted.sh "$CLAUDE_DIR/hooks/limit-interrupted.sh"
cp hooks/concierge-resume.sh  "$CLAUDE_DIR/hooks/concierge-resume.sh"
cp concierge-sweep.sh         "$CLAUDE_DIR/hooks/concierge-sweep.sh"
chmod +x "$CLAUDE_DIR/hooks/limit-interrupted.sh" \
         "$CLAUDE_DIR/hooks/concierge-resume.sh" \
         "$CLAUDE_DIR/hooks/concierge-sweep.sh"
echo "✓ Hook, resume helper and sweep script in $CLAUDE_DIR/hooks/"

# 2. settings.json: StopFailure recording hook
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak.limit-resume-concierge" ] || cp "$SETTINGS" "$SETTINGS.bak.limit-resume-concierge"
if grep -q 'limit-interrupted.sh' "$SETTINGS"; then
  echo "✓ settings.json already has the StopFailure hook"
else
  jq --arg cmd "$CLAUDE_DIR/hooks/limit-interrupted.sh" '
    .hooks //= {} | .hooks.StopFailure //= [] |
    .hooks.StopFailure += [{matcher: "", hooks: [{type: "command", command: $cmd, timeout: 10}]}]' \
    "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
  echo "✓ settings.json updated (backup at $SETTINGS.bak.limit-resume-concierge)"
fi
# v1 cleanup: drop the obsolete mcp_tool task-arming hook if present
if jq -e '[.hooks.StopFailure[]?.hooks[]? | select(.type=="mcp_tool" and (.input.taskId? == "limit-resume-concierge"))] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
  jq '(.hooks.StopFailure[]?.hooks) |= map(select((.type=="mcp_tool" and (.input.taskId? == "limit-resume-concierge")) | not))' \
    "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
  echo "✓ removed the obsolete v1 task-arming hook from settings.json"
fi

# 3. launchd agent
PLIST="$HOME/Library/LaunchAgents/com.limit-resume-concierge.plist"
mkdir -p "$HOME/Library/LaunchAgents"
CLAUDE_BIN_DIR="$(dirname "$(command -v claude)")"
sed -e "s|__HOME__|$HOME|g" -e "s|__CLAUDE_DIR__|$CLAUDE_BIN_DIR|g" \
  com.limit-resume-concierge.plist.template > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "✓ launchd agent loaded (sweeps every 5 min; idle ticks are free)"

cat <<'EOF'

Done — no manual steps. When you hit the usage limit, the hook records the
interrupted sessions in ~/.claude/limit-interrupted.jsonl; as soon as quota
returns, the next 5-min sweep resumes each one headless. Logs: per session in
~/.claude/concierge-resume-<id>.log, sweep in ~/.claude/concierge-sweep.log.

Quick test:
  echo '{"session_id":"test-1","cwd":"/tmp","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"resets 2:40pm"}' | ~/.claude/hooks/limit-interrupted.sh
  cat ~/.claude/limit-interrupted.jsonl     # entry with resets_at parsed to ISO
  bash ~/.claude/hooks/concierge-sweep.sh   # drops the test- entry, logs the pass
  tail -2 ~/.claude/concierge-sweep.log
EOF
