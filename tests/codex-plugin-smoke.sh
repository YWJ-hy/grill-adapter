#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

python3 - "$ROOT" <<'PY' || exit 1
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / ".codex-plugin/plugin.json").read_text(encoding="utf-8"))
assert manifest["name"] == "grill-adapter"
assert manifest["skills"] == "./skills/"
assert set(manifest["mcpServers"]) == {"shared-wiki", "obsidian-wiki"}
for server in manifest["mcpServers"].values():
    assert server["cwd"] == "."
    assert server["args"][0].startswith("./mcp/")
assert manifest["interface"]["displayName"] == "Grill Adapter"
assert len(list((root / "skills").glob("*/SKILL.md"))) == 13

hooks = json.loads((root / "hooks/hooks.json").read_text(encoding="utf-8"))
assert set(hooks) == {"hooks"}, "Codex rejects unknown top-level hook fields"
assert {"SessionStart", "PostToolUse", "Stop"}.issubset(hooks["hooks"])

mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
assert set(mcp) == {"mcpServers"}
assert set(mcp["mcpServers"]) == {"shared-wiki", "obsidian-wiki"}
for server in mcp["mcpServers"].values():
    assert server["args"][0].startswith("${CLAUDE_PLUGIN_ROOT}/mcp/")
PY

if command -v codex >/dev/null 2>&1; then
  SANDBOX="$(mktemp -d)"
  trap 'rm -rf "$SANDBOX"' EXIT
  export CODEX_HOME="$SANDBOX/.codex"
  mkdir -p "$CODEX_HOME"
  codex plugin marketplace add "$ROOT" --json >/dev/null || fail "Codex marketplace add failed"
  codex plugin add grill-adapter@grill-adapter --json >/dev/null || fail "Codex plugin add failed"
  codex plugin list | grep -q 'grill-adapter@grill-adapter.*installed, enabled' \
    || fail "Codex plugin is not installed and enabled"
else
  printf 'codex plugin CLI check SKIP (codex not found)\n'
fi

printf 'codex plugin smoke OK\n'
