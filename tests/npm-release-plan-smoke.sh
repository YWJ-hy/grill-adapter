#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?grill-adapter root required}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$ROOT" init -q "$TMP/repo"
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name "Release Plan Test"
mkdir -p "$TMP/repo/skills/demo" "$TMP/repo/tests"
printf 'one\n' > "$TMP/repo/skills/demo/SKILL.md"
printf 'test\n' > "$TMP/repo/tests/example.sh"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -q -m initial
BASE="$(git -C "$TMP/repo" rev-parse HEAD)"

printf 'two\n' > "$TMP/repo/skills/demo/SKILL.md"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -q -m change
HEAD="$(git -C "$TMP/repo" rev-parse HEAD)"

PLAN="$(cd "$TMP/repo" && node "$ROOT/scripts/npm_release_plan.mjs" "$BASE" "$HEAD")"
grep -q '^release=true$' <<<"$PLAN"
grep -q '^root=true$' <<<"$PLAN"
grep -q '^obsidian=false$' <<<"$PLAN"

printf 'test-only\n' >> "$TMP/repo/tests/example.sh"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -q -m tests
TEST_HEAD="$(git -C "$TMP/repo" rev-parse HEAD)"
TEST_PLAN="$(cd "$TMP/repo" && node "$ROOT/scripts/npm_release_plan.mjs" "$HEAD" "$TEST_HEAD")"
grep -q '^release=false$' <<<"$TEST_PLAN"

mkdir -p "$TMP/repo/mcp/obsidian-wiki/src"
printf 'runtime\n' > "$TMP/repo/mcp/obsidian-wiki/src/index.ts"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -q -m runtime
RUNTIME_HEAD="$(git -C "$TMP/repo" rev-parse HEAD)"
RUNTIME_PLAN="$(cd "$TMP/repo" && node "$ROOT/scripts/npm_release_plan.mjs" "$TEST_HEAD" "$RUNTIME_HEAD")"
grep -q '^release=true$' <<<"$RUNTIME_PLAN"
grep -q '^root=true$' <<<"$RUNTIME_PLAN"
grep -q '^obsidian=true$' <<<"$RUNTIME_PLAN"

FORCED="$(cd "$TMP/repo" && node "$ROOT/scripts/npm_release_plan.mjs" "$HEAD" "$TEST_HEAD" --force)"
grep -q '^release=true$' <<<"$FORCED"
grep -q '^root=true$' <<<"$FORCED"
grep -q '^obsidian=true$' <<<"$FORCED"

printf 'npm release plan smoke OK\n'
