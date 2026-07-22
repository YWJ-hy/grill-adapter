#!/usr/bin/env bash
set -euo pipefail

# Read-only schema-v5 compatibility test for legacy discovery-card role routing.
# New Skill Cards are schema-v6 Obsidian Notes covered by obsidian-wiki-context-v6-smoke
# and obsidian-wiki-bind-smoke; the legacy index generation path is retired.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
RENDER="${TARGET_INPUT}/scripts/wiki_context_render.py"

for f in "$RENDER"; do
  if [[ ! -f "$f" ]]; then
    printf 'Missing script: %s\n' "$f" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected %s to contain %s\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'Expected %s NOT to contain %s\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Part A: render + reread filter by role (hand-authored sidecar; no files needed).
# A review-only hard card and an unrestricted (both-role) hard card, both global.
# ---------------------------------------------------------------------------
CTX="$TMP/render.wiki-context.json"
cat > "$CTX" <<'JSON'
{
  "schemaVersion": 5,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "wikiPages": [
    {
      "root": "project", "source": "local",
      "displayPath": ".adapter/wiki/guides/skills.md", "localPath": "guides/skills.md",
      "documentContext": {"title": "Skills", "overview": "discovery directory"},
      "sections": [
        {
          "sectionId": "perm-review-card", "section_name": "perm-review-card",
          "hardConstraint": true, "relevance": "direct", "roles": ["review"],
          "constraints": {"implementation": [], "test": [], "review": ["check PermissionCodeEnumsV2 usage"], "general": []},
          "reread": {"root": "project", "source": "local", "localPath": "guides/skills.md", "sectionId": "perm-review-card", "includeDocumentContext": true},
          "destination": {"kind": "global", "reason": "review-only skill card."}
        },
        {
          "sectionId": "list-page-card", "section_name": "list-page-card",
          "hardConstraint": true, "relevance": "direct",
          "constraints": {"implementation": ["use iho-table-wrapper"], "test": [], "review": [], "general": []},
          "reread": {"root": "project", "source": "local", "localPath": "guides/skills.md", "sectionId": "list-page-card", "includeDocumentContext": true},
          "destination": {"kind": "global", "reason": "binds both roles."}
        }
      ]
    }
  ],
  "taskWikiRefs": [],
  "caveats": []
}
JSON

python3 "$RENDER" "$CTX" --validate-only --strict >/dev/null

IMPL_RENDER="$(python3 "$RENDER" "$CTX" --role implementer)"
REV_RENDER="$(python3 "$RENDER" "$CTX" --role reviewer)"
assert_not_contains "implementer render" 'perm-review-card' "$IMPL_RENDER"
assert_contains     "implementer render" 'list-page-card'   "$IMPL_RENDER"
assert_contains     "reviewer render"    'perm-review-card' "$REV_RENDER"
assert_contains     "reviewer render"    'list-page-card'   "$REV_RENDER"

IMPL_RR="$(python3 "$RENDER" "$CTX" --reread-list --role implementer)"
REV_RR="$(python3 "$RENDER" "$CTX" --reread-list --role reviewer)"
assert_not_contains "implementer reread" 'perm-review-card' "$IMPL_RR"
assert_contains     "implementer reread" 'list-page-card'   "$IMPL_RR"
assert_contains     "reviewer reread"    'perm-review-card' "$REV_RR"
assert_contains     "reviewer reread"    'list-page-card'   "$REV_RR"

# Validator rejects an unknown role token (e.g. "reviewer" instead of "review").
BAD_CTX="$TMP/bad-roles.wiki-context.json"
python3 - "$CTX" "$BAD_CTX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
d['wikiPages'][0]['sections'][0]['roles'] = ['reviewer']
open(sys.argv[2], 'w', encoding='utf-8').write(json.dumps(d))
PY
if python3 "$RENDER" "$BAD_CTX" --validate-only --strict >"$TMP/bad-roles.out" 2>&1; then
  printf 'Expected validator to reject roles=["reviewer"]\n' >&2
  exit 1
fi
assert_contains "bad roles error" 'must be a non-empty subset' "$(cat "$TMP/bad-roles.out")"

printf 'wiki-card-roles schema-v5 compatibility smoke complete\n'
