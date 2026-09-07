# limit-resume-concierge

When you hit Claude Code's 5h usage limit with several sessions working, they all die at once, mid-task. This tool records them at the moment they're cut off and, as soon as quota returns, wakes each one exactly where it left off. You do nothing — it works while you sleep, with zero approvals.

## How it works

```
usage limit ──▶ StopFailure hook ──▶ records each MAIN session in ~/.claude/limit-interrupted.jsonl
                                       and each SUBAGENT killed by the limit in
                                       ~/.claude/limit-interrupted-agents.jsonl (under its parent's
                                       session id, with its worktree + branch; dedupe; parsed reset time)

every 5 min ──▶ launchd runs concierge-sweep.sh (plain bash, no LLM, no app)
                      │  manifests empty → exit (free)
                      │  reset time still in the future → exit (free)
                      │  quota probe rejected → retry next tick (free)
                      └─▶ quota back → for each session, ONE message that lists the subagents
                          the limit killed (+ "continue where you left off" if its own turn died):
                            session ALIVE (registered in ~/.claude/sessions, process running)
                              → posted INTO the live session over its inbox socket;
                                when the session is idle, Claude starts a turn with it
                            session DEAD
                              → claude --resume <uuid> -p "<message>" from its own cwd, detached,
                                waiting as long as the relaunched subagents need
                          its lines are removed right after (crash-safe)
```

Three moving pieces, all deterministic:

| Piece | Installed at |
|---|---|
| StopFailure hook ([hooks/limit-interrupted.sh](hooks/limit-interrupted.sh)) | `~/.claude/hooks/limit-interrupted.sh` + a `StopFailure` entry in `~/.claude/settings.json` |
| Sweep ([concierge-sweep.sh](concierge-sweep.sh)) | `~/.claude/hooks/concierge-sweep.sh` + launchd agent `com.limit-resume-concierge` |
| Wake-up helpers ([hooks/concierge-notify.sh](hooks/concierge-notify.sh) for live sessions, [hooks/concierge-resume.sh](hooks/concierge-resume.sh) for dead ones) | `~/.claude/hooks/` |

## Install

Requirements: macOS, Claude Code **desktop app** (its sessions are what get recorded and revived), the **`claude` CLI on PATH and logged in** — the desktop app does [not bundle it](https://code.claude.com/docs/en/desktop-quickstart.md) and desktop login does not carry over (run `/login` once in a terminal; `claude auth status` must say `loggedIn: true`) — plus `jq` and the stock `nc`.

```bash
./install.sh
```

That's the whole install: scripts copied, hook configured, launchd agent loaded. No permission rules, no scheduled tasks to create. The installer verifies the CLI and its login, and prints a self-test you can run immediately.

It asks **one question**: *do you ever run sessions in `bypassPermissions` mode?* A session in that mode holds a message from a script for your approval and drops it after five minutes, so the concierge's wake-up would never reach it overnight. Answer **yes** and the installer sets `"crossSessionInbound": "accept"` in `~/.claude/settings.json` (every session then delivers messages from your other sessions and scripts without asking); answer **no** and nothing changes, because sessions in `auto`, `default`, `acceptEdits` or `dontAsk` mode already deliver them. If the key is already set, the installer reports its value instead of asking; a value other than `accept` blocks the wake-up and is flagged. For a non-interactive install, answer through the environment: `CONCIERGE_INSTALL_BYPASS=y ./install.sh` (or `=n`); with no terminal and no answer, the key is left unset and a warning tells you how to set it. `./test.sh` runs the tool's own tests in a sandboxed `$HOME` (no real API call), including a replay of a subagent's 429 payload through the hook, a sweep that posts into a fake live session's socket, and a sweep that resumes a dead one.

## Why launchd and not the app's scheduled tasks

v1 orchestrated the recovery with a desktop-app scheduled task running a Claude prompt. Three real incidents in three days killed that design, each for a different platform reason:

1. **Unattended runs stall forever on any approval — and a stalled run blocks all future passes.** We found one hanging 11 hours on a single permission prompt while the manifest filled up.
2. **`send_message` is hard-blocked in unattended sessions** ("Claude can't send cross-session messages from a session nobody is watching" — [desktop docs](https://code.claude.com/docs/en/desktop#work-across-sessions)). No permission rule fixes that; the direct nudge could never work. Re-verified on 2026-09-07 with a one-off scheduled task: `This tool is unavailable in unattended sessions (scheduled-task runs and remote-dispatched trees)`.
3. **A scheduled task cannot `update_scheduled_task` itself while running** — the self-disarm call deadlocks the run, with permissions fully granted. Reproduced twice at the exact same call.

The lesson generalizes: **keep the LLM out of the recovery loop**. Everything the concierge does is deterministic — read a file, post a line into a socket or resume a session, delete a line — so it runs in bash under launchd, where idle ticks are free, nothing prompts, nothing deadlocks, and the desktop app doesn't even need to be open overnight. The LLM appears exactly once: *inside* each woken session, doing the work you actually wanted finished.

## Subagents killed by the limit

A session running several subagents (the Agent tool) usually does not die alone: each subagent's API call fails with HTTP 429 too, and **subagents never resume on their own**. Their transcripts persist (`~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl`), but only the parent session can revive one, by relaunching it or with `SendMessage` to its agentId.

The hook sees these deaths: Claude Code fires a `StopFailure` for each subagent, with `agent_id`/`agent_type` in the payload and the **parent's** `session_id` (verified against real payloads and the [hooks reference](https://code.claude.com/docs/en/hooks#stopfailure); `SubagentStop` does not fire on API errors). The hook records one line per subagent in the agents manifest, with the agent's type, its description, the path to its transcript and — from `agent-<id>.meta.json` next to it — the **worktree and branch it was working in**, where its uncommitted work still sits. The line's cwd is rewritten from the agent's throwaway worktree to the parent's cwd (read from the parent transcript).

The sweep groups both manifests by session and wakes the parent **once**, with a message that names each dead subagent, its worktree and branch, its last line before dying and where its transcript is, and asks the parent to check whether it already finished before relaunching it **from the same worktree** (or re-sending its last instruction), shutting down any iOS simulator it left booted first. If the parent's own turn died too, the message also carries the usual "continue where you left off".

**Known limit:** the concierge cannot resume a subagent directly — there is no CLI entry point into a subagent's transcript. All it can do is tell the parent.

## Live sessions get a message, dead sessions get a resume (v3)

The parent of a dead subagent is usually **still open in the app**: a subagent's 429 kills the subagent, not the conversation. Until v3 the sweep resumed that parent headless anyway, and the real incident of 2026-09-07 showed what that costs: `claude --resume -p` ran a *second copy* of the conversation, that copy relaunched the two dead subagents, the headless run's 10-minute ceiling on background work killed them again, and the live session in the app never saw any of it — its owner found the work still undone six hours later.

Now the sweep asks first whether the session is alive, and Claude Code itself provides both halves of the answer:

- **Liveness.** Every session registers itself in `~/.claude/sessions/<pid>.json` (`sessionId`, `pid`, `procStart`, `messagingSocketPath`). A session is alive when that pid is a running `claude` process whose start time matches the registration (pid reuse guard) and its inbox socket exists.
- **Delivery.** Each live session binds an inbox socket for cross-session messages, and the docs name it as the path for "a script or hook to post into a session" ([cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket)). `concierge-notify.sh` writes one JSON line to it — `{"type":"user","message":{"role":"user","content":"…"}}`, the shape Claude Code prints in its own debug log — with the stock `nc -U`. On macOS and Linux no auth line is needed. **When the session is idle, Claude Code starts a new turn with the message**; when it is busy, Claude reads it between tool calls. The message shows up in the app as "Message from another session", and the parent relaunches its subagents right there, in its own context, visible to you.

Only a session that is **not** alive is resumed headless, as before — and that resume now runs with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, so it waits for the subagents it relaunches instead of [exiting after 10 minutes](https://code.claude.com/docs/en/env-vars) and killing them.

The socket path was verified end to end on 2026-09-07: a fake dead-subagent line for a live session was written to the agents manifest, the launchd tick picked it up, and the message arrived in that session as a new turn.

One thing to know about **inbound controls**: the receiving session applies its `crossSessionInbound` rules to the concierge's message like to any other. With the default (no value set), a session in `auto`, `acceptEdits`, `default` or `dontAsk` mode delivers it; a session in **`bypassPermissions` mode holds it for your approval** (the dialog expires after five minutes). If you run bypass-mode sessions, set `"crossSessionInbound": "accept"` in `~/.claude/settings.json`.

## Design decisions (learned from real failures)

- **Deliver first, clean immediately after, session by session.** If the sweep dies mid-pass, everything already delivered is gone from the manifests and won't be re-sent; everything else survives for the next tick.
- **Dedupe in the hook, by (session, subagent).** A single limit event fires one StopFailure per interrupted subagent, and each one can fire more than once: one session generated 316 lines before dedupe. The hook records each session once and each of its dead subagents once.
- **Never resume a session that is alive.** See above. The older heuristic — skipping a session whose transcript shows the desktop app's own "Continue from where you left off." revival newer than the limit hit — is kept for the dead path only.
- **Self-guard.** The sweep's own quota probe is the one session that dies from the limit by design, every tick; its prompt carries a marker and the hook never records it. A woken work session that hits the limit again *is* recorded again, on purpose: it still has work pending. (An earlier version checked for a string the sweep never wrote, so the guard was dead code — caught in review, covered by `test.sh` now.)
- **Non-quota failures are ignored.** Auth, billing, invalid_request… no point reviving those: they'd fail again.
- **Resume from the session's own cwd.** `claude --resume` only finds sessions of the current directory's project — the manifest records each session's cwd precisely so the sweep can `cd` there first (found live in a drill: resuming from anywhere else fails with "No conversation found").
- **Quota gating without spending.** The sweep exits free while the manifests' parsed reset time is still in the future — but only if that time is within 5h, the length of the limit window. A reset further out is a mis-parsed timezone, and trusting it would hold every pending session for up to a day; the sweep ignores it and probes instead. After the gate, a minimal probe call decides the pass — while the limit is active the probe is rejected at no cost and the sweep just retries next tick.
- **Locks expire.** The single-instance lock is a directory; a crash or reboot mid-sweep used to leave it behind and every later tick exited with "another sweep is still running", forever, silently. A sweep takes seconds, so a lock older than 10 minutes is now treated as stale and cleared.
- **The manifest loop cannot spin.** A session's lines are removed by literal match on the compact JSON the hook writes, then by a parsed pass that also catches a hand-edited line with different spacing; lines that are not JSON with a `session_id` are dropped; and the pass gives up after 50 iterations.
- **CLI auth can silently rot on macOS.** After a CLI update, the binary can lose keychain access to its stored credentials: it worked, then it didn't, and nobody touched anything. To the quota probe this looks exactly like an exhausted limit, and one expired login cost four hours of silent retries before anyone noticed. The sweep now tells the two apart: on an auth failure it logs `CLI logged out` and sends one macOS notification per incident (not one per tick). Fix: run `claude` in a terminal and `/login` once — the next tick wakes everything pending. The installer checks the login too.

## Honest limitations

- **The wake-up lands within ~5 minutes of quota returning**, not the very second (launchd ticks every 5 min).
- **The reset hour is only as good as the zone in the message.** Claude states the reset in the *account's* timezone; when the message names it (`(Europe/Madrid)`) the hook converts from that zone, otherwise it assumes the machine's local time. The sweep only uses it to skip ticks while the reset is less than 5h away; a time further out is ignored and the quota probe decides instead. A zone mismatch can therefore cost at most one 5h window of free skips, never a day.
- **A live session must accept the message.** See the inbound-controls note above: a `bypassPermissions` session holds it for approval unless `crossSessionInbound` is `accept`. The sweep can't tell a held message from a delivered one (the socket accepts both); the session's lines are removed either way.
- **The socket's message format is not documented**, only the socket, the auth line and the delivery semantics are. The JSON shape used here is the one Claude Code prints in its own `[uds-messaging] Inject messages …` debug line (v2.1.260). If a future version changes it, the message will be refused and `concierge-notify.sh` will need the new shape.
- A dead session's work continues **headless, outside the app UI**: the transcript advances (you'll see it when you reopen the session), with a per-session log in `~/.claude/concierge-resume-<uuid>.log`. Tool calls not covered by your allowlist are denied rather than prompted there.
- **A resume that fails is not retried.** The resume is launched detached and its manifest lines are removed at once (that is what makes the pass crash-safe). If `claude --resume` then fails — session pruned, cwd deleted or renamed, CLI updated mid-flight — the only trace is the error in that session's `~/.claude/concierge-resume-<uuid>.log`; the sweep log just says `resuming`. Reopen the session from the app in that case.
- The Mac must be awake (plugged in, lid open or caffeinated). The desktop app, however, can be closed — its sessions then count as dead and are resumed headless.
- Sweeps handle 5 sessions per tick; more simply roll over to the next tick.
- **Subagents cannot be resumed by the concierge.** It can only list them to the parent, with their worktree, branch, last line and transcript path; the parent does the relaunching.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.limit-resume-concierge.plist
rm ~/Library/LaunchAgents/com.limit-resume-concierge.plist
rm ~/.claude/hooks/limit-interrupted.sh ~/.claude/hooks/concierge-resume.sh ~/.claude/hooks/concierge-notify.sh ~/.claude/hooks/concierge-sweep.sh
rm -f ~/.claude/limit-interrupted.jsonl ~/.claude/limit-interrupted-agents.jsonl ~/.claude/limit-reset-at ~/.claude/stopfailure-raw.log ~/.claude/concierge-sweep.log ~/.claude/concierge-auth-alerted ~/.claude/concierge-launchd.err.log ~/.claude/concierge-resume-*.log
rm -rf ~/.claude/limit-resume-concierge.lock
```

Then remove the `StopFailure` block the installer added in `~/.claude/settings.json` (or restore `~/.claude/settings.json.bak.limit-resume-concierge`). If you're coming from v1, also delete the `limit-resume-concierge` scheduled task in the app and the five v1 `permissions.allow` rules.
