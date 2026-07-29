# limit-resume-concierge

When you hit Claude Code's 5h usage limit with several sessions working, they all die at once, mid-task. This tool records them at the moment they're cut off and, as soon as quota returns, a "concierge" wakes them up one by one with a "continue where you left off" message. You do nothing.

## How it works

```
usage limit ──▶ StopFailure hook ──▶ records the session in ~/.claude/limit-interrupted.jsonl
                      │                (dedupe: 1 line per session + parsed reset time)
                      └──▶ arms the "limit-resume-concierge" scheduled task

quota back ──▶ the task runs (cron every 5 min while armed)
                      │  for each pending session: send_message "continue where you left off"
                      │  and cleans ITS line from the manifest immediately (crash-safe)
                      └──▶ manifest empty → the task disarms itself
```

Three pieces:

| Piece | Where it ends up installed |
|---|---|
| StopFailure hook ([hooks/limit-interrupted.sh](hooks/limit-interrupted.sh)) | `~/.claude/hooks/limit-interrupted.sh` |
| Hooks configuration ([install.sh](install.sh) adds it) | `~/.claude/settings.json` |
| "Concierge" scheduled task ([concierge.SKILL.md](concierge.SKILL.md)) | task `limit-resume-concierge` in the app |

## Install

Requirements: Claude Code **desktop app** (uses its scheduled tasks and its session-management MCP), `bash`, `jq`. macOS or Linux.

```bash
./install.sh
```

The installer copies the hook, adds the configuration to `settings.json` (with backup, idempotent) and prints the only manual step: asking Claude in the app to create the scheduled task (tasks cannot be created from outside the app — a platform limitation).

## Design decisions (learned from real failures)

- **Session-by-session cleanup, not at the end.** The first version cleaned the manifest when the pass finished; one day the concierge died mid-pass (it hit the limit again) and left hundreds of stale traces that caused duplicate re-sends. Now each session is removed from the manifest right after it's messaged.
- **Dedupe in the hook.** A single limit event fires one StopFailure per interrupted subagent: one session generated 316 lines. The hook won't record a session already in the manifest.
- **Self-guard.** If the concierge itself dies from the limit, its run is not recorded (prevents it from trying to "resume" itself in a loop).
- **Non-quota failures are ignored.** Auth, billing, invalid_request… no point reviving those: they'd fail again.

## Honest limitations

- **The wake-up is not exact: it arrives ≤ ~8 min after the reset**, not the very minute. The hook already parses the reset time from the error (`"resets 2:40pm (Europe/Madrid)"` → ISO in the manifest and in `~/.claude/limit-reset-at`), but the platform doesn't allow using it to schedule an exact fire: an `mcp_tool` hook's input is static JSON (no templating) and there is no CLI or file through which a script can set a task's `fireAt`. What remains is the 5-min cron plus the fixed jitter (~3 min) the scheduler applies to recurring tasks. If dynamic hook inputs ever ship, the exact time is already captured and ready.
- **The reset hour is only as good as the zone in the message.** Claude states the reset in the *account's* timezone. When the message names it (`(Europe/Madrid)`) the hook converts from that zone; when it doesn't, it assumes the machine's local time. If your laptop's clock lives in a different zone than your account and the message omits the zone, `resets_at` is off by the difference. It costs nothing today — the value is recorded, not used to schedule — but don't build on it without checking.
- Only wakes **desktop app** sessions (it uses its session-management MCP).
- Manifest→session matching is by `cwd` (the manifest stores UUIDs while the session list uses `local_...` IDs): if you have several live sessions in the same directory, it wakes the most recent one.
- `send_message` asks the user for confirmation in the app for each nudge; the system semi-automates, it doesn't act behind your back.

## Uninstall

```bash
rm ~/.claude/hooks/limit-interrupted.sh ~/.claude/limit-interrupted.jsonl ~/.claude/limit-reset-at ~/.claude/stopfailure-raw.log
```

Remove the `StopFailure` block the installer added in `~/.claude/settings.json` (or restore the `.bak`) and delete the `limit-resume-concierge` scheduled task from the app.
