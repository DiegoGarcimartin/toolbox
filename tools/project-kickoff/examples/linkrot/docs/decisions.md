# Decisions — linkrot

Append-only. Decision · why · alternatives rejected. Newest at the bottom.

## ADR-001 — A link is dead only after three failures
**Decision:** transient failures (timeouts, 5xx, connection resets) are retried twice with backoff before a link is reported dead. 4xx other than 429 is believed immediately.
**Why:** the product's whole value is trust. One false "dead" and the user stops believing the report, which is worse than missing a real break — they'll re-check by hand either way.
**Rejected:** report everything and let the user judge. Cheaper to build, but it moves the hard part onto the person we're trying to help.

## ADR-002 — No headless browser
**Decision:** plain HTTP fetches and HTML parsing. Links injected by client-side JavaScript are not seen.
**Why:** a browser multiplies runtime by ~20x and drags in a 300MB dependency, for link sets that on documentation sites are almost entirely server-rendered. The appetite for V1 was one weekend.
**Rejected:** Playwright. Reconsider if users report real misses on JS-rendered docs — that's the signal to revisit, not general unease about coverage. Until then this is the decision most likely to be re-argued from first principles; don't.

## ADR-003 — Concurrency defaults to 4
**Decision:** four in-flight requests, configurable up to 8, hard-capped there.
**Why:** measured against three CDNs, 8+ reliably triggered rate limiting, which produces exactly the false "dead" verdicts ADR-001 exists to prevent. Speed loses to correctness by the priority order in `CLAUDE.md`.
**Rejected:** unbounded concurrency with adaptive backoff. More elegant, and it makes the failure mode harder to reason about for a marginal gain on a tool that runs in CI overnight.

## ADR-004 — `robots.txt` is not overridable
**Decision:** no `--ignore-robots` flag, ever.
**Why:** the tool would otherwise be a trivially weaponised crawler, and "my CI hammered your server" is not a support burden worth taking on.
**Rejected:** a flag guarded by a scary warning. Warnings get copy-pasted past.
