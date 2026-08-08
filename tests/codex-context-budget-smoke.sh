#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
CHECK="${ROOT}/acceptance/codex-context-budget-installed.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() {
  local file="$1"
  local text="$2"
  grep -qF "$text" "$file" || fail "missing '$text' in $file"
}

[[ -x "$CHECK" ]] || fail "installed Codex context budget check is missing or not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$CHECK" "$ROOT" --contract-check >"$TMP/contract.json"
python3 - "$TMP/contract.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report == {
    "schemaVersion": 1,
    "kind": "grill-adapter.codex-context-budget",
    "fixedCosts": [
        "globalPluginSkillCatalog",
        "projectHostInstructions",
        "mcpToolSchemas",
    ],
    "stageCosts": [
        "research",
        "readiness",
        "capture",
        "maintenance",
    ],
    "measurementUnit": "utf8Bytes",
    "runtimeSources": [
        "codex debug prompt-input",
        "MCP tools/list",
        "codex debug prompt-input (installed stage resources)",
    ],
}
PY

python3 - "$ROOT/contracts/codex-context-budget-v1.json" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert contract["limits"]["projectHostInstructions"] == 4096
PY

# The runner accepts captured runtime discovery so its behavior can be tested without
# depending on the developer machine's Codex defaults or credentials.
mkdir -p "$TMP/captures" "$TMP/installed/skills/wiki-research" \
  "$TMP/installed/skills/wiki-readiness" \
  "$TMP/installed/skills/update-wiki/references" \
  "$TMP/installed/skills/wiki-maintenance" "$TMP/installed/agents"

cat >"$TMP/captures/baseline.json" <<'JSON'
[{"role":"developer","content":[{"type":"input_text","text":"base"}]}]
JSON
cat >"$TMP/captures/plugin.json" <<'JSON'
[{"role":"developer","content":[{"type":"input_text","text":"base\n- grill-adapter:wiki-research: Research the Wiki. (file: /machine/plugin/skills/wiki-research/SKILL.md)\n- grill-adapter:wiki-readiness: Bind task context. (file: /machine/plugin/skills/wiki-readiness/SKILL.md)\n"}]}]
JSON
cat >"$TMP/captures/wired.json" <<'JSON'
[{"role":"developer","content":[{"type":"input_text","text":"base\n- grill-adapter:wiki-research: Research the Wiki. (file: /other/machine/plugin/skills/wiki-research/SKILL.md)\n- grill-adapter:wiki-readiness: Bind task context. (file: /other/machine/plugin/skills/wiki-readiness/SKILL.md)\n"}]},{"role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /machine/project\n<INSTRUCTIONS>\n<!-- grill-adapter:host:grill:start -->\nHOST-CONTEXT\n<!-- grill-adapter:host:grill:end -->\n</INSTRUCTIONS>"}]}]
JSON
cat >"$TMP/captures/tools.json" <<'JSON'
{"tools":[{"name":"obsidian_wiki_status","description":"Status.","inputSchema":{"type":"object","properties":{}}},{"name":"obsidian_wiki_search","description":"Search.","inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}]}
JSON

printf 'RESEARCH-SKILL\n' >"$TMP/installed/skills/wiki-research/SKILL.md"
printf 'READINESS-SKILL\n' >"$TMP/installed/skills/wiki-readiness/SKILL.md"
printf 'CAPTURE-SKILL\n' >"$TMP/installed/skills/update-wiki/SKILL.md"
printf 'TARGETING-REFERENCE\n' >"$TMP/installed/skills/update-wiki/references/targeting.md"
printf 'TEMPLATE-REFERENCE\n' >"$TMP/installed/skills/update-wiki/references/content-templates.md"
printf 'MAINTENANCE-SKILL\n' >"$TMP/installed/skills/wiki-maintenance/SKILL.md"
printf 'RESEARCH-ROLE\n' >"$TMP/installed/agents/wiki-researcher.md"
printf 'CAPTURE-ROLE\n' >"$TMP/installed/agents/wiki-capture.md"
printf 'MAINTENANCE-ROLE\n' >"$TMP/installed/agents/wiki-maintenance.md"

python3 - "$ROOT/contracts/codex-context-budget-v1.json" "$TMP/installed" \
  "$TMP/captures" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
installed = pathlib.Path(sys.argv[2])
captures = pathlib.Path(sys.argv[3])
for stage, resources in contract["stageResources"].items():
    parts = [
        f'<context-budget-stage name="{stage}">',
        "<renderer-overhead>runtime</renderer-overhead>",
    ]
    for relative in resources:
        parts.extend((
            f'<resource path="{relative}">',
            (installed / relative).read_text(encoding="utf-8"),
            "</resource>",
        ))
    parts.append("</context-budget-stage>")
    prompt = [{
        "role": "user",
        "content": [{"type": "input_text", "text": "\n".join(parts)}],
    }]
    (captures / f"stage-{stage}.json").write_text(json.dumps(prompt), encoding="utf-8")
PY

cat >"$TMP/thresholds.json" <<'JSON'
{
  "globalPluginSkillCatalog": 4096,
  "projectHostInstructions": 4096,
  "mcpToolSchemas": 4096,
  "stages": {
    "research": 4096,
    "readiness": 4096,
    "capture": 4096,
    "maintenance": 4096
  }
}
JSON

"$CHECK" "$ROOT" --from-captures "$TMP/captures" \
  --installed-root "$TMP/installed" --thresholds "$TMP/thresholds.json" \
  --output "$TMP/report.json"

python3 - "$TMP/report.json" "$TMP/installed" "$ROOT/contracts/codex-context-budget-v1.json" <<'PY'
import json
import pathlib
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
contract = json.load(open(sys.argv[3], encoding="utf-8"))
assert report["schemaVersion"] == 1
assert report["kind"] == "grill-adapter.codex-context-budget"
assert report["status"] == "pass"
assert report["measurementUnit"] == "utf8Bytes"
assert set(report["fixedCosts"]) == {
    "globalPluginSkillCatalog",
    "projectHostInstructions",
    "mcpToolSchemas",
}
assert set(report["stages"]) == {"research", "readiness", "capture", "maintenance"}
assert report["fixedCosts"]["mcpToolSchemas"]["toolCount"] == 2
assert report["totals"]["fixedBytes"] == sum(
    item["bytes"] for item in report["fixedCosts"].values()
)
assert report["totals"]["stageBytes"] == sum(
    item["bytes"] for item in report["stages"].values()
)
assert round(sum(item["sharePercent"] for item in report["fixedCosts"].values()), 5) == 100
assert round(sum(item["sharePercent"] for item in report["stages"].values()), 5) == 100
assert [tool["name"] for tool in report["fixedCosts"]["mcpToolSchemas"]["tools"]] == [
    "obsidian_wiki_search",
    "obsidian_wiki_status",
]
assert report["stages"]["research"]["resources"] == [
    "skills/wiki-research/SKILL.md",
]
assert "skills/wiki-research/SKILL.md" in report["stages"]["readiness"]["resources"]
assert "agents/wiki-researcher.md" not in report["stages"]["research"]["resources"]
assert "agents/wiki-researcher.md" not in report["stages"]["readiness"]["resources"]
assert report["stages"]["capture"]["resources"] == [
    "skills/update-wiki/SKILL.md",
    "skills/update-wiki/references/targeting.md",
    "skills/update-wiki/references/content-templates.md",
]
assert report["stages"]["maintenance"]["resources"] == [
    "skills/wiki-maintenance/SKILL.md",
]
assert report["stages"]["capture"]["baselineCommit"] == contract["baselineCommit"]
assert report["stages"]["maintenance"]["baselineCommit"] == contract["baselineCommit"]
assert report["stages"]["capture"]["reductionBytes"] > 0
assert report["stages"]["maintenance"]["reductionBytes"] > 0
assert not any(
    resource.startswith("agents/")
    for stage in report["stages"].values()
    for resource in stage["resources"]
)
installed = pathlib.Path(sys.argv[2])
source_bytes = sum(
    (installed / relative).stat().st_size
    for relative in report["stages"]["research"]["resources"]
)
assert report["stages"]["research"]["bytes"] > source_bytes
serialized = json.dumps(report)
assert "machine" not in serialized
for private_body in ("HOST-CONTEXT", "RESEARCH-SKILL", "CAPTURE-ROLE"):
    assert private_body not in serialized
PY

cat >"$TMP/tight-thresholds.json" <<'JSON'
{
  "globalPluginSkillCatalog": 1,
  "projectHostInstructions": 4096,
  "mcpToolSchemas": 4096,
  "stages": {
    "research": 4096,
    "readiness": 4096,
    "capture": 4096,
    "maintenance": 4096
  }
}
JSON

if "$CHECK" "$ROOT" --from-captures "$TMP/captures" \
  --installed-root "$TMP/installed" --thresholds "$TMP/tight-thresholds.json" \
  --output "$TMP/failing-report.json" >"$TMP/failing.out" 2>&1; then
  fail "budget overflow unexpectedly passed"
fi
need "$TMP/failing.out" "globalPluginSkillCatalog"
need "$TMP/failing.out" "limit=1"

need "$ROOT/release-check.sh" 'acceptance/codex-context-budget-installed.sh'
need "$ROOT/docs/DEVELOPMENT_CN.md" 'codex-context-budget-installed.sh'
need "$ROOT/README.md" 'codex-context-budget-installed.sh'

printf 'codex context budget smoke OK\n'
