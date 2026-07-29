# Worked example — what a kickoff session produces

`linkrot/` is the harness the skill produces for a small CLI project: a tool that crawls a site and reports dead links. It is a **worked example, not a shipped product** — there is no source code here, because session 1 doesn't write any. That's the point of the skill.

What matters is that these four files exist *before* the first line of the product, and that together they answer every question a newcomer would otherwise have to ask a human:

| File | The question it kills |
|---|---|
| [`CLAUDE.md`](linkrot/CLAUDE.md) | "What are the rules here, and which one wins when two collide?" |
| [`STATE.md`](linkrot/STATE.md) | "Where did we leave off, and what's the next thing to do?" |
| [`README.md`](linkrot/README.md) | "What is this and how do I run it?" |
| [`docs/decisions.md`](linkrot/docs/decisions.md) | "Why is it built this way — did anyone consider the obvious alternative?" |

Read `STATE.md` first. If it tells you the next step and you believe it, the harness is doing its job.

## What to notice

- **`CLAUDE.md` is short on purpose.** It loads in every future session, so every line costs tokens forever. Anything an agent can infer from the code was deleted.
- **The hard rules are ranked.** "Correctness > politeness to servers > speed" resolves a dozen arguments before they happen — like whether to parallelise the crawler harder.
- **`STATE.md` names ONE next step,** not a backlog. A list of five things is a decision you've postponed.
- **`decisions.md` records what was rejected,** not just what was chosen. The rejected options are what stops someone re-litigating the same call in three months.
- **The spec closed the scope before opening it.** The "not in V1" list is longer than the feature list. This is what keeps an autonomous agent from building for three days in the wrong direction.
