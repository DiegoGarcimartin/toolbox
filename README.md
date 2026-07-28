# toolbox

Small, self-contained tools built to fix real day-to-day frictions. Each tool lives in `tools/<name>/` with its own README and standalone install — take only what you need.

## Tools

| Tool | For | What it does |
|---|---|---|
| [limit-resume-concierge](tools/limit-resume-concierge/) | [Claude Code](https://claude.com/claude-code) | When you hit the 5h usage limit, it records which sessions were cut off mid-task and automatically wakes them up as soon as your quota comes back. |

## Philosophy

- **Self-contained**: each tool installs and uninstalls on its own, without touching anything else.
- **No personal data**: everything is parameterized over `$HOME`; no paths, accounts, or identifiers of anyone.
- **Honest about platform limits**: each README documents what the tool CANNOT do and why (verified against official docs, not assumed).

## General requirements

- macOS or Linux, `bash` and `jq`.
- Anything tool-specific (e.g. the Claude Code desktop app) is listed in each tool's README.

## License

MIT — see [LICENSE](LICENSE).
