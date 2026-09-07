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
cp hooks/concierge-notify.sh  "$CLAUDE_DIR/hooks/concierge-notify.sh"
cp concierge-sweep.sh         "$CLAUDE_DIR/hooks/concierge-sweep.sh"
chmod +x "$CLAUDE_DIR/hooks/limit-interrupted.sh" \
         "$CLAUDE_DIR/hooks/concierge-resume.sh" \
         "$CLAUDE_DIR/hooks/concierge-notify.sh" \
         "$CLAUDE_DIR/hooks/concierge-sweep.sh"
echo "✓ Hook, resume helper, live-session notifier and sweep script in $CLAUDE_DIR/hooks/"

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

# 2b. Inbound messages (v3). A live session receives the concierge's wake-up
# over its inbox socket, and applies its crossSessionInbound rules to it. With
# no value set, a session in auto / default / acceptEdits / dontAsk mode
# delivers the message, but a session in bypassPermissions mode HOLDS it for
# approval and drops it after five minutes — overnight, that is a session that
# never wakes up. The one question the installer has to ask.
ask_inbound() {
  local cur ans
  cur=$(jq -r '.crossSessionInbound // empty' "$SETTINGS" 2>/dev/null)
  if [ -n "$cur" ]; then
    case "$cur" in
      accept) echo "✓ crossSessionInbound is already \"accept\": live sessions will take the wake-up in any permission mode" ;;
      *)      echo "⚠ crossSessionInbound is \"$cur\" in $SETTINGS: live sessions will NOT take the concierge's wake-up."
              echo "  Set it to \"accept\" (or remove it) or the concierge can only wake sessions that are already dead." ;;
    esac
    return
  fi
  echo
  echo "One question. Do you ever run Claude Code sessions in bypassPermissions mode"
  echo "(claude --dangerously-skip-permissions, or the app's 'bypass' setting)?"
  echo "  A session in that mode HOLDS a message from a script for approval and drops it"
  echo "  after five minutes, so the concierge's wake-up would never reach it overnight."
  echo "  Answering yes sets \"crossSessionInbound\": \"accept\" in $SETTINGS,"
  echo "  which makes every session deliver messages from your other sessions and scripts"
  echo "  without asking. Sessions in auto / default / acceptEdits mode already deliver them."
  if [ -n "${CONCIERGE_INSTALL_BYPASS-}" ]; then
    ans="$CONCIERGE_INSTALL_BYPASS"           # non-interactive installs answer via env
  elif [ -t 0 ]; then
    read -r -p "Any bypassPermissions sessions? [y/N] " ans
  else
    echo "⚠ no terminal to ask on; leaving crossSessionInbound unset. If you use bypassPermissions"
    echo "  sessions, re-run with CONCIERGE_INSTALL_BYPASS=y or set crossSessionInbound to \"accept\" yourself."
    return
  fi
  case "$ans" in
    y|Y|yes|YES|Yes)
      jq '.crossSessionInbound = "accept"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
      echo "✓ crossSessionInbound set to \"accept\" in $SETTINGS" ;;
    *)
      echo "✓ leaving crossSessionInbound unset: your sessions deliver the wake-up as they are" ;;
  esac
}
ask_inbound

# 3. launchd agent
PLIST="$HOME/Library/LaunchAgents/com.limit-resume-concierge.plist"
mkdir -p "$HOME/Library/LaunchAgents"
CLAUDE_BIN_DIR="$(dirname "$(command -v claude)")"
sed -e "s|__HOME__|$HOME|g" -e "s|__CLAUDE_DIR__|$CLAUDE_BIN_DIR|g" \
  com.limit-resume-concierge.plist.template > "$PLIST"
if [ -n "${CONCIERGE_INSTALL_NO_LAUNCHD-}" ]; then
  echo "✓ launchd agent written to $PLIST (not loaded: CONCIERGE_INSTALL_NO_LAUNCHD set)"
else
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  echo "✓ launchd agent loaded (sweeps every 5 min; idle ticks are free)"
fi

cat <<'EOF'

Done. When you hit the usage limit, the hook records the interrupted sessions
in ~/.claude/limit-interrupted.jsonl and the subagents it killed in
~/.claude/limit-interrupted-agents.jsonl; as soon as quota returns, the next
5-min sweep posts a wake-up into each session that is still open (over its
inbox socket) and resumes headless each one that is not. Logs: sweep in
~/.claude/concierge-sweep.log, per resumed session in
~/.claude/concierge-resume-<id>.log.

Quick test:
  echo '{"session_id":"test-1","cwd":"/tmp","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"resets 2:40pm"}' | ~/.claude/hooks/limit-interrupted.sh
  cat ~/.claude/limit-interrupted.jsonl     # entry with resets_at parsed to ISO
  bash ~/.claude/hooks/concierge-sweep.sh   # drops the test- entry, logs the pass
  tail -2 ~/.claude/concierge-sweep.log
A subagent killed by the limit is recorded under its parent session (agent_id set):
  echo '{"session_id":"test-1","agent_id":"a1","agent_type":"Explore","cwd":"/tmp","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"resets 2:40pm"}' | ~/.claude/hooks/limit-interrupted.sh
  cat ~/.claude/limit-interrupted.jsonl     # one line per (session, subagent)
EOF
