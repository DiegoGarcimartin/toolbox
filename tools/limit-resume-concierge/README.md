# limit-resume-concierge

When you hit Claude Code's 5h usage limit with several sessions working, they all die at once, mid-task. This tool records them at the moment they're cut off and, as soon as quota returns, resumes each one exactly where it left off. You do nothing — it works while you sleep, with zero approvals.

## How it works

```
usage limit ──▶ StopFailure hook ──▶ records each session in ~/.claude/limit-interrupted.jsonl
                                       (1 line per session + 1 line per killed subagent, under
                                        its parent's session id; dedupe; parsed reset time)

every 5 min ──▶ launchd runs concierge-sweep.sh (plain bash, no LLM, no app)
                      │  manifest empty → exit (free)
                      │  reset time still in the future → exit (free)
                      │  quota probe rejected → retry next tick (free)
                      │  session already revived by the desktop app → leave it alone
                      └─▶ quota back → for each session: claude --resume <uuid> -p
                          "continue where you left off" (+ the list of subagents killed
                          by the limit, which the parent must re-drive), launched from
                          the session's own cwd, detached; its lines are removed right
                          after (crash-safe)
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

That's the whole install: scripts copied, hook configured, launchd agent loaded. No manual steps, no permission rules, no scheduled tasks to create. The installer verifies the CLI and its login, and prints a self-test you can run immediately. `./test.sh` runs the tool's own tests in a sandboxed `$HOME` (no real API call), including a replay of a subagent's 429 payload through the hook and a sweep against the resulting manifest.

## Why launchd and not the app's scheduled tasks

v1 orchestrated the recovery with a desktop-app scheduled task running a Claude prompt. Three real incidents in three days killed that design, each for a different platform reason:

1. **Unattended runs stall forever on any approval — and a stalled run blocks all future passes.** We found one hanging 11 hours on a single permission prompt while the manifest filled up.
2. **`send_message` is hard-blocked in unattended sessions** ("Claude can't send cross-session messages from a session nobody is watching" — [desktop docs](https://code.claude.com/docs/en/desktop.md)). No permission rule fixes that; the direct nudge could never work.
3. **A scheduled task cannot `update_scheduled_task` itself while running** — the self-disarm call deadlocks the run, with permissions fully granted. Reproduced twice at the exact same call.

The lesson generalizes: **keep the LLM out of the recovery loop**. Everything the concierge does is deterministic — read a file, resume a session, delete a line — so v2 does it in bash under launchd, where idle ticks are free, nothing prompts, nothing deadlocks, and the desktop app doesn't even need to be open overnight. The LLM appears exactly once: *inside* each resumed session, doing the work you actually wanted finished.

## Subagents killed by the limit

A session running several subagents (the Agent tool) usually does not die alone: each subagent's API call fails with HTTP 429 too, and **subagents never resume on their own**. Their transcripts persist (`~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl`), but only the parent session can revive one, with `SendMessage` to its agentId or a relaunch.

The hook sees these deaths: Claude Code fires a `StopFailure` for each subagent, with `agent_id`/`agent_type` in the payload and the **parent's** `session_id` (verified against real payloads and the [hooks reference](https://code.claude.com/docs/en/hooks#stopfailure); `SubagentStop` does not fire on API errors). The hook records one line per subagent under its parent, with the agent's type, its description and the path to its transcript, and rewrites the line's cwd from the agent's throwaway worktree to the parent's cwd (read from the parent transcript).

The sweep groups the manifest by session and resumes the parent **once**, with a message that names each dead subagent, its last line before dying and where its transcript is, and asks the parent to check whether it already finished before re-sending it its last instruction (or relaunching it), shutting down any iOS simulator it left booted first. If the parent itself died too, the message also carries the usual "continue where you left off".

**Known limit:** the concierge cannot resume a subagent directly — there is no CLI entry point into a subagent's transcript. All it can do is tell the parent. And it can only tell a parent it resumes headless: a parent that is alive in the app already holds the subagents' failure notifications in its own context, and is left to deal with them.

## Design decisions (learned from real failures)

- **Deliver first, clean immediately after, session by session.** If the sweep dies mid-pass, everything already delivered is gone from the manifest and won't be re-sent; everything else survives for the next tick.
- **Dedupe in the hook, by (session, subagent).** A single limit event fires one StopFailure per interrupted subagent, and each one can fire more than once: one session generated 316 lines before dedupe. The hook records each session once and each of its dead subagents once.
- **A session the app already revived is left alone.** Since desktop 2.1.258 the app can revive an interrupted session by itself once the limit resets (it appends a synthetic "Continue from where you left off." turn). On 2026-09-02 the sweep resumed such a session headless one minute after the app had, and both copies ran the same builds on the same transcript. The sweep now checks the parent transcript for an app revival newer than the limit hit and, if it finds one, drops the session's lines without resuming — that live session already has everything it needs, including the subagents' failure notifications.
- **Self-guard.** The sweep's own quota probe is the one session that dies from the limit by design, every tick; its prompt carries a marker and the hook never records it. A resumed work session that hits the limit again *is* recorded again, on purpose: it still has work pending. (An earlier version checked for a string the sweep never wrote, so the guard was dead code — caught in review, covered by `test.sh` now.)
- **Non-quota failures are ignored.** Auth, billing, invalid_request… no point reviving those: they'd fail again.
- **Resume from the session's own cwd.** `claude --resume` only finds sessions of the current directory's project — the manifest records each session's cwd precisely so the sweep can `cd` there first (found live in a drill: resuming from anywhere else fails with "No conversation found").
- **Quota gating without spending.** The sweep exits free while the manifest's parsed reset time is still in the future — but only if that time is within 5h, the length of the limit window. A reset further out is a mis-parsed timezone, and trusting it would hold every pending session for up to a day; the sweep ignores it and probes instead. After the gate, a minimal probe call decides the pass — while the limit is active the probe is rejected at no cost and the sweep just retries next tick.
- **Locks expire.** The single-instance lock is a directory; a crash or reboot mid-sweep used to leave it behind and every later tick exited with "another sweep is still running", forever, silently. A sweep takes seconds, so a lock older than 10 minutes is now treated as stale and cleared.
- **The manifest loop cannot spin.** Lines are removed by literal match on the compact JSON the hook writes; a hand-edited line with different spacing could never be removed and the pass looped on it at full CPU while holding the lock. Now a line that survives its own removal is dropped by position, and the pass gives up after 50 iterations.
- **CLI auth can silently rot on macOS.** After a CLI update, the binary can lose keychain access to its stored credentials: it worked, then it didn't, and nobody touched anything. To the quota probe this looks exactly like an exhausted limit, and one expired login cost four hours of silent retries before anyone noticed. The sweep now tells the two apart: on an auth failure it logs `CLI logged out` and sends one macOS notification per incident (not one per tick). Fix: run `claude` in a terminal and `/login` once — the next tick resumes everything pending. The installer checks the login too.

## Honest limitations

- **The wake-up lands within ~5 minutes of quota returning**, not the very second (launchd ticks every 5 min).
- **The reset hour is only as good as the zone in the message.** Claude states the reset in the *account's* timezone; when the message names it (`(Europe/Madrid)`) the hook converts from that zone, otherwise it assumes the machine's local time. The sweep only uses it to skip ticks while the reset is less than 5h away; a time further out is ignored and the quota probe decides instead. A zone mismatch can therefore cost at most one 5h window of free skips, never a day.
- The resumed work continues **headless, outside the app UI**: the transcript advances (you'll see it when you reopen the session), with a per-session log in `~/.claude/concierge-resume-<uuid>.log`. Tool calls not covered by your allowlist are denied rather than prompted there.
- **A resume that fails is not retried.** The resume is launched detached and its manifest line is removed at once (that is what makes the pass crash-safe). If `claude --resume` then fails — session pruned, cwd deleted or renamed, CLI updated mid-flight — the only trace is the error in that session's `~/.claude/concierge-resume-<uuid>.log`; the sweep log just says `resuming`. Reopen the session from the app in that case.
- The Mac must be awake (plugged in, lid open or caffeinated). The desktop app, however, can be closed.
- Sweeps handle 5 sessions per tick; more simply roll over to the next tick.
- **Subagents cannot be resumed by the concierge.** It can only list them to the parent it resumes, with their last line and transcript path; the parent does the re-sending. If the parent was revived by the desktop app instead, nothing is sent at all — that session already saw the failures.
- **The app-revival check is a heuristic on the transcript.** It looks for the app's synthetic "Continue from where you left off." turn after the limit hit. If the app revives a session some other way, the sweep will still resume it headless, and the two copies will overlap as they did before this check existed.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.limit-resume-concierge.plist
rm ~/Library/LaunchAgents/com.limit-resume-concierge.plist
rm ~/.claude/hooks/limit-interrupted.sh ~/.claude/hooks/concierge-resume.sh ~/.claude/hooks/concierge-sweep.sh
rm -f ~/.claude/limit-interrupted.jsonl ~/.claude/limit-reset-at ~/.claude/stopfailure-raw.log ~/.claude/concierge-sweep.log ~/.claude/concierge-auth-alerted ~/.claude/concierge-launchd.err.log ~/.claude/concierge-resume-*.log
rm -rf ~/.claude/limit-resume-concierge.lock
```

Then remove the `StopFailure` block the installer added in `~/.claude/settings.json` (or restore `~/.claude/settings.json.bak.limit-resume-concierge`). If you're coming from v1, also delete the `limit-resume-concierge` scheduled task in the app and the five v1 `permissions.allow` rules.
