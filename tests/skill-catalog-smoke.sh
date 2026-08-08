#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
contract_path = root / "contracts" / "project-activation-v1.json"
contract = json.loads(contract_path.read_text(encoding="utf-8"))
assert contract["schemaVersion"] == 1
assert contract["kind"] == "grill-adapter.project-activation"
assert contract["standaloneExitCode"] == 3
assert contract["activeReasons"] == ["explicit", "settings", "host-marker"]
assert contract["preflightScript"] == "scripts/project_activation.py"
assert contract["preflightArgs"] == ["<project-root>", "[--explicit]"]
assert contract["preflightRoot"] == "installed plugin root"
assert contract["settingsPath"] == ".grill-adapter/settings.json"
assert "grill-adapter:host:" in contract["hostMarker"]

expected = {
    "break-loop",
    "candidate-journal",
    "import-wiki",
    "init-wiki",
    "migrate-wiki",
    "scaffold-practice-skill",
    "setup-init-obsidian",
    "source-truth-check",
    "update-wiki",
    "wiki-maintenance",
    "wiki-readiness",
    "wiki-research",
}
skills_dir = root / "skills"
skills = {path.parent.name: path for path in skills_dir.glob("*/SKILL.md")}
assert set(skills) == expected, sorted(skills)
assert not (skills_dir / "wiki-materialize" / "SKILL.md").exists()

suffix = "Requires explicit invocation or project opt-in; standalone grill remains inert."
for name, path in skills.items():
    lines = path.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "---", name
    end = lines.index("---", 1)
    frontmatter = "\n".join(lines[1:end])
    description = next((line for line in lines[1:end] if line.startswith("description:")), "")
    assert suffix in description, name
    body = "\n".join(lines[end + 1 :])
    assert "contracts/project-activation-v1.json" in body, name
    assert "## Activation gate" not in body, name

print("skill catalog smoke OK")
PY
