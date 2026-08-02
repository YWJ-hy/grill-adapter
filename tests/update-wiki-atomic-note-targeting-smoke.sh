#!/usr/bin/env bash
set -euo pipefail

# Static contract smoke for the Capture Agent atomic-Note targeting seam. Semantic ownership stays
# agent-led; deterministic staging validates the resulting exact identity and operation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

SKILL="$ROOT/skills/update-wiki/SKILL.md"
AGENT="$ROOT/agents/wiki-capture.md"
TARGETING="$ROOT/skills/update-wiki/references/targeting.md"
TEMPLATES="$ROOT/skills/update-wiki/references/content-templates.md"

need "$SKILL" 'one isolated Capture agent'
need "$SKILL" 'references/targeting.md'
need "$SKILL" 'Never neutralize'
need "$AGENT" 'Same-theme refinements update the existing atomic Note'
need "$AGENT" 'Ambiguous ownership, contradiction, or'
need "$AGENT" 'needsDecision'
need "$TARGETING" '### Obsidian Atomic Note Targeting'
need "$TARGETING" 'same-theme refinement updates the existing Note'
need "$TARGETING" 'creates a sibling Note with a new stable `wiki_id`'
need "$TARGETING" 'Same module,'
need "$TARGETING" 'record `defer`'
need "$TARGETING" 'exact affected `sourceId` + `wikiId`'
need "$TARGETING" '`obsidian_wiki_read_notes_by_wiki_ids`'
need "$TARGETING" 'one-element `wikiIds` list'
need "$TARGETING" 'Never neutralize this candidate into a Shared Source'
need "$TEMPLATES" 'explicit `create`/`update` decision'
need "$TEMPLATES" 'current-project overlay'

python3 - "$AGENT" "$TARGETING" <<'PY'
import sys

agent, targeting = [open(path, encoding="utf-8").read() for path in sys.argv[1:]]
assert agent.count("obsidian_wiki_stage_capture_plan") >= 2
assert "Same module,\n  directory, or code owner is not sufficient" in targeting
assert "preserves its stable `wiki_id`" in targeting
PY

printf 'update-wiki atomic-note targeting smoke OK\n'
