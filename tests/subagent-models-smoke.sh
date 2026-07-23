#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

python3 - "$ROOT" "$SANDBOX" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sandbox = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))

from subagent_models import load_subagent_model_config

config_path = sandbox / "adapter.config.json"
config_path.write_text(
    json.dumps({"subagentModels": {"agents": {"wiki-researcher": "inherit"}}}),
    encoding="utf-8",
)
assert load_subagent_model_config(sandbox).agents == {"wiki-researcher": "inherit"}

removed_ids = [
    "lan" + "hu-frontend-requirements-analyst",
    "lan" + "hu-backend-requirements-analyst",
]
for removed_id in removed_ids:
    config_path.write_text(
        json.dumps({"subagentModels": {"agents": {removed_id: "inherit"}}}),
        encoding="utf-8",
    )
    try:
        load_subagent_model_config(sandbox)
    except SystemExit as exc:
        message = str(exc)
        assert "unknown subagentModels.agents key" in message
        assert removed_id in message
    else:
        raise AssertionError(f"removed agent key was accepted: {removed_id}")
PY

printf 'subagent models smoke OK\n'
