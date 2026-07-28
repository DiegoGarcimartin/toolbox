#!/bin/bash
# project-kickoff installer.
# Copies the skill to ~/.claude/skills/project-kickoff/ so it is available in every project.
set -euo pipefail
cd "$(dirname "$0")"

DST="$HOME/.claude/skills/project-kickoff"

if [ -e "$DST" ] && [ ! -L "$DST" ]; then
  BACKUP="$DST.bak.$(date +%Y%m%d%H%M%S)"
  mv "$DST" "$BACKUP"
  echo "✓ Existing skill backed up to $BACKUP"
fi

mkdir -p "$DST/references"
cp SKILL.md "$DST/SKILL.md"
cp references/claude.md references/state.md references/readme.md "$DST/references/"

echo "✓ Skill installed at $DST"
echo
echo "Start a new session and say \"new project: ...\", or invoke it with /project-kickoff."
echo "To uninstall: rm -rf $DST"
