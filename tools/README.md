# tools

One directory per tool. Each is self-contained: its own README, its own `install.sh`, its own uninstall. Nothing here depends on anything else here.

| Tool | What it does |
|---|---|
| [project-kickoff](project-kickoff/) | Makes Claude Code spend session 1 building the project's harness — spec, `CLAUDE.md`, `STATE.md`, review agents, CI — so the project survives a cold return and a new pair of hands. |
| [limit-resume-concierge](limit-resume-concierge/) | Records the sessions killed mid-task by the 5h usage limit and wakes them up as soon as quota returns. |

Start from the tool's own README — it explains the problem it solves, how it works, and what it deliberately cannot do.
