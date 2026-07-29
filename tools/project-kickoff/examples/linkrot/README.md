# linkrot

> Find the dead links in your site before your readers do.

Documentation rots quietly. Links go 404, redirect into parking pages, or hang for eleven seconds — and nobody notices until someone gives up and closes the tab. `linkrot` crawls your site and tells you which links are broken, which moved, and which are just slow, in a form you can put in CI.

## What it does
- Crawls every page on one host and checks every link it finds.
- Separates *dead* (gone) from *moved* (redirected) from *slow* — they need different fixes.
- Retries before accusing: a link is only reported dead after it fails three times.
- Exits non-zero when something is broken, so it works as a CI gate.

## Run it
```bash
npm install -g linkrot
linkrot https://example.com                 # human-readable report
linkrot https://example.com --format junit  # for CI
```

No API keys, no account, no config file.

## For contributors
Rules, layout and conventions live in `CLAUDE.md`; current state and next step in `STATE.md`; the why behind decisions in `docs/decisions.md`.

## License
MIT
