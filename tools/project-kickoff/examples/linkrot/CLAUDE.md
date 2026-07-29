# linkrot — what an agent must know before touching this repo

A CLI that crawls a website and reports links that are dead, redirected, or slow. For people who maintain documentation sites and can't click 4,000 links by hand.

## Hard rules (priority order — when they collide, higher wins)
1. **Correctness > politeness to servers > speed.** A fast crawl that reports a live link as dead is worthless.
2. **Never report a failure from a single attempt.** Transient 5xx and timeouts are retried twice before a link is called dead.
3. **Never crawl outside the starting host** unless `--external` is passed. Checking an external link means one HEAD request, never following its links.
4. **Respect robots.txt and `Crawl-delay`.** No flag overrides this.

## Commands
- run: `linkrot https://example.com`
- test: `npm test`   ← before every push
- lint + types: `npm run check`
- fixtures: `npm run fixtures` (starts the local server the tests crawl)

## Layout (don't re-explore)
- `src/crawl/` — fetch queue, rate limiting, robots parsing
- `src/report/` — output formats (text, json, junit)
- `tests/fixtures/site/` — a deliberately broken static site the tests crawl
- entrypoint: `src/cli.ts`

## Gotchas / environment
- Tests never hit the network. If a test needs a URL, it goes in the fixture site — a networked test fails in CI and flakes locally.
- Many servers return 403 to HEAD but 200 to GET. The crawler falls back to a ranged GET; don't "simplify" that away.
- `--concurrency` above 8 gets us rate-limited by most CDNs. The default is 4 for a reason.

## Autonomy
Decide, log it in `docs/decisions.md` (decision · why · alternatives), continue. Interrupt the human only for blockers, scope changes, or anything that changes what counts as a "dead" link.

## Working state
Current state, in-flight work and the next step live in `STATE.md` — read it first.
**At session end, update `STATE.md` (done / in-flight / next step).**
