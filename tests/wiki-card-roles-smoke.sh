#!/usr/bin/env bash
set -euo pipefail

# Smoke test for discovery-card role binding (implement / review):
#   register-card --roles writes a roles="…" marker + role-specific body sentence
#   --scaffold stamps section.roles MECHANICALLY from the local card marker (not from the selection)
#   render + reread filter by --role so a review-only card never reaches an implementer (and vice versa)
# A review-checklist skill (审查类) binds review only; an ordinary "how to build" practice binds both.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
RENDER="${TARGET_INPUT}/scripts/wiki_context_render.py"
SCAFFOLD_SKILL="${TARGET_INPUT}/scripts/scaffold_practice_skill.py"

for f in "$RENDER" "$SCAFFOLD_SKILL"; do
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
  "schemaVersion": 4,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "wikiPages": [
    {
      "root": "project", "source": "local",
      "displayPath": ".superpowers/wiki/guides/skills.md", "localPath": "guides/skills.md",
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

printf 'Part A (render/reread role filter) ok\n'

# ---------------------------------------------------------------------------
# Part B: register-card --roles -> marker -> --scaffold stamps section.roles.
# Run register-card and --scaffold from the project root so displayPath resolves.
# ---------------------------------------------------------------------------
PROJ="$TMP/project"
mkdir -p "$PROJ/.superpowers/wiki"
printf '# Project Wiki\n' > "$PROJ/.superpowers/wiki/index.md"

(
  cd "$PROJ"
  # Review-only checklist skill: only reviewers get bound.
  python3 "$SCAFFOLD_SKILL" --json register-card --name perm-review \
    --title "权限审查" --triggers "权限,审查,PermissionCodeEnumsV2" \
    --summary "权限新增/判断审查清单" --roles review --authorized-create >/dev/null
  # Ordinary "how to build" practice: binds both roles (default).
  python3 "$SCAFFOLD_SKILL" --json register-card --name list-page \
    --title "列表页模板" --triggers "列表页,表格,iho-table-wrapper" \
    --summary "列表页生成模板" --authorized-update >/dev/null
)

SKILLS_MD="$PROJ/.superpowers/wiki/guides/skills.md"
SKILLS_TEXT="$(cat "$SKILLS_MD")"
# Review-only card carries the roles attr and the review-only body sentence.
assert_contains "review card marker" 'roles="review"'           "$SKILLS_TEXT"
assert_contains "review card body"   '审查相关产物时'            "$SKILLS_TEXT"
# Default both-role card stays byte-clean: no roles attr, original both-role sentence.
assert_contains     "both card body" '实现或审查相关产物时'      "$SKILLS_TEXT"
assert_not_contains "both card marker" 'roles="implement,review"' "$SKILLS_TEXT"

# A selection that picks both cards; --scaffold must stamp roles from the marker, not the selection.
SEL="$PROJ/sel.json"
cat > "$SEL" <<'JSON'
{
  "status": "ok", "phase": "plan",
  "wikiPages": [
    {
      "root": "project", "source": "local",
      "displayPath": ".superpowers/wiki/guides/skills.md", "localPath": "guides/skills.md",
      "documentContext": {"title": "Skills", "overview": "discovery"},
      "sections": [
        {"sectionId": "perm-review", "readDepth": "full", "relevance": "direct", "confidence": "high",
         "reason": "task touches permissions", "hardConstraint": true,
         "constraints": {"implementation": [], "test": [], "review": [], "general": []}},
        {"sectionId": "list-page", "readDepth": "full", "relevance": "direct", "confidence": "high",
         "reason": "task builds a list page", "hardConstraint": true,
         "constraints": {"implementation": [], "test": [], "review": [], "general": []}}
      ]
    }
  ],
  "caveats": []
}
JSON
printf '# P\n\n### Task T1: build\nstuff\n' > "$PROJ/plan.md"

(
  cd "$PROJ"
  python3 "$RENDER" ctx.json --scaffold sel.json --plan-path plan.md --strict >/dev/null
)

python3 - "$PROJ/ctx.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
secs = {s['sectionId']: s for s in d['wikiPages'][0]['sections']}
assert secs['perm-review'].get('roles') == ['review'], secs['perm-review'].get('roles')
assert 'roles' not in secs['list-page'], secs['list-page'].get('roles')
print('scaffold stamp ok: perm-review->[review], list-page->(unrestricted)')
PY

# validate reports the pack/card cleanly for the both-role card; then a hand-corrupted
# roles token must make validate fail (the silent-widening guard).
(
  cd "$PROJ"
  mkdir -p .claude/skills/list-page
  printf -- '---\nname: list-page\ndescription: 列表页模板 skill。当需要创建列表/管理/表格页面时使用。详见 rules.md。\n---\n\nGenerated by grill-adapter.\n\n见 `rules.md`。\n' > .claude/skills/list-page/SKILL.md
  printf '# Rules\n\n规范正文。\n' > .claude/skills/list-page/rules.md
  python3 "$SCAFFOLD_SKILL" --json validate --name list-page >/dev/null
)

# Corrupt the review card's roles token and confirm validate flags it.
python3 - "$SKILLS_MD" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read().replace('roles="review"', 'roles="reviewer"')
open(p, 'w', encoding='utf-8').write(t)
PY
if ( cd "$PROJ" && python3 "$SCAFFOLD_SKILL" --json validate --name list-page >"$TMP/validate-bad.out" 2>&1 ); then
  printf 'Expected validate to fail on a malformed roles token\n%s\n' "$(cat "$TMP/validate-bad.out")" >&2
  exit 1
fi
assert_contains "validate bad roles" "section 'perm-review' has roles=" "$(cat "$TMP/validate-bad.out")"
assert_contains "validate bad roles" 'expected a non-empty subset' "$(cat "$TMP/validate-bad.out")"

printf 'Part B (marker -> scaffold stamp + validate guard) ok\n'
printf 'wiki-card-roles smoke test complete\n'
