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
assert set(manifest["mcpServers"]) == {"obsidian-wiki"}
for server in manifest["mcpServers"].values():
    assert server["cwd"] == "."
    assert server["args"][0].startswith("./mcp/")
assert manifest["interface"]["displayName"] == "Grill Adapter"
default_prompts = manifest["interface"]["defaultPrompt"]
assert len(default_prompts) <= 3, "Codex ignores interface.defaultPrompt when more than 3 prompts are declared"
assert any("readiness" in prompt.lower() for prompt in default_prompts)
skills = list((root / "skills").glob("*/SKILL.md"))
assert len(skills) == 11
assert root / "skills" / "wiki-readiness" / "SKILL.md" in skills
removed_capability = "lan" + "hu"
assert not any(removed_capability in path.as_posix().lower() for path in skills)
assert len(list((root / "agents").glob("*.md"))) == 1
assert not any(removed_capability in path.as_posix().lower() for path in (root / "agents").glob("*.md"))

hooks = json.loads((root / "hooks/hooks.json").read_text(encoding="utf-8"))
assert set(hooks) == {"hooks"}, "Codex rejects unknown top-level hook fields"
assert {"SessionStart", "PostToolUse", "Stop"}.issubset(hooks["hooks"])

mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
assert set(mcp) == {"mcpServers"}
assert set(mcp["mcpServers"]) == {"obsidian-wiki"}
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
  codex debug prompt-input > "$SANDBOX/prompt-input.json" \
    || fail "Codex could not render the installed prompt input"
  python3 - "$SANDBOX/prompt-input.json" <<'PY' || exit 1
import json
import pathlib
import re
import sys

prompt_input = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
skill_names = set()
for message in prompt_input:
    for content in message.get("content", []):
        if not isinstance(content, dict):
            continue
        for line in content.get("text", "").splitlines():
            match = re.match(r"^- (grill-adapter:[^:]+):", line)
            if match:
                skill_names.add(match.group(1))

assert len(skill_names) == 11, sorted(skill_names)
assert "grill-adapter:wiki-readiness" in skill_names
removed_capability = "lan" + "hu"
assert not any(removed_capability in name.lower() for name in skill_names)
PY
else
  printf 'codex plugin CLI check SKIP (codex not found)\n'
fi

printf 'codex plugin smoke OK\n'
