#!/usr/bin/env bash
set -euo pipefail

# Legacy selections and contexts are migration input only. The public scaffold seam accepts
# only an Obsidian metadata selection and produces schema v6.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPT="${TARGET_INPUT}/scripts/wiki_context_render.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SELECTION="$TMP/legacy.wiki-selection.json"
CONTEXT="$TMP/legacy.wiki-context.json"
printf '%s\n' '{"status":"ok","phase":"plan","wikiPages":[]}' > "$SELECTION"

if python3 "$SCRIPT" "$CONTEXT" --scaffold "$SELECTION" --feature-slug legacy --ticket-source manual --strict >/tmp/wiki-v5-scaffold.out 2>&1; then
  printf 'Expected legacy selection scaffold to fail\n' >&2
  exit 1
fi
grep -q 'Obsidian selection must contain wikiNotes, wikiBindings, or requiredSkills' /tmp/wiki-v5-scaffold.out
if [[ ! -f "$SELECTION" ]]; then
  printf 'Expected rejected legacy selection to remain available for migration\n' >&2
  exit 1
fi

printf '{"schemaVersion":5,"kind":"grill-adapter.wiki-context","wikiPages":[]}' > "$CONTEXT"
if python3 "$SCRIPT" "$CONTEXT" --validate-only --strict >/tmp/wiki-v5-validate.out 2>&1; then
  printf 'Expected legacy context validation to fail\n' >&2
  exit 1
fi
grep -q 'legacy contexts are migration input only' /tmp/wiki-v5-validate.out

printf 'wiki-context scaffold transition smoke test complete\n'
