#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REMOTE="$TMP_DIR/remote.git"
WORK="$TMP_DIR/work"
CACHE="$TMP_DIR/cache"
CONFIG="$TMP_DIR/config.json"

to_node_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -am "$1"
  else
    printf '%s' "$1"
  fi
}

git init --bare "$REMOTE" >/dev/null
git clone "$REMOTE" "$WORK" >/dev/null
cat > "$WORK/index.md" <<'MD'
# Shared Wiki

- [Guide](guide.md)
MD
cat > "$WORK/guide.md" <<'MD'
# Guide

Reusable shared rule.
MD
cat > "$WORK/guide.index.md" <<'MD'
# Guide Sections

> Shared guide rules used by smoke tests.

| section | 描述 | 约束强度 |
|---|---|---|
| guide-rule | Guide rule | hard |
MD
git -C "$WORK" add .
git -C "$WORK" commit -m "Seed shared wiki" >/dev/null
git -C "$WORK" branch -M main
git -C "$WORK" push origin main >/dev/null

REMOTE_CONFIG="$(to_node_path "$REMOTE")"
CACHE_CONFIG="$(to_node_path "$CACHE")"
cat > "$CONFIG" <<JSON
{
  "repoUrl": "$REMOTE_CONFIG",
  "baseBranch": "main",
  "cacheDir": "$CACHE_CONFIG"
}
JSON

# Run against src via tsx: `npm run build` is now an esbuild bundle (one dist/index.js), so
# the per-module dist/*.js files this used to import no longer exist.
(cd "$ROOT_DIR/mcp/shared-wiki" && npm install >/dev/null)

(
  cd "$ROOT_DIR"
  SHARED_WIKI_MCP_CONFIG="$CONFIG" "$ROOT_DIR/mcp/shared-wiki/node_modules/.bin/tsx" --input-type=module <<'JS'
import { loadConfig } from './mcp/shared-wiki/src/config.js';
import { validatePatchTool } from './mcp/shared-wiki/src/tools/validatePatch.js';
import { applyPatch, commitAll, createBranch, fetchBase, pushBranch } from './mcp/shared-wiki/src/git.js';
const config = loadConfig(process.env);
const patch = `diff --git a/guide.md b/guide.md
index 3b155d1..8bbbf1f 100644
--- a/guide.md
+++ b/guide.md
@@ -1,3 +1,5 @@
 # Guide

 Reusable shared rule.
+
+Use neutral shared language.
`;
const validation = await validatePatchTool(config, { patch, authorizedUpdate: true });
if (!validation.ok) throw new Error(validation.errors.join('\n'));
await fetchBase(config);
await createBranch(config, 'shared-wiki/test-smoke');
await applyPatch(config, patch);
await commitAll(config, 'Test shared wiki MCP branch flow');
await pushBranch(config, 'shared-wiki/test-smoke');
JS
)

git clone "$REMOTE" "$TMP_DIR/check" >/dev/null
git -C "$TMP_DIR/check" fetch origin shared-wiki/test-smoke >/dev/null
git -C "$TMP_DIR/check" rev-parse --verify origin/shared-wiki/test-smoke >/dev/null

if [[ "${SHARED_WIKI_MCP_REAL_GITHUB:-}" == "1" ]]; then
  gh auth status >/dev/null
  printf 'Real GitHub draft PR smoke is enabled but must be run manually against https://github.com/YWJ-hy/shared-wiki.git to avoid accidental external PRs in default self-test.\n'
fi

printf 'shared-wiki MCP branch smoke passed\n'
