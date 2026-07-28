# toolbox

Small, self-contained tools built to fix real day-to-day frictions — mostly around working with AI coding agents. Each tool lives in `tools/<name>/` with its own README and standalone install: take only what you need, ignore the rest.

## Tools

| Tool | For | What it does |
|---|---|---|
| [project-kickoff](tools/project-kickoff/) | [Claude Code](https://claude.com/claude-code) | Makes the agent spend session 1 building the project's harness — spec, `CLAUDE.md`, `STATE.md`, review agents, CI — so the project survives a cold return and a new pair of hands, instead of living in the chat history. |
| [limit-resume-concierge](tools/limit-resume-concierge/) | [Claude Code](https://claude.com/claude-code) | When you hit the 5h usage limit, it records which sessions were cut off mid-task and automatically wakes them up as soon as your quota comes back. |

## How to use this repo

There is nothing to install at the top level. Pick a tool, read its README, run its installer:

```bash
git clone https://github.com/DiegoGarcimartin/toolbox.git
cd toolbox/tools/<tool-name>
./install.sh
```

Every tool documents its own uninstall, and none of them depend on another.

## Philosophy

- **Self-contained**: each tool installs and uninstalls on its own, without touching anything else.
- **No personal data**: everything is parameterized over `$HOME`; no paths, accounts or identifiers of anyone.
- **Honest about limits**: each README has a section documenting what the tool CANNOT do and why — verified against official docs, not assumed.
- **Earned, not theorized**: every tool here exists because something broke repeatedly. The design-decision sections record the failures that shaped them.

## General requirements

- macOS or Linux, with `bash`. Some tools also need `jq` — each README states its own.
- Anything tool-specific (e.g. the Claude Code desktop app) is listed in that tool's README.

## Feedback

Bugs, ideas and "this didn't work on my setup" reports are welcome as [GitHub issues](https://github.com/DiegoGarcimartin/toolbox/issues). If a tool's *honest limitations* section is wrong or out of date, that's the most useful issue you can open.

## License

MIT — see [LICENSE](LICENSE). Built by [Diego Garcimartín](https://github.com/DiegoGarcimartin).
