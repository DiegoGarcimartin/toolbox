<!-- TEMPLATE for the project's root CLAUDE.md. Loads in EVERY session — every line costs tokens forever, so delete anything an agent can infer from the code. Aim ~30 high-signal lines. Replace [brackets]; cut sections that don't apply. Terse beats complete. -->

# [Project] — what an agent must know before touching this repo

[One sentence: what this is and who it's for. No jargon.]

## Hard rules (priority order — when they collide, higher wins)
1. [e.g. safety > correctness > speed > elegance]
2. [non-negotiable, e.g. never log PII / no network in unit tests]
3. [non-negotiable, e.g. all money in integer cents]
<!-- Only the truly non-negotiable. These resolve dozens of decisions without asking. -->

## Commands
- run: `[cmd]`
- test: `[cmd]`   ← before every push
- deploy: `[cmd]`
- [lint / typecheck / eval]: `[cmd]`

## Layout (don't re-explore)
- `[path/]` — [what lives here]
- `[path/]` — [what lives here]
- entrypoint: `[file]`

## Gotchas / environment
- [the non-obvious thing that cost you an hour]
- [missing account/key, rate limit, local quirk]

## Autonomy
Decide, log it in `docs/decisions.md` (decision · why · alternatives), continue. Interrupt the human only for blockers, scope changes, or [areas to always consult].

## Working state
Current state, in-flight work and the next step live in `STATE.md` — read it first.
**At session end, update `STATE.md` (done / in-flight / next step).**
