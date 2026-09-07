#!/bin/bash
# limit-resume-concierge — headless resume helper (the DEAD-session path).
# Usage: concierge-resume.sh <session-uuid> <session-cwd> <message>
#
# claude --resume only finds sessions belonging to the CURRENT directory's
# project, so we cd to the session's recorded cwd first (found in the
# 2026-07-31 drill: resuming from the task's own cwd fails with
# "No conversation found"). The resume itself is launched detached so the
# concierge pass never waits on the resumed work.
#
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0: a headless run stops waiting for
# background subagents after 10 minutes by default and exits, killing them
# mid-task (2026-09-07: "Background tasks still running after 600s;
# terminating" — the relaunched subagents died a second time). The resume is
# exactly the run that relaunches them, so it waits as long as they need.
set -u
sid="$1"; dir="$2"; msg="$3"
log="$HOME/.claude/concierge-resume-$sid.log"
echo "=== $(date -Iseconds) resume $sid (cwd: $dir)" >> "$log"
cd "$dir" 2>/dev/null || { echo "cwd no longer exists; resume will likely fail" >> "$log"; cd "$HOME"; }
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup claude --resume "$sid" -p "$msg" >> "$log" 2>&1 &
echo "launched (pid $!)" >> "$log"
