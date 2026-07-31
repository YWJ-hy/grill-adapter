#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_windows-compat.bash"
TMP_DIR="$(portable_tmpdir)"
trap 'rm -rf "$TMP_DIR"' EXIT
MCP_ROOT="$TMP_DIR/repo/mcp/obsidian-wiki"

mkdir -p "$TMP_DIR/repo/mcp" "$TMP_DIR/repo/scripts"
cp -R "$ROOT_DIR/mcp/obsidian-wiki" "$MCP_ROOT"
cp "$ROOT_DIR/scripts/wiki_candidate_journal.py" "$TMP_DIR/repo/scripts/"
cp "$ROOT_DIR/scripts/wiki_session_state.py" "$TMP_DIR/repo/scripts/"
rm -rf "$MCP_ROOT/node_modules" "$MCP_ROOT/dist"

(
  cd "$MCP_ROOT"
  npm install --no-audit --no-fund >/dev/null
  npm run typecheck >/dev/null
  npm test >/dev/null
  npm run build >/dev/null
)

test -f "$MCP_ROOT/dist/index.js"
if CLAUDE_PROJECT_DIR="$TMP_DIR/project" node "$MCP_ROOT/dist/index.js" status | grep -q '"healthy":false'; then
  printf 'obsidian-wiki binding smoke passed\n'
else
  printf 'obsidian-wiki status did not fail closed for an unconfigured project\n' >&2
  exit 1
fi
