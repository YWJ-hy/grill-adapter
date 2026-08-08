#!/usr/bin/env bash
set -euo pipefail

# Static contract smoke for legacy section repartition and post-migration Obsidian Note
# maintenance. The agent still owns semantic decisions; this test protects the workflow gates.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

SKILL="$ROOT/skills/migrate-wiki/SKILL.md"
REF="$ROOT/skills/migrate-wiki/references/obsidian-note-maintenance.md"

need "$SKILL" '7. **Obsidian Note maintenance/repartition**'
need "$SKILL" 'bounded section-overload audit'
need "$SKILL" '### Legacy section repartition pass'
need "$SKILL" 'proposal-driven, not a silent automatic rewrite'
need "$SKILL" '## Mode 7: Obsidian Note maintenance/repartition'
need "$SKILL" 'Never repurpose an existing `wiki_id`'
need "$SKILL" 'propose-note-change'
need "$SKILL" 'profile legacy'
need "$SKILL" 'Load `references/obsidian-note-maintenance.md`'
need "$REF" '## Atomicity decision'
need "$REF" '## Confirmation gates'
need "$REF" 'Never delete the manifests'

# Host instructions only route to migrate-wiki. The migration skill and its reference own the
# repartition state machine, confirmation gates, and maintenance details.
need "$SKILL" 'Legacy section repartition pass'
need "$SKILL" 'Obsidian Note maintenance/repartition'
need "$SKILL" 'proposal-driven'

python3 - "$SKILL" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
assert text.index("### Legacy section repartition pass") < text.index(
    "## Mode 2: graph enrichment"
), "legacy repartition must precede graph enrichment"
assert text.index("## Mode 7: Obsidian Note maintenance/repartition") > text.index(
    "## Mode 2: graph enrichment"
), "post-migration maintenance mode must be a separate lifecycle branch"
assert "update` of the old Note plus one or more `create`" in text
assert "An open PR is not runtime" in text
PY

printf 'migrate-wiki repartition smoke OK\n'
