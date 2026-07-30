# limit-resume-concierge

When you hit Claude Code's 5h usage limit with several sessions working, they all die at once, mid-task. This tool records them at the moment they're cut off and, as soon as quota returns, a "concierge" wakes them up one by one with a "continue where you left off" message. You do nothing.

## How it works

```
usage limit ──▶ StopFailure hook ──▶ records the session in ~/.claude/limit-interrupted.jsonl
                      │                (dedupe: 1 line per session + parsed reset time)
                      └──▶ arms the "limit-resume-concierge" scheduled task

quota back ──▶ the task runs (cron every 5 min while armed)
                      │  for each pending session: nudge it — send_message when available,
                      │  otherwise headless `claude --resume <uuid> -p` (unattended fallback) —
                      │  and cleans ITS line from the manifest immediately (crash-safe)
                      └──▶ manifest empty → the task disarms itself
```

Three pieces:

| Piece | Where it ends up installed |
|---|---|
| StopFailure hook ([hooks/limit-interrupted.sh](hooks/limit-interrupted.sh)) | `~/.claude/hooks/limit-interrupted.sh` |
| Resume helper ([hooks/concierge-resume.sh](hooks/concierge-resume.sh)) | `~/.claude/hooks/concierge-resume.sh` |
| Hooks configuration ([install.sh](install.sh) adds it) | `~/.claude/settings.json` |
| "Concierge" scheduled task ([concierge.SKILL.md](concierge.SKILL.md)) | task `limit-resume-concierge` in the app |

## Install

Requirements: macOS, Claude Code **desktop app** (uses its scheduled tasks and its session-management MCP), the **`claude` CLI on PATH and logged in** — the desktop app does [not bundle it](https://code.claude.com/docs/en/desktop-quickstart.md) and desktop login does not carry over (run `/login` once in a terminal; `claude auth status` should say `loggedIn: true`); the headless fallback shells out to it and the installer checks both — plus `bash` and `jq`.

```bash
./install.sh
```

The installer copies the hook, adds the configuration to `settings.json` (with backup, idempotent), **pre-allows the permission rules the concierge needs to run unattended** (announced on screen, see below), and prints the only manual step: asking Claude in the app to create the scheduled task (tasks cannot be created from outside the app — a platform limitation).

Two gotchas on that manual step, both cheap to check:

- **Name the task exactly `limit-resume-concierge`.** The app derives the taskId from the name (lowercase kebab-case), and the arming hook targets that exact id — a different name means the hook arms a task that doesn't exist, silently. Verify by asking Claude to list your scheduled tasks with their taskIds; on mismatch, recreate with the exact name or edit the `taskId` in the StopFailure `mcp_tool` hook in `~/.claude/settings.json`.
- After creating the task, click **"Run now"** on it once: with an empty manifest it just self-disarms, and any tool approval you grant during that run is stored on the task and auto-applied to every future (unattended) run. Two minutes that de-risk the first real night.

## Unattended runs and permissions (read this)

The concierge runs as a scheduled task: **nobody is at the keyboard when it fires**. Three platform facts shape the design — each one bit us in a real incident (2026-07-29, two sessions never got resumed):

1. **An unapproved tool call stalls the run forever — and blocks every future pass.** Scheduled runs honor `permissions.allow` from `~/.claude/settings.json`; anything not allowed prompts for approval, the prompt sits in the app sidebar, and the scheduler does not fire again while a run is stuck. We found a concierge run that had been hanging on one approval for 11 hours while the manifest filled up. That's why `install.sh` pre-allows the exact rules the concierge uses (`mcp__scheduled-tasks`, `mcp__ccd_session_mgmt`, `Bash(grep *)`, `Bash(mv *)`, and the bundled resume helper). If you remove them, the system degrades to "a visible approval request waiting for you" — acceptable, but it defeats the run-while-you-sleep purpose, and a stuck run must be killed/archived by hand before passes resume.
2. **MCP wildcard permission rules are silently invalid.** `mcp__scheduled-tasks__*` matches *nothing*; the bare server name (`mcp__scheduled-tasks`) is what allows all its tools. Our own settings had the wildcard form — the allowlist looked complete and was doing nothing. Check yours.
3. **`send_message` is hard-blocked in unattended sessions** — "Claude can't send cross-session messages from a session nobody is watching" ([desktop docs](https://code.claude.com/docs/en/desktop.md)). No permission rule fixes this; it's architectural. So the skill delivers the nudge via a fallback: the bundled helper (`hooks/concierge-resume.sh`) cds to the session's recorded cwd — `claude --resume` only finds sessions of the current directory's project — and launches `claude --resume <uuid> -p "…"` detached, which continues the interrupted transcript directly. Each resume writes its output to `~/.claude/concierge-resume-<uuid>.log`, and the resumed work runs non-interactively (tool calls not covered by your allowlist are denied rather than prompted there).

## Design decisions (learned from real failures)

- **Session-by-session cleanup, not at the end.** The first version cleaned the manifest when the pass finished; one day the concierge died mid-pass (it hit the limit again) and left hundreds of stale traces that caused duplicate re-sends. Now each session is removed from the manifest right after it's messaged.
- **Dedupe in the hook.** A single limit event fires one StopFailure per interrupted subagent: one session generated 316 lines. The hook won't record a session already in the manifest.
- **Self-guard.** If the concierge itself dies from the limit, its run is not recorded (prevents it from trying to "resume" itself in a loop).
- **Non-quota failures are ignored.** Auth, billing, invalid_request… no point reviving those: they'd fail again.

## Honest limitations

- **The wake-up is not exact: it arrives ≤ ~8 min after the reset**, not the very minute. The hook already parses the reset time from the error (`"resets 2:40pm (Europe/Madrid)"` → ISO in the manifest and in `~/.claude/limit-reset-at`), but the platform doesn't allow using it to schedule an exact fire: an `mcp_tool` hook's input is static JSON (no templating) and there is no CLI or file through which a script can set a task's `fireAt`. What remains is the 5-min cron plus the fixed jitter (~3 min) the scheduler applies to recurring tasks. If dynamic hook inputs ever ship, the exact time is already captured and ready.
- **The reset hour is only as good as the zone in the message.** Claude states the reset in the *account's* timezone. When the message names it (`(Europe/Madrid)`) the hook converts from that zone; when it doesn't, it assumes the machine's local time. If your laptop's clock lives in a different zone than your account and the message omits the zone, `resets_at` is off by the difference. It costs nothing today — the value is recorded, not used to schedule — but don't build on it without checking.
- Only wakes **desktop app** sessions (it uses its session-management MCP and the shared transcripts under `~/.claude/projects/`).
- On the direct path, manifest→session matching is by `cwd` (the manifest stores UUIDs while the session list uses `local_...` IDs): if you have several live sessions in the same directory, it wakes the most recent one. The headless fallback uses the UUID directly and has no such ambiguity.
- The headless fallback continues the work outside the app UI: the transcript advances, but you won't see it typing live in the original session pane.
- **CLI auth can silently rot on macOS.** After a CLI update or reinstall, the new binary may lose keychain access to its stored credentials — macOS denies silently and `claude auth status` reports `loggedIn: false` even though the keychain item is still there. It worked, then it didn't, and nobody touched anything. Fix once: run `claude` in a terminal and either click "Always Allow" on the keychain dialog or do `/login`. The installer's auth check catches this.

## Uninstall

```bash
rm ~/.claude/hooks/limit-interrupted.sh ~/.claude/limit-interrupted.jsonl ~/.claude/limit-reset-at ~/.claude/stopfailure-raw.log
```

Remove the `StopFailure` block and the five `permissions.allow` rules the installer added in `~/.claude/settings.json` (or restore the `.bak`) and delete the `limit-resume-concierge` scheduled task from the app.
