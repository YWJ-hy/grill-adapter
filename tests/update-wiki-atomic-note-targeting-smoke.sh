#!/usr/bin/env bash
set -euo pipefail

# Static contract smoke for the Obsidian atomic-Note targeting seam. Semantic ownership remains
# agent-led; this test prevents the documented create/update/defer rules from being removed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

SKILL="$ROOT/skills/update-wiki/SKILL.md"
TARGETING="$ROOT/skills/update-wiki/references/targeting.md"
TEMPLATES="$ROOT/skills/update-wiki/references/content-templates.md"

need "$SKILL" '### Atomic Note targeting contract'
need "$SKILL" 'same-theme refinement'
need "$SKILL" 'creates a sibling Note with a new stable `wiki_id`'
need "$SKILL" 'record `deferred` and ask the user'
need "$SKILL" 'targetWikiId`/path'
need "$TARGETING" '### Obsidian atomic Note targeting'
need "$TARGETING" 'The bridge validates the chosen operation and'
need "$TEMPLATES" 'explicit `create`/`update` decision'

for host in \
  "$ROOT/host-adapters/grill/CLAUDE.md" \
  "$ROOT/host-adapters/grill/AGENTS.md" \
  "$ROOT/host-adapters/plain/CLAUDE.md" \
  "$ROOT/host-adapters/plain/AGENTS.md"; do
  need "$host" 'explicit target decision before proposal'
  need "$host" 'same-theme refinement'
  need "$host" 'defer and ask'
done

python3 - "$SKILL" "$TARGETING" <<'PY'
import sys

skill, targeting = [open(path, encoding="utf-8").read() for path in sys.argv[1:]]
assert skill.index("### Atomic Note targeting contract") < skill.index(
    "1. Call `obsidian_wiki_propose_note_change`"
), "targeting contract must precede the proposal call"
assert "Same module,\n  directory, or code owner is not sufficient" in skill
assert "preserve the existing Note's `wiki_id`" in targeting
PY

printf 'update-wiki atomic-note targeting smoke OK\n'
