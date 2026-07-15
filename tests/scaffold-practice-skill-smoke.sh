#!/usr/bin/env bash
set -euo pipefail

# Smoke test for scaffold-practice-skill mechanical layer.
# Usage: bash tests/scaffold-practice-skill-smoke.sh <installed-superpowers-target>
#
# Exercises the installed scaffold_practice_skill.py against a hermetic temp
# project: scaffold (open file set), discovery-card registration + companion
# index + index linkage, authorization gates, idempotency, and non-destructive
# convert (bundled files preserved, source coverage reported).

TARGET_DIR="${1:-}"
if [[ -z "$TARGET_DIR" ]]; then
  printf 'Usage: %s <installed-superpowers-target>\n' "$0" >&2
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
WIKI="$TMP/.superpowers/wiki"
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

printf '\nTest: register-card honors createNewDocument=ask (default)\n'
if run register-card --name management-page-practices --triggers "后台管理页, CRUD" > /dev/null 2>&1; then
  bad "unauthorized create should fail"
else
  ok "unauthorized create rejected"
fi
assert_no_file "skills.md not created without authorization" "$WIKI/guides/skills.md"

printf '\nTest: register-card with --authorized-create (规范 wiki document)\n'
run --json register-card --name management-page-practices \
  --title "管理页面统一布局" --triggers "后台管理页, CRUD, 列表筛选, 表单弹窗" \
  --summary "管理页统一布局（筛选+列表+弹窗）的实现与审查规范；命中即必须绑定 skill" \
  --authorized-create > /dev/null
assert_file "skills.md created" "$WIKI/guides/skills.md"
assert_file "companion index created" "$WIKI/guides/skills.index.md"
SKILLS_MD="$(cat "$WIKI/guides/skills.md")"
SKILLS_IDX="$(cat "$WIKI/guides/skills.index.md")"
assert_contains "card section present" "wiki-section:management-page-practices" "$SKILLS_MD"
assert_contains "card carries authored summary= attribute" 'summary="管理页统一布局' "$SKILLS_MD"
assert_contains "card requires the skill (hard)" "必须使用 skill：\`management-page-practices\`" "$SKILLS_MD"
assert_contains "companion index marks hard" "| management-page-practices |" "$SKILLS_IDX"
assert_contains "index 描述 is the authored summary verbatim" "管理页统一布局（筛选+列表+弹窗）的实现与审查规范" "$SKILLS_IDX"
assert_contains "index has canonical Sections header" "# Sections: guides/skills.md" "$SKILLS_IDX"
assert_contains "index has document overview blockquote" "> 项目最佳实践 skill 的发现目录" "$SKILLS_IDX"
assert_contains "guides/index.md lists skills.md" '`skills.md`' "$(cat "$WIKI/guides/index.md")"

printf '\nTest: register-card without --summary falls back to a theme line (not a trigger 清单)\n'
run register-card --name fallback-practice --title "回退实践" --triggers "kw-a, kw-b, kw-c" \
  --authorized-update > /dev/null
FB_MD="$(cat "$WIKI/guides/skills.md")"
assert_contains "fallback card carries a summary= attribute" 'wiki-section:fallback-practice summary="' "$FB_MD"
[[ "$FB_MD" == *'summary="kw-a, kw-b, kw-c"'* ]] && bad "fallback summary should NOT be the trigger list" || ok "fallback summary is not the trigger list"

printf '\nTest: idempotent re-register (updateExistingPage=skip default), summary marker preserved\n'
run register-card --name management-page-practices \
  --title "管理页面统一布局" --triggers "后台管理页, CRUD" \
  --summary "管理页统一布局（筛选+列表+弹窗）的实现与审查规范；命中即必须绑定 skill" > /dev/null 2>&1
OPEN_COUNT="$(grep -c '<!-- wiki-section:management-page-practices summary=' "$WIKI/guides/skills.md")"
CLOSE_COUNT="$(grep -c '<!-- /wiki-section:management-page-practices -->' "$WIKI/guides/skills.md")"
[[ "$OPEN_COUNT" == "1" && "$CLOSE_COUNT" == "1" ]] && ok "no duplicate card section" || bad "duplicate card section (open=$OPEN_COUNT close=$CLOSE_COUNT)"

printf '\nTest: register-card never mints a wiki root (mis-pointed root fails loudly)\n'
NOWIKI="$(mktemp -d)"
if python3 "$SCRIPT" --project-root "$NOWIKI" register-card --name x --authorized-create > /dev/null 2>&1; then
  bad "register-card should fail when no wiki exists"
else
  ok "register-card refused (no wiki to write into)"
fi
assert_no_file "no stray .superpowers/wiki minted" "$NOWIKI/.superpowers/wiki/index.md"
rm -rf "$NOWIKI"

printf '\nTest: running from a subdir with --project-root . anchors to the real root (no stray wiki)\n'
mkdir -p "$TMP/.claude/skills"
( cd "$TMP/.claude/skills" && python3 "$SCRIPT" --project-root . register-card \
    --name subdir-practice --title "子目录实践" --triggers "x" \
    --summary "子目录实践概述；命中即绑定 skill" --authorized-update > /dev/null 2>&1 )
assert_no_file "no stray wiki under .claude/skills" "$TMP/.claude/skills/.superpowers/wiki/index.md"
assert_contains "card landed in the real project wiki" "wiki-section:subdir-practice" "$(cat "$WIKI/guides/skills.md")"

printf '\nTest: validate happy path\n'
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
if run validate --pack-dir "$TMP/.claude/skills/old-skill" --from "$SRC" --skip-discovery > /dev/null; then
  ok "coverage complete after authoring"
else
  bad "coverage should be complete after authoring"
fi

printf '\nTest: refuse policy blocks card writes\n'
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/.superpowers/wiki"
printf '# Project Wiki\n' > "$TMP2/.superpowers/wiki/index.md"
printf '{\n  "wiki": { "updateAuthorization": { "createNewDocument": "refuse" } }\n}\n' > "$TMP2/.superpowers/settings.json"
python3 "$SCRIPT" --project-root "$TMP2" scaffold --name refused-skill > /dev/null
if python3 "$SCRIPT" --project-root "$TMP2" register-card --name refused-skill --authorized-create > /dev/null 2>&1; then
  bad "refuse policy should block even with --authorized-create"
else
  ok "refuse policy blocked"
fi
assert_no_file "no skills.md under refuse policy" "$TMP2/.superpowers/wiki/guides/skills.md"
rm -rf "$TMP2"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
