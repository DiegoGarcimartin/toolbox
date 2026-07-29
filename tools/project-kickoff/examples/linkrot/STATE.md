# STATE — linkrot

**Status:** harness complete, product not started. CI is green on an empty test suite.
**Updated:** 2026-03-14

## Next step (the ONE thing)
→ Build the fetch queue in `src/crawl/queue.ts` against the fixture site. It's the riskiest layer (rate limiting, retries, robots) and the most testable, so it goes first. UI/output formats come last.

## In flight
- [ ] Nothing. Session 1 ended at the harness boundary on purpose.

## Blockers / waiting on
- None. No credentials are needed: the tool talks to public URLs and the tests talk to a local fixture server.

## How to resume
1. Read this file + `CLAUDE.md`.
2. `npm test` should be green (it passes trivially — there are no tests yet).
3. Pick up at "Next step".

## Last sessions (newest first — 3 lines each)
### 2026-03-14
- did: spec agreed (`docs/spec.md`), harness committed, CI wired with lint + types + tests, engineering-supervisor and product-supervisor agents added.
- next: fetch queue against the fixture site.
- note: decided against a headless browser — see ADR-002. This is the decision most likely to be re-litigated later; read it before proposing Playwright.
