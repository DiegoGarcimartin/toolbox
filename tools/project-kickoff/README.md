# project-kickoff

Most projects built with an AI agent die the same way: the state that matters — why this decision, what's half-done, what's next — lives in the chat, and the chat is ephemeral. Come back a month later and you're re-explaining your own project to the agent. Hand it to someone else and they can't start at all.

This skill makes Claude Code spend **session 1 on the harness, not the product**: a spec with closed scope, a `CLAUDE.md` the agent reads every session, a `STATE.md` that always answers "what's the next step", review agents with veto power, and CI from the first commit. The product starts in session 2, and from then on your messages are scope decisions and taste calls instead of repeated context.

The bar it aims at: **a stranger who clones the repo is productive in under 30 minutes, with no access to your chat history.**

## How it works

```
"start a new project"  ──▶  Claude loads the skill
                              │
                              ├─ 00. tier gate ──▶ disposable?  → exits, don't over-build
                              │                    multi-session? → lite harness
                              │                    others may join? → full harness
                              ├─ 0. spec ─────────▶ docs/spec.md  (9-question interview,
                              │                     or graded against the rubric if you
                              │                     already have one)
                              ├─ 1. credentials ──▶ every key you must fetch, asked at once
                              ├─ 2. HARNESS ──────▶ CLAUDE.md · STATE.md · README.md
                              │      (commit 1)     .claude/agents/ · Stop hook · CI · tests
                              ├─ 3. design ───────▶ flows + tokens on paper, reviewed
                              └─ 4. build ────────▶ riskiest layer first, supervisors
                                                    review at every milestone
```

Three documents, split by how fast each one changes — which is what stops them rotting together:

| File | For | Rhythm |
|---|---|---|
| `CLAUDE.md` | the agent (loaded every session) | stable rules and layout |
| `STATE.md` | cold resume, by anyone | changes every session |
| `README.md` | humans arriving at the repo | changes per release |
| `docs/decisions.md` | the *why*, append-only | changes per decision |

Templates for the first three ship in [references/](references/) and are instantiated by the skill, so the output format doesn't drift between projects.

## What it actually produces

[**`examples/linkrot/`**](examples/) is a full harness as the skill produces it — the four documents above, filled in for a small CLI project. No source code, because session 1 doesn't write any; that's the whole idea. If you only read one file, read its [`STATE.md`](examples/linkrot/STATE.md) and ask whether you could pick the project up from it cold.

## Install

Requirements: [Claude Code](https://claude.com/claude-code). No dependencies.

```bash
./install.sh
```

Copies the skill to `~/.claude/skills/project-kickoff/` so it's available in every project. Then just start a session and say *"new project: …"* — or invoke it explicitly with `/project-kickoff`.

## Design decisions (learned from real failures)

- **Harness before product.** No app code until the harness exists. The structure that makes a project survivable is cheapest to add at the start and never gets added later under delivery pressure. *Rejected:* scaffold first, document later — the documentation never happens.
- **Resume-state lives in the repo, not in the agent's memory.** An earlier version kept the resume point in the agent's personal memory. It worked beautifully for the author and was worthless to everyone else: clone the repo, get nothing. `STATE.md` is versioned; personal memory holds only cross-project preferences.
- **Maintenance is a forcing function, not a reminder.** A Stop hook updates `STATE.md` at session end. "Remember to update the doc" rots the moment you're in a hurry.
- **Scope OUT before scope IN.** The interview asks for at least 5 things V1 will *not* do before asking what it will. Open-ended scope is what makes an agent build for three days in the wrong direction.
- **Hard rules need a priority order.** "Safety > correctness > speed > elegance" resolves dozens of downstream decisions without a single question. Rules with no ranking just move the argument later.
- **A tier gate at the top.** The full harness (dual veto supervisors, paper design panel, CI from commit 1) is a tax on a weekend script. The skill asks how far this is going before deciding how much of itself to apply.
- **Templates committed, not improvised.** Reproducible output beats a slightly better format each time.
- **README is product-first.** Value before mechanics — a README is a landing page; the runbook is `CLAUDE.md`. OSS ceremony (badges, TOC, FAQ) only when earned.

## Honest limitations

- **Greenfield only.** There's no retrofit mode yet for adopting the harness into a repo that already exists. You can run it manually against one, but the skill won't guide that path.
- **The Stop hook nudges more than it writes.** Getting the agent to reliably auto-compose the session summary into `STATE.md`, rather than being prompted to, is still the weakest link.
- **The worked example is illustrative, not archaeological.** [`examples/linkrot/`](examples/) shows the shape of the output faithfully, but it was written to demonstrate the skill rather than captured from a shipped product. Judge the structure, not the project.
- **It costs a session.** That's the deal, and it's the wrong deal for anything you'll throw away — which is exactly what the tier gate at step 00 exists to catch.

## Lineage

The spec rubric is assembled from prior art rather than invented: the [Heilmeier Catechism](https://www.darpa.mil/about/heilmeier-catechism) (problem, user, checkable success), [Shape Up](https://basecamp.com/shapeup) (appetite, shaping, no-gos), and PRD conventions (goals/non-goals, ADR-style decision logs).

`CLAUDE.md` guidance follows [Anthropic's Claude Code best practices](https://code.claude.com/docs/en/best-practices): keep it short, treat it like code, only content that's worth loading in every single session.

## Uninstall

```bash
rm -rf ~/.claude/skills/project-kickoff
```
