#!/usr/bin/env bash
set -euo pipefail

# Smoke test for scaffold-practice-skill mechanical layer.
# Usage: bash tests/scaffold-practice-skill-smoke.sh <installed-adapter-target>
#
# Exercises the installed scaffold_practice_skill.py against a hermetic temp
# project: scaffold (open file set), discovery-card registration + companion
# index + index linkage, authorization gates, idempotency, and non-destructive
# convert (bundled files preserved, source coverage reported).

TARGET_DIR="${1:-}"
if [[ -z "$TARGET_DIR" ]]; then
  printf 'Usage: %s <installed-adapter-target>\n' "$0" >&2
  exit 1
fi
SCRIPT="$TARGET_DIR/scripts/scaffold_practice_skill.py"
if [[ ! -f "$SCRIPT" ]]; then
  printf 'Missing installed script: %s\n' "$SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0

ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_file()      { [[ -f "$2" ]] && ok "$1" || bad "$1 (missing: $2)"; }
assert_no_file()   { [[ ! -f "$2" ]] && ok "$1" || bad "$1 (should not exist: $2)"; }
assert_contains()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1 (missing: $2)"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WIKI="$TMP/.adapter/wiki"
mkdir -p "$WIKI/guides"
printf '# Project Wiki\n\n- [Guides](guides/)\n' > "$WIKI/index.md"
printf '# Guides\n\n<!-- grill-adapter:auto:start -->\n<!-- grill-adapter:auto:end -->\n' > "$WIKI/guides/index.md"

run() { python3 "$SCRIPT" --project-root "$TMP" "$@"; }

printf 'Test: scaffold creates only requested files\n'
run --json scaffold --name management-page-practices \
  --description "管理页统一布局规范" --files implement.md,review.md,scripts/check.py > /dev/null
PACK="$TMP/.claude/skills/management-page-practices"
assert_file "SKILL.md created" "$PACK/SKILL.md"
assert_file "implement.md created" "$PACK/implement.md"
assert_file "review.md created" "$PACK/review.md"
assert_file "scripts/check.py created" "$PACK/scripts/check.py"
assert_no_file "rules.md not created (not requested)" "$PACK/rules.md"
assert_contains "SKILL.md references implement.md" '`implement.md`' "$(cat "$PACK/SKILL.md")"
assert_contains "SKILL.md carries the pack version" "version: 1.0.0" "$(cat "$PACK/SKILL.md")"
if run scaffold --name invalid-version-pack --version 1.2 \
  --description "Invalid incomplete version" > /dev/null 2>&1; then
  bad "scaffold accepted a version without major.minor.patch"
else
  ok "scaffold rejected an incomplete semantic version"
fi
assert_no_file "invalid-version scaffold wrote no SKILL.md" \
  "$TMP/.claude/skills/invalid-version-pack/SKILL.md"

printf '\nTest: stage-card records a content-addressed pending registration without legacy wiki writes\n'
STAGED="$(run --json stage-card --name management-page-practices \
  --feature-slug skill-card-discovery --provider claude-code-project \
  --version 1.0.0 --roles implement,review \
  --triggers "后台管理页,CRUD,列表筛选" \
  --summary "管理页统一布局的实现与审查规范")"
assert_contains "registration is pending" '"discoveryState": "pending"' "$STAGED"
assert_contains "registration carries provider" '"provider": "claude-code-project"' "$STAGED"
assert_contains "registration carries version" '"version": "1.0.0"' "$STAGED"
assert_contains "registration carries implementer role" '"implementer"' "$STAGED"
assert_contains "registration carries reviewer role" '"reviewer"' "$STAGED"
assert_contains "registration carries a contract hash" '"contractHash": "sha256:' "$STAGED"
JOURNAL="$TMP/.adapter/context/skill-card-discovery.wiki-candidates.jsonl"
assert_file "registration journal created" "$JOURNAL"
assert_contains "journal stores structured registration" '"skillRegistration"' "$(cat "$JOURNAL")"
assert_no_file "stage-card does not write the legacy discovery index" "$WIKI/guides/skills.md"

mv "$PACK/review.md" "$TMP/review.md"
if run stage-card --name management-page-practices \
  --feature-slug invalid-pack --provider claude-code-project \
  --version 1.0.0 --roles review --triggers "review" \
  --summary "Missing router targets must fail." > /dev/null 2>&1; then
  bad "stage-card accepted a pack with a missing router target"
else
  ok "stage-card rejected an invalid pack"
fi
mv "$TMP/review.md" "$PACK/review.md"

printf '# Unreachable pack content\n' > "$PACK/orphan.md"
if run stage-card --name management-page-practices \
  --feature-slug unreachable-pack --provider claude-code-project \
  --version 1.0.0 --roles review --triggers "review" \
  --summary "Unreachable pack files must fail." > /dev/null 2>&1; then
  bad "stage-card accepted a pack file that SKILL.md cannot route to"
else
  ok "stage-card rejected unreachable pack content"
fi
rm "$PACK/orphan.md"

if run stage-card --name management-page-practices \
  --feature-slug wrong-version --provider claude-code-project \
  --version 2.0.0 --roles review --triggers "review" \
  --summary "Version drift must fail." > /dev/null 2>&1; then
  bad "stage-card accepted a version different from SKILL.md"
else
  ok "stage-card rejected version drift"
fi

cp "$PACK/SKILL.md" "$TMP/management-page-practices.SKILL.md"
sed 's/version: 1.0.0/version: 1.2/' "$TMP/management-page-practices.SKILL.md" > "$PACK/SKILL.md"
if run stage-card --name management-page-practices \
  --feature-slug invalid-semver --provider claude-code-project \
  --version 1.2 --roles review --triggers "review" \
  --summary "Versions require major.minor.patch." > /dev/null 2>&1; then
  bad "stage-card accepted a version without major.minor.patch"
else
  ok "stage-card rejected an incomplete semantic version"
fi
mv "$TMP/management-page-practices.SKILL.md" "$PACK/SKILL.md"

printf '\nTest: direct legacy index registration is retired\n'
if run register-card --name management-page-practices --authorized-create > /dev/null 2>&1; then
  bad "register-card must not retain a direct wiki write path"
else
  ok "register-card rejected"
fi
assert_no_file "retired command does not create skills.md" "$WIKI/guides/skills.md"

printf '\nTest: identical staging is idempotent\n'
STAGED_AGAIN="$(run --json stage-card --name management-page-practices \
  --feature-slug skill-card-discovery --provider claude-code-project \
  --version 1.0.0 --roles implement,review \
  --triggers "后台管理页,CRUD,列表筛选" \
  --summary "管理页统一布局的实现与审查规范")"
assert_contains "duplicate staging was skipped" '"skipped": 1' "$STAGED_AGAIN"
[[ "$(wc -l < "$JOURNAL" | tr -d ' ')" == "1" ]] \
  && ok "journal still has one event" || bad "idempotent staging appended a duplicate"

STAGED_REWORDED="$(run --json stage-card --name management-page-practices \
  --feature-slug skill-card-discovery --provider claude-code-project \
  --version 1.0.0 --roles implement,review \
  --triggers "后台管理页,CRUD,列表筛选" \
  --summary "管理页布局、筛选与操作区的一致性规范")"
assert_contains "summary-only revision staged" '"appended": 1' "$STAGED_REWORDED"
FIRST_CANDIDATE="$(printf '%s' "$STAGED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["candidateId"])')"
REWORDED_CANDIDATE="$(printf '%s' "$STAGED_REWORDED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["candidateId"])')"
[[ "$FIRST_CANDIDATE" != "$REWORDED_CANDIDATE" ]] \
  && ok "summary revision has a distinct candidate identity" \
  || bad "summary revision collided with the original candidate"

printf '\nTest: contract hash matches the shared cross-runtime path-order vector\n'
HASH_VECTOR="$TARGET_DIR/mcp/obsidian-wiki/tests/fixtures/skill-pack-hash-v1.json"
python3 - "$HASH_VECTOR" "$TMP" <<'PY'
import json
import pathlib
import sys

vector = json.load(open(sys.argv[1], encoding='utf-8'))
pack = pathlib.Path(sys.argv[2]) / '.claude' / 'skills' / vector['name']
for relative, content in vector['files'].items():
    destination = pack / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding='utf-8', newline='\n')
PY
VECTOR_HASH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["expectedHash"])' "$HASH_VECTOR")"
VECTOR_STAGED="$(run --json stage-card --name path-order \
  --feature-slug path-order --provider claude-code-project \
  --version 1.0.0 --roles review --triggers "path order review" \
  --summary "Verify cross-runtime path ordering.")"
assert_contains "Python hash matches shared vector" "\"contractHash\": \"$VECTOR_HASH\"" "$VECTOR_STAGED"

printf '\nTest: validate checks the pack without a legacy discovery index\n'
if run validate --name management-page-practices > /dev/null; then
  ok "validate ok"
else
  bad "validate should pass"
fi

printf '\nTest: convert is non-destructive and preserves bundled files\n'
SRC="$TMP/legacy/old-skill"
mkdir -p "$SRC/scripts"
printf -- '---\nname: old-skill\ndescription: legacy monolith\n---\n\n# Old Skill\n\n## Layout Rules\nrules body\n\n## Review Steps\nreview body\n' > "$SRC/SKILL.md"
printf '#!/usr/bin/env python3\nprint("lint")\n' > "$SRC/scripts/lint.py"
CONVERT_JSON="$(run --json convert --from "$SRC" --name old-skill --files rules.md,review.md)"
assert_file "converted pack scripts/lint.py preserved" "$TMP/.claude/skills/old-skill/scripts/lint.py"
assert_file "original SKILL.md intact" "$SRC/SKILL.md"
assert_contains "carried bundled file reported" "scripts/lint.py" "$CONVERT_JSON"
assert_contains "uncovered source content reported" "Layout Rules" "$CONVERT_JSON"

printf '\nTest: coverage closes after authoring\n'
{ printf '# Rules\n\n## Layout Rules\nrules body\n\n## Review Steps\nreview body\n'; } > "$TMP/.claude/skills/old-skill/rules.md"
if run validate --pack-dir "$TMP/.claude/skills/old-skill" --from "$SRC" > /dev/null; then
  ok "coverage complete after authoring"
else
  bad "coverage should be complete after authoring"
fi

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
