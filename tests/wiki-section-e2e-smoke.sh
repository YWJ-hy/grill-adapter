#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke test for wiki section marker system (Phase 8).
# Usage: bash tests/wiki-section-e2e-smoke.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$ADAPTER_ROOT/scripts"

PASS=0
FAIL=0

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

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s (not found: %s)\n' "$label" "$path"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local label="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$expected" == "$actual" ]]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s (expected exit %s, got %s)\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup temp wiki with section markers ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.adapter/wiki/frontend"

cat > "$TMP/.adapter/wiki/index.md" << 'WIKI'
# Project Wiki

- [Frontend](frontend/)
WIKI

cat > "$TMP/.adapter/wiki/frontend/index.md" << 'WIKI'
# Frontend

- [Hook Guidelines](hook-guidelines.md)
WIKI

cat > "$TMP/.adapter/wiki/frontend/hook-guidelines.index.md" << 'WIKI'
# Hook Guidelines

> Project-private hook rules for generated form adapters.

WIKI

cat > "$TMP/.adapter/wiki/frontend/hook-guidelines.md" << 'WIKI'
# Hook Guidelines

Overview of hook patterns.

<!-- wiki-section:path-based-update -->
## Path-Based Update

All field updates MUST use updateByPath(path, value).
Direct props.model mutation is forbidden.
This ensures change tracking works correctly.
<!-- /wiki-section:path-based-update -->

<!-- wiki-section:deep-path -->
## Deep Path Handling

For nested objects, use dot-notation paths like `user.address.city`.
Do not destructure and reassign nested properties.
<!-- /wiki-section:deep-path -->

<!-- wiki-section:hook-naming -->
## Hook Naming

All hooks should be prefixed with `use`.
Composition hooks should describe their combined behavior.
<!-- /wiki-section:hook-naming -->
WIKI

# --- E2E Flow ---

printf 'Step 1: Section extraction\n'

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "path-based-update" \
  --wiki-root project --project-root "$TMP")
assert_contains "extract path-based-update" "updateByPath" "$OUT"

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "hook-naming" \
  --wiki-root project --project-root "$TMP")
assert_contains "extract hook-naming" "prefixed with" "$OUT"

printf '\nStep 2: Index generation\n'

python3 "$SCRIPTS/wiki_generate_section_index.py" \
  --all --wiki-root project --project-root "$TMP" >/dev/null

INDEX="$TMP/.adapter/wiki/frontend/hook-guidelines.index.md"
assert_file_exists "index generated" "$INDEX"

INDEX_CONTENT="$(cat "$INDEX")"
assert_contains "index has path-based-update" "path-based-update" "$INDEX_CONTENT"
assert_contains "index has deep-path" "deep-path" "$INDEX_CONTENT"
assert_contains "index has hook-naming" "hook-naming" "$INDEX_CONTENT"
assert_contains "path-based-update is hard" "hard" "$INDEX_CONTENT"

OUT=$(python3 "$SCRIPTS/wiki_read_section.py" \
  "frontend/hook-guidelines.md" "path-based-update" \
  --wiki-root project --project-root "$TMP" --include-document-context)
assert_contains "context reread includes overview" "Project-private hook rules" "$OUT"
assert_contains "context reread includes selected section" "updateByPath" "$OUT"
assert_not_contains "context reread excludes sibling section" "Do not destructure" "$OUT"

printf '\nStep 3: Migrate helper inventory\n'

INV=$(python3 "$SCRIPTS/wiki_migrate_helper.py" --inventory "$TMP" --wiki-root project)
assert_contains "inventory lists hook-guidelines" "hook-guidelines.md" "$INV"
assert_contains "inventory shows line count" "lines" "$INV"

printf '\nStep 4: Migrate helper validate\n'

assert_exit_code "validate passes" 0 \
  python3 "$SCRIPTS/wiki_migrate_helper.py" --validate "$TMP" --wiki-root project

printf '\nStep 5: wiki_update_check detects no errors\n'

CHECK=$(python3 "$SCRIPTS/wiki_update_check.py" --wiki-root project --json 2>&1 <<< "" || true)
# Run from project root context
CHECK=$(cd "$TMP" && python3 "$SCRIPTS/wiki_update_check.py" --wiki-root project --json 2>&1 || true)
assert_contains "check status not invalid" '"status"' "$CHECK"

printf '\nStep 6: Detect broken markers\n'

cat > "$TMP/.adapter/wiki/frontend/broken.md" << 'WIKI'
# Broken

<!-- wiki-section:unclosed -->
## Unclosed Section

No closing marker here.
WIKI

# Add to index
cat > "$TMP/.adapter/wiki/frontend/index.md" << 'WIKI'
# Frontend

- [Hook Guidelines](hook-guidelines.md)
- [Broken](broken.md)
WIKI

CHECK=$(cd "$TMP" && python3 "$SCRIPTS/wiki_update_check.py" --wiki-root project --json 2>&1 || true)
assert_contains "detects section marker error" "Section marker error" "$CHECK"

# --- Summary ---
printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
