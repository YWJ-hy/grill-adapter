#!/usr/bin/env bash
# grill-adapter doctor — diagnose install + shared-wiki binding for a project.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-}"
if [[ -z "$PROJECT_ROOT" ]]; then
  printf 'Usage: %s <project-root>\n' "$0" >&2
  exit 1
fi

echo "grill-adapter doctor"
echo "===================="
python3 "$SCRIPT_DIR/lib/install.py" status "$PROJECT_ROOT" || true
echo ""
echo "shared-wiki binding (per-project, .shared-adapter/settings.json -> wiki.sharedMcp):"
python3 - "$PROJECT_ROOT" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
settings = root / ".shared-adapter" / "settings.json"
if not settings.is_file():
    print("  no .shared-adapter/settings.json — no MCP shared wiki (fail-closed).")
    raise SystemExit(0)
try:
    data = json.loads(settings.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"  settings.json is invalid JSON: {exc}")
    raise SystemExit(0)
shared = (data.get("wiki", {}) or {}).get("sharedMcp", {}) or {}
if not shared:
    print("  wiki.sharedMcp not declared — no MCP shared wiki (fail-closed).")
    raise SystemExit(0)
repo = shared.get("repoUrl")
if not repo:
    print("  wiki.sharedMcp declared WITHOUT repoUrl — server will fail closed. Add repoUrl or remove the block.")
    raise SystemExit(0)
print(f"  repoUrl:      {repo}")
print(f"  baseBranch:   {shared.get('baseBranch', '(default)')}")
print(f"  remote:       {shared.get('remote', '(default)')}")
print(f"  wikiRoot:     {shared.get('wikiRoot', '(repo root)')}")
print(f"  displayRoot:  {shared.get('displayRoot', '(default)')}")
print(f"  draftPr:      {shared.get('draftPr', False)}")
print("  binding OK.")
PY

echo ""
echo "Obsidian Wiki Source runtime (binding/read/write-bridge diagnostic):"
if [[ -f "$SCRIPT_DIR/mcp/obsidian-wiki/dist/index.js" ]] && command -v node >/dev/null 2>&1; then
  CLAUDE_PROJECT_DIR="$PROJECT_ROOT" node "$SCRIPT_DIR/mcp/obsidian-wiki/dist/index.js" status || true
else
  echo "  unavailable: obsidian-wiki bundle or node is missing."
fi
