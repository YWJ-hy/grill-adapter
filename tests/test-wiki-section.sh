#!/usr/bin/env bash
set -euo pipefail

# Smoke test for wiki section extraction (Phase 1).
# Usage: bash tests/test-wiki-section.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$ADAPTER_ROOT/scripts"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s (missing: %s)\n' "$label" "$needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s (unexpected: %s)\n' "$label" "$needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local label="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  assert_eq "$label" "$expected" "$actual"
}

# --- Setup temp wiki ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.superpowers/wiki/frontend"
cat > "$TMP/.superpowers/wiki/frontend/hook-guidelines.md" << 'WIKI'
# Hook Guidelines

Introduction paragraph.

<!-- wiki-section:path-based-update -->
## Path-Based Update

All field updates MUST use updateByPath(path, value).
Direct props.model mutation is forbidden.
<!-- /wiki-section:path-based-update -->

<!-- wiki-section:deep-path -->
## Deep Path Handling

For nested objects, use dot-notation paths.
<!-- /wiki-section:deep-path -->

<!-- wiki-section:parent-section -->
## Parent Section

Parent intro.

<!-- wiki-section:child-section -->
### Child Section

Child content here.
<!-- /wiki-section:child-section -->

Parent outro.
<!-- /wiki-section:parent-section -->
WIKI

cat > "$TMP/.superpowers/wiki/frontend/hook-guidelines.index.md" << 'WIKI'
# Hook Guidelines

> Project-private hook rules for form field updates and naming.

| section | 描述 | 约束强度 |
|---|---|---|
| path-based-update | Path-Based Update | hard |
| deep-path | Deep Path Handling | soft |
| parent-section | Parent Section | soft |
WIKI

cat > "$TMP/.superpowers/wiki/frontend/type-safety.md" << 'WIKI'
# Type Safety

<!-- wiki-section:type-imports -->
## Type Imports

使用 `import type` 保持运行时代码干净。
<!-- /wiki-section:type-imports -->
WIKI

cat > "$TMP/.superpowers/wiki/frontend/type-safety.index.md" << 'WIKI'
# Type Safety

> 中文类型安全规则。

| section | 描述 | 约束强度 |
|---|---|---|
| type-imports | Type Imports | hard |
WIKI

cat > "$TMP/.superpowers/wiki/frontend/with-code-block.md" << 'WIKI'
# Code Block Test

```markdown
<!-- wiki-section:fake-section -->
This is inside a code block and should NOT be parsed.
<!-- /wiki-section:fake-section -->
```

<!-- wiki-section:real-section -->
## Real Section

This is the real section.
<!-- /wiki-section:real-section -->
WIKI

cat > "$TMP/.superpowers/wiki/frontend/broken.md" << 'WIKI'
# Broken Markers

<!-- wiki-section:unclosed -->
## Unclosed Section

Content without closing marker.
WIKI

# --- Tests ---

printf 'Test: extract_section via CLI\n'

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "path-based-update" \
  --wiki-root project --project-root "$TMP")
assert_contains "contains updateByPath" "updateByPath(path, value)" "$OUT"
assert_contains "contains forbidden" "forbidden" "$OUT"
assert_not_contains "default output has no document context" "Wiki Constraint — Document Context" "$OUT"

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "path-based-update" \
  --wiki-root project --project-root "$TMP" --include-document-context)
assert_contains "context output has context heading" "Document Context" "$OUT"
assert_contains "context output has document title" "Document: Hook Guidelines" "$OUT"
assert_contains "context output has overview" "Project-private hook rules" "$OUT"
assert_contains "context output has section body" "updateByPath(path, value)" "$OUT"

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "deep-path" \
  --wiki-root project --project-root "$TMP")
assert_contains "deep-path contains dot-notation" "dot-notation" "$OUT"

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/with-code-block.md" "real-section" \
  --wiki-root project --project-root "$TMP" --include-document-context)
assert_contains "missing companion index still extracts" "real section" "$OUT"
assert_contains "missing companion index caveat" "companion section index not found" "$OUT"

printf '\nTest: nested sections\n'

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "parent-section" \
  --wiki-root project --project-root "$TMP")
assert_contains "parent includes child marker" "wiki-section:child-section" "$OUT"
assert_contains "parent includes parent intro" "Parent intro" "$OUT"
assert_contains "parent includes parent outro" "Parent outro" "$OUT"

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "child-section" \
  --wiki-root project --project-root "$TMP")
assert_contains "child has own content" "Child content here" "$OUT"
# Child should NOT include parent content
if [[ "$OUT" != *"Parent intro"* ]]; then
  printf '  ✓ child excludes parent content\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ child excludes parent content\n'
  FAIL=$((FAIL + 1))
fi

printf '\nTest: code block immunity\n'

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/with-code-block.md" "real-section" \
  --wiki-root project --project-root "$TMP")
assert_contains "real section extracted" "real section" "$OUT"

assert_exit_code "fake-section not found" 1 \
  python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/with-code-block.md" "fake-section" \
  --wiki-root project --project-root "$TMP"

printf '\nTest: missing section\n'

assert_exit_code "nonexistent section exits 1" 1 \
  python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "nonexistent" \
  --wiki-root project --project-root "$TMP"

printf '\nTest: batch JSONL section reads\n'

BATCH_INPUT="$TMP/rereads.jsonl"
cat > "$BATCH_INPUT" <<'JSONL'
{"root":"project","source":"local","localPath":"frontend/hook-guidelines.md","sectionId":"path-based-update","reread":{"includeDocumentContext":true}}
{"root":"project","source":"local","localPath":"frontend/type-safety.md","sectionId":"type-imports","reread":{"includeDocumentContext":true}}
JSONL
BATCH_OUT=$(python3 "$SCRIPTS/wiki_read_section.py" --batch-jsonl --project-root "$TMP" --include-document-context < "$BATCH_INPUT")
assert_contains "batch contains first section" "updateByPath(path, value)" "$BATCH_OUT"
assert_contains "batch contains second section" "import type" "$BATCH_OUT"
assert_contains "batch preserves unicode" "中文类型安全规则" "$BATCH_OUT"
assert_contains "batch labels root" "Root: \`project\`" "$BATCH_OUT"
if [[ "$BATCH_OUT" == *"updateByPath(path, value)"*"import type"* ]]; then
  printf '  ✓ batch preserves input order\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ batch preserves input order\n'
  FAIL=$((FAIL + 1))
fi

BAD_BATCH="$TMP/bad-rereads.jsonl"
cat > "$BAD_BATCH" <<'JSONL'
{"root":"project","source":"local","localPath":"frontend/hook-guidelines.md","sectionId":"missing-section"}
JSONL
BAD_BATCH_OUT="$TMP/bad-batch.out"
if python3 "$SCRIPTS/wiki_read_section.py" --batch-jsonl --project-root "$TMP" --include-document-context < "$BAD_BATCH" > /dev/null 2> "$BAD_BATCH_OUT"; then
  printf '  ✗ batch missing section exits 1\n'
  FAIL=$((FAIL + 1))
else
  printf '  ✓ batch missing section exits 1\n'
  PASS=$((PASS + 1))
fi
assert_contains "batch error has item index" "batch item 1" "$(cat "$BAD_BATCH_OUT")"
assert_contains "batch error has available sections" "Available sections: path-based-update, deep-path, parent-section, child-section" "$(cat "$BAD_BATCH_OUT")"

printf '\nTest: validation (unclosed markers)\n'

ERRORS=$(PYTHONPATH="$SCRIPTS" python3 -c "
from wiki_section import validate_section_markers
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
errors = validate_section_markers(text)
for e in errors: print(e)
" "$TMP/.superpowers/wiki/frontend/broken.md")
assert_contains "reports unclosed" "unclosed" "$ERRORS"

printf '\nTest: list_section_ids\n'

IDS=$(PYTHONPATH="$SCRIPTS" python3 -c "
from wiki_section import list_section_ids
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
for sid in list_section_ids(text): print(sid)
" "$TMP/.superpowers/wiki/frontend/hook-guidelines.md")
assert_contains "lists path-based-update" "path-based-update" "$IDS"
assert_contains "lists deep-path" "deep-path" "$IDS"
assert_contains "lists parent-section" "parent-section" "$IDS"
assert_contains "lists child-section" "child-section" "$IDS"

printf '\nTest: authored section summaries\n'

cat > "$TMP/.superpowers/wiki/frontend/summaries.md" <<'WIKI'
# Summaries
<!-- wiki-section:with-summary summary="服务端数据走服务层，不当请求缓存" -->
## Server State
body
<!-- /wiki-section:with-summary -->
<!-- wiki-section:no-summary -->
## Other
body
<!-- /wiki-section:no-summary -->
WIKI

SUMS=$(PYTHONPATH="$SCRIPTS" PYTHONIOENCODING=utf-8 python3 -c "
from wiki_section import extract_section_summaries, list_section_ids
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
s = extract_section_summaries(text)
print('IDS:', ','.join(list_section_ids(text)))
print('WITH:', s.get('with-summary', ''))
print('NO:', 'no-summary' in s)
" "$TMP/.superpowers/wiki/frontend/summaries.md")
# Backward compat: both ids still parse with the extended open-marker regex.
assert_contains "summary marker still lists both ids" "IDS: with-summary,no-summary" "$SUMS"
assert_contains "parses authored summary" "WITH: 服务端数据走服务层，不当请求缓存" "$SUMS"
assert_contains "section without summary absent from map" "NO: False" "$SUMS"

printf '\nTest: malformed summary marker is reported (not silently dropped)\n'

cat > "$TMP/.superpowers/wiki/frontend/bad-summary.md" <<'WIKI'
# Bad
<!-- wiki-section:broken-sum summary="a > b" -->
## X
body
<!-- /wiki-section:broken-sum -->
WIKI

BADSUM=$(PYTHONPATH="$SCRIPTS" python3 -c "
from wiki_section import validate_section_markers
from pathlib import Path
import sys
for e in validate_section_markers(Path(sys.argv[1]).read_text(encoding='utf-8')): print(e)
" "$TMP/.superpowers/wiki/frontend/bad-summary.md")
assert_contains "malformed marker reported" "malformed wiki-section marker" "$BADSUM"

# --- Summary ---
printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
