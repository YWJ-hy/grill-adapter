#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_windows-compat.bash"
TMP_DIR="$(portable_tmpdir)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp -R "$ROOT_DIR/mcp/obsidian-wiki" "$TMP_DIR/obsidian-wiki-mcp"
rm -rf "$TMP_DIR/obsidian-wiki-mcp/node_modules" "$TMP_DIR/obsidian-wiki-mcp/dist"

(
  cd "$TMP_DIR/obsidian-wiki-mcp"
  npm install --no-audit --no-fund >/dev/null
  npm run typecheck >/dev/null
  npm test >/dev/null
  npm run build >/dev/null
)

test -f "$TMP_DIR/obsidian-wiki-mcp/dist/index.js"
if CLAUDE_PROJECT_DIR="$TMP_DIR/project" node "$TMP_DIR/obsidian-wiki-mcp/dist/index.js" status | grep -q '"healthy":false'; then
  printf 'obsidian-wiki binding smoke passed\n'
else
  printf 'obsidian-wiki status did not fail closed for an unconfigured project\n' >&2
  exit 1
fi
