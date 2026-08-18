---
name: project-kickoff
description: Protocol for starting a new project with Claude Code the right way — harness before product. Use when the user starts a new project or asks to set up a repo from a spec or an idea, in any language — "new project", "kickoff", "start a repo", "nuevo proyecto", "arranca/empieza un proyecto".
---

# Project kickoff — harness first, product second

Session 1 belongs to the harness. The product starts in session 2. Do NOT scaffold app code until step 4 is done.

## 00. Tier gate (before anything else)

Two questions decide how much of this protocol applies. Ask them (or infer from the request) and say the verdict out loud:
1. **Is a second session plausible?** No → this is a **disposable** (prototype, exploration, one-off script): exit this skill — just build it. Disposables still write their ANSWERS as files (a brief, a decisions note, a README) so they can be promoted later by copying results — never by keeping code.
2. **Is a second person plausible — including future-you in 3 months?** Yes → full harness below. No, but multi-session → lite harness (CLAUDE.md + STATE.md + one supervisor).

Standing rule either way: **project knowledge lives in the repo, never in the agent's personal memory** (memory holds cross-project preferences and pointers only). If work starts as a loose file outside a repo and survives its first session, `git init` + CLAUDE.md before session 2 — that's the promotion moment people miss.

**Scale the harness to the appetite** (step 0, Q2): a weekend tool gets a lite harness; a product others may join gets the full set below. Never skip STATE.md or the spec.

## 0. Spec (skip if the user already provided one)

If the user pasted or attached a spec: do NOT interview from scratch. Grade it against the rubric below and ask ONLY about the gaps (often zero questions). Save it to `docs/spec.md`.

If there is no written spec, INTERVIEW the user (batched, one message) and draft `docs/spec.md` for their approval. Adapt the wording to the domain, drop what the user already answered, add domain-specific questions:

1. **Problem & user**: who is this for and what pain does it remove — no jargon? How is it solved today and why is that not enough?
2. **Appetite**: how much is this worth — in time, money, and calendar? (The budget shapes the scope, not the other way around.)
3. **Scope OUT first**: what are we explicitly NOT building in V1? Push for at least 5 items.
4. **Scope IN**: the 5–8 capabilities V1 must have to be worth shipping.
5. **Priority order when rules collide** (e.g. "safety > correctness > speed > elegance") — make them choose.
6. **Stack/platform constraints** and existing accounts (or "you pick, justify in decisions.md").
7. **Integrations & credentials**: which external services, and which keys/accounts can they actually get?
8. **Success, checkably**: the ONE north-star metric, what must NEVER happen (these become eval/test gates), and what "done" looks like.
9. **Autonomy**: confirm the clause — "I decide, document in decisions.md (ADR-style: decision, why, alternatives), continue; I only interrupt for blockers and scope changes." Any areas where they want to be consulted anyway?

A good spec has, non-negotiably:
- **Closed scope** with an explicit "OUT of V1" list.
- **Hard rules with a priority order** — this resolves dozens of decisions without asking.
- **Autonomy clause** — this is what buys autonomy.
- **"Done" criteria** that are checkable, not vibes.

## 1. Blocking-credentials list — FIRST message to the human

Before building anything, list every account, key or browser-step only the human can provide (API keys, cloud accounts, OAuth apps, GitHub app installs, payment providers). Ask for ALL of them upfront so they arrive in parallel with the build instead of blocking it later, drip by drip.

## 2. Harness (commit 1, before any product code)

Everything that lets someone resume the project cold MUST be versioned IN the repo. The test: **could a stranger become productive in under 30 minutes from the repo alone?**

- `CLAUDE.md` — distill the spec into ~30 token-lean lines: hard rules, priority order, commands, layout pointers ("don't re-explore"), environment gaps. Loads in EVERY future session; makes future prompts two lines long. Operational rules carry the symptom they prevent ("after adding a dep, recreate containers — the symptom is MODULE_NOT_FOUND for a package that's plainly installed"): debugging knowledge becomes repo knowledge instead of re-discovery. End it with the standing rule: "at session end, update STATE.md (done / in-flight / next step)." Skeleton: `references/claude.md`.
- `STATE.md` (repo root) — the living resume point: current state, what's in flight, the ONE next step, and a 3-line last-session summary. This is what makes cold-resume trivial for you OR anyone else. Versioned, kept current by the hook below. Skeleton: `references/state.md`.
- `README.md` + `.env.example` — the human on-ramp, PRODUCT-FIRST (CLAUDE.md is the agent's runbook): what it is / who for / value, THEN run in 5 min; credentials from step 1 persisted as `.env.example`. Skeleton: `references/readme.md`.
- `.claude/agents/` — persist the roles that hold a stable quality bar:
  - `engineering-supervisor` (VETO) and `product-supervisor` (VETO) — review-only agents, required before merging substantial changes. Their findings go to `docs/feedback/`.
  - Recurring executors whose rules don't change per brief (e.g. a UI builder carrying the design system, a DB engineer carrying the security rules). One-off briefs use built-in agents — don't over-create.
- `.claude/settings.json` Stop hook — at session end, update or append to STATE.md so resumability never depends on anyone remembering. A forcing function, not a reminder.
- **CI from commit 1** with every quality gate the spec names (lint, typecheck, tests, domain evals). Red until earned green. Nothing merges red.
- **Testing floor** (don't re-decide it per project): if the product has a web UI, a browser smoke suite exists from v0 — boots, main route renders, core flow completes — and runs pre-push and in CI. E2E depth only for flows the spec marks business-critical; pure style or layout changes need smoke only. If DOM selectors change, tests update in the same commit. Non-web products: the cheapest equivalent end-to-end check (CLI run on a fixture, API golden test).
  - **The inner dev loop is a fast unit layer with the edges stubbed** (external APIs, DB): runs in seconds with nothing booted, exercises the domain rules. E2E is a gate, never the inner loop — if verifying a change means starting the stack, iteration speed dies and verification gets skipped.
  - **Tests run against an isolated environment** (own DB/instance/test project), never against dev data. Test-only routes or resets are gated behind an env var that only the test environment sets.
  - **External API → a mock that serves the SAME fixture files the unit tests read**, so unit and E2E can't drift. Fixtures are hand-authored and each one pins a named domain edge case — mine these from the user: enumerating the weird cases is where their domain knowledge feeds the tests.
  - **Git hooks live versioned in `.githooks/`** (`git config core.hooksPath .githooks`, documented as an install command), with a documented bypass. Never unversioned `.git/hooks`, never husky — a hook that doesn't survive a fresh clone fails the 30-minute-stranger test.
- `docs/decisions.md` (append-only log: decision, why, alternatives) + `docs/backlog.md` (scope + status).
- `docs/plans/` for multi-phase features (session 2+; kickoff just creates the folder + convention note): one folder per plan, phase files named `todo-*.md` → `doing-*.md` → `done-*.md`. Status lives in the filename — `ls` shows progress cold; one `doing-` at a time. Closing a plan requires a 5-line completion summary (shipped / changed vs plan / lessons) and updating CLAUDE.md if architecture changed. That's the whole protocol — no approval gates, the autonomy clause governs.
- `.gitignore`: ignore local-only and worktree paths, but VERSION `.claude/agents/`, `.claude/skills/`, `CLAUDE.md`, `STATE.md`, `README.md` and `.claude/settings.json`.

## 3. Design before build (user-facing products)

If the product has users: personas, UX flows and design tokens FIRST, evaluated by a review agent or a synthetic panel on paper. Problems cost 10x less to fix in markdown than in code.

## 4. Build by risk order, verify per milestone

- Order layers by invariant-criticality: the riskiest, most-testable core first; UI last.
- Every data shape is defined ONCE and every other layer derives or infers it (schema → types → client). A hand-written duplicate of a shape that exists elsewhere is a bug even while it still matches — duplicates drift silently and no one reviews the drift.
- Every layer: tests green before the next layer starts.
- Supervisors review AT EACH MILESTONE, not once at the end — a milestone veto is 4 fixes; an end-of-build veto is 30.
- Every rule the user cares about must have a check that runs WITHOUT the user (tests, evals, CI gates). Autonomy = self-verification.

## 5. Shipped from commit 1 (products with a deploy target)

Launching is the repo's normal state, not an event:

- The walking skeleton deploys to a real public URL from commit 1. Env vars, domains and build differences surface on day 1 against a hello-world — not the night before showing someone. From then on, merge to main = deployed.
- **Telemetry before the first shared URL**: error capture + basic analytics wired into the harness. A launch you can't measure didn't happen — you learn neither that it broke nor that nobody came.
- **Post-deploy smoke against the production URL** (loads + core flow responds), run automatically after each deploy. Sharing a link must not require opening it first "just in case".

## 6. The user's role from session 2 on

Their messages should be: scope decisions, domain knowledge, taste calls, credentials. If they have to repeat a rule, that's a harness bug — move the rule into CLAUDE.md, an agent, or a test immediately.
