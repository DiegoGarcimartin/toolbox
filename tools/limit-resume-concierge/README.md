# limit-resume-concierge

When you hit Claude Code's 5h usage limit with several sessions working, they all die at once, mid-task. This tool records them at the moment they're cut off and, as soon as quota returns, resumes each one exactly where it left off. You do nothing — it works while you sleep, with zero approvals.

## How it works

```
usage limit ──▶ StopFailure hook ──▶ records each session in ~/.claude/limit-interrupted.jsonl
                                       (dedupe: 1 line per session + parsed reset time)

every 5 min ──▶ launchd runs concierge-sweep.sh (plain bash, no LLM, no app)
                      │  manifest empty → exit (free)
                      │  reset time still in the future → exit (free)
                      │  quota probe rejected → retry next tick (free)
                      └─▶ quota back → for each session: claude --resume <uuid> -p
                          "continue where you left off", launched from the session's
                          own cwd, detached; its line is removed right after (crash-safe)
```

Two moving pieces, both deterministic:

| Piece | Installed at |
|---|---|
| StopFailure hook ([hooks/limit-interrupted.sh](hooks/limit-interrupted.sh)) | `~/.claude/hooks/limit-interrupted.sh` + a `StopFailure` entry in `~/.claude/settings.json` |
| Sweep ([concierge-sweep.sh](concierge-sweep.sh) + [hooks/concierge-resume.sh](hooks/concierge-resume.sh)) | `~/.claude/hooks/` + launchd agent `com.limit-resume-concierge` |

## Install

Requirements: macOS, Claude Code **desktop app** (its sessions are what get recorded and revived), the **`claude` CLI on PATH and logged in** — the desktop app does [not bundle it](https://code.claude.com/docs/en/desktop-quickstart.md) and desktop login does not carry over (run `/login` once in a terminal; `claude auth status` must say `loggedIn: true`) — plus `jq`.

```bash
./install.sh
```

That's the whole install: scripts copied, hook configured, launchd agent loaded. No manual steps, no permission rules, no scheduled tasks to create. The installer verifies the CLI and its login, and prints a self-test you can run immediately.

## Why launchd and not the app's scheduled tasks

v1 orchestrated the recovery with a desktop-app scheduled task running a Claude prompt. Three real incidents in three days killed that design, each for a different platform reason:

1. **Unattended runs stall forever on any approval — and a stalled run blocks all future passes.** We found one hanging 11 hours on a single permission prompt while the manifest filled up.
2. **`send_message` is hard-blocked in unattended sessions** ("Claude can't send cross-session messages from a session nobody is watching" — [desktop docs](https://code.claude.com/docs/en/desktop.md)). No permission rule fixes that; the direct nudge could never work.
3. **A scheduled task cannot `update_scheduled_task` itself while running** — the self-disarm call deadlocks the run, with permissions fully granted. Reproduced twice at the exact same call.

The lesson generalizes: **keep the LLM out of the recovery loop**. Everything the concierge does is deterministic — read a file, resume a session, delete a line — so v2 does it in bash under launchd, where idle ticks are free, nothing prompts, nothing deadlocks, and the desktop app doesn't even need to be open overnight. The LLM appears exactly once: *inside* each resumed session, doing the work you actually wanted finished.

## Design decisions (learned from real failures)

- **Deliver first, clean immediately after, session by session.** If the sweep dies mid-pass, everything already delivered is gone from the manifest and won't be re-sent; everything else survives for the next tick.
- **Dedupe in the hook.** A single limit event fires one StopFailure per interrupted subagent: one session generated 316 lines. The hook won't record a session already in the manifest.
- **Self-guard.** Concierge-related runs are never recorded (prevents resume loops).
- **Non-quota failures are ignored.** Auth, billing, invalid_request… no point reviving those: they'd fail again.
- **Resume from the session's own cwd.** `claude --resume` only finds sessions of the current directory's project — the manifest records each session's cwd precisely so the sweep can `cd` there first (found live in a drill: resuming from anywhere else fails with "No conversation found").
- **Quota gating without spending.** The sweep exits free while the manifest's parsed reset time is still in the future; after that, a minimal probe call gates the pass — while the limit is active the probe is rejected at no cost and the sweep just retries next tick.
- **CLI auth can silently rot on macOS.** After a CLI update, the binary can lose keychain access to its stored credentials: it worked, then it didn't, and nobody touched anything. `claude auth status` says `loggedIn: false`; run `claude` and re-`/login` once. The installer checks this.

## Honest limitations

- **The wake-up lands within ~5 minutes of quota returning**, not the very second (launchd ticks every 5 min).
- **The reset hour is only as good as the zone in the message.** Claude states the reset in the *account's* timezone; when the message names it (`(Europe/Madrid)`) the hook converts from that zone, otherwise it assumes the machine's local time. The sweep only uses it to skip known-dead ticks, and the quota probe re-checks reality anyway.
- The resumed work continues **headless, outside the app UI**: the transcript advances (you'll see it when you reopen the session), with a per-session log in `~/.claude/concierge-resume-<uuid>.log`. Tool calls not covered by your allowlist are denied rather than prompted there.
- The Mac must be awake (plugged in, lid open or caffeinated). The desktop app, however, can be closed.
- Sweeps handle 5 sessions per tick; more simply roll over to the next tick.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.limit-resume-concierge.plist
rm ~/Library/LaunchAgents/com.limit-resume-concierge.plist
rm ~/.claude/hooks/limit-interrupted.sh ~/.claude/hooks/concierge-resume.sh ~/.claude/hooks/concierge-sweep.sh
rm -f ~/.claude/limit-interrupted.jsonl ~/.claude/limit-reset-at ~/.claude/stopfailure-raw.log ~/.claude/concierge-sweep.log
```

Then remove the `StopFailure` block the installer added in `~/.claude/settings.json` (or restore the `.bak`). If you're coming from v1, also delete the `limit-resume-concierge` scheduled task in the app and the five v1 `permissions.allow` rules.
