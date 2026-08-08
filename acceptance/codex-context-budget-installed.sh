#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
[[ $# -eq 0 ]] || shift

MODE="run"
CAPTURES=""
INSTALLED_ROOT=""
THRESHOLDS="${GRILL_ADAPTER_CONTEXT_BUDGETS:-${ROOT}/contracts/codex-context-budget-v1.json}"
OUTPUT=""

usage() {
  cat <<'EOF'
Usage:
  acceptance/codex-context-budget-installed.sh [root] [--thresholds file] [--output file]
  acceptance/codex-context-budget-installed.sh [root] --from-captures dir --installed-root dir [options]
  acceptance/codex-context-budget-installed.sh [root] --contract-check
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract-check)
      MODE="contract"
      shift
      ;;
    --from-captures)
      MODE="captures"
      CAPTURES="${2:-}"
      shift 2
      ;;
    --installed-root)
      INSTALLED_ROOT="${2:-}"
      shift 2
      ;;
    --thresholds)
      THRESHOLDS="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "contract" ]]; then
  python3 - <<'PY'
import json

print(json.dumps({
    "schemaVersion": 1,
    "kind": "grill-adapter.codex-context-budget",
    "fixedCosts": [
        "globalPluginSkillCatalog",
        "projectHostInstructions",
        "mcpToolSchemas",
    ],
    "stageCosts": ["research", "readiness", "capture", "maintenance"],
    "measurementUnit": "utf8Bytes",
    "runtimeSources": [
        "codex debug prompt-input",
        "MCP tools/list",
        "codex debug prompt-input (installed stage resources)",
    ],
}, separators=(",", ":")))
PY
  exit 0
fi

analyze_captures() {
  python3 - "$CAPTURES" "$INSTALLED_ROOT" "$THRESHOLDS" "$OUTPUT" \
    "$ROOT/contracts/codex-context-budget-v1.json" "$ROOT" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

captures = pathlib.Path(sys.argv[1]).resolve()
installed_root = pathlib.Path(sys.argv[2]).resolve()
threshold_path = pathlib.Path(sys.argv[3]).resolve()
output_arg = sys.argv[4]
contract_path = pathlib.Path(sys.argv[5]).resolve()
repo_root = pathlib.Path(sys.argv[6]).resolve()


def fail(message: str) -> None:
    raise SystemExit(f"context budget input error: {message}")


def load_json(path: pathlib.Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {path.name}: {exc}")


def utf8_size(value: str) -> int:
    return len(value.encode("utf-8"))


def message_text(prompt_input) -> str:
    if not isinstance(prompt_input, list):
        fail("prompt-input capture must be a JSON list")
    chunks = []
    for message in prompt_input:
        if not isinstance(message, dict):
            continue
        for content in message.get("content", []):
            if isinstance(content, dict) and isinstance(content.get("text"), str):
                chunks.append(content["text"])
    return "\n".join(chunks)


baseline_text = message_text(load_json(captures / "baseline.json"))
plugin_text = message_text(load_json(captures / "plugin.json"))
wired_text = message_text(load_json(captures / "wired.json"))

if "grill-adapter:" in baseline_text:
    fail("baseline prompt unexpectedly contains grill-adapter discovery")

catalog_lines = []
for line in plugin_text.splitlines():
    if re.match(r"^- grill-adapter:[^:]+:", line):
        normalized = re.sub(
            r"\(file: .*?/skills/([^/]+)/SKILL\.md\)",
            r"(file: skills/\1/SKILL.md)",
            line,
        )
        catalog_lines.append(normalized)
if not catalog_lines:
    fail("plugin prompt contains no grill-adapter skill discovery entries")
catalog_lines.sort()
catalog_payload = "\n".join(catalog_lines) + "\n"

host_blocks = re.findall(
    r"<!-- grill-adapter:host:[^:]+:start -->.*?<!-- grill-adapter:host:[^:]+:end -->",
    wired_text,
    flags=re.DOTALL,
)
if len(host_blocks) != 1:
    fail(f"wired prompt must contain exactly one host convention block, found {len(host_blocks)}")
host_payload = host_blocks[0]

tool_result = load_json(captures / "tools.json")
if not isinstance(tool_result, dict) or not isinstance(tool_result.get("tools"), list):
    fail("MCP tools/list capture must contain a tools array")
tool_rows = []
for tool in tool_result["tools"]:
    if not isinstance(tool, dict) or not isinstance(tool.get("name"), str):
        fail("MCP tools/list returned a tool without a stable name")
    canonical = json.dumps(tool, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    tool_rows.append({"name": tool["name"], "bytes": utf8_size(canonical)})
tool_rows.sort(key=lambda item: item["name"])
if not tool_rows:
    fail("MCP tools/list returned no tools")

raw_thresholds = load_json(threshold_path)
if isinstance(raw_thresholds, dict) and "limits" in raw_thresholds:
    raw_thresholds = raw_thresholds["limits"]
if not isinstance(raw_thresholds, dict):
    fail("thresholds must be a JSON object")

fixed_names = (
    "globalPluginSkillCatalog",
    "projectHostInstructions",
    "mcpToolSchemas",
)
stage_names = ("research", "readiness", "capture", "maintenance")
for name in fixed_names:
    if not isinstance(raw_thresholds.get(name), int) or raw_thresholds[name] < 0:
        fail(f"threshold {name} must be a non-negative integer")
stage_limits = raw_thresholds.get("stages")
if not isinstance(stage_limits, dict):
    fail("thresholds.stages must be an object")
for name in stage_names:
    if not isinstance(stage_limits.get(name), int) or stage_limits[name] < 0:
        fail(f"threshold stages.{name} must be a non-negative integer")

contract = load_json(contract_path)
stage_resources = contract.get("stageResources") if isinstance(contract, dict) else None
if not isinstance(stage_resources, dict) or set(stage_resources) != set(stage_names):
    fail("default budget contract must define exactly the four stage resource rosters")
for name in stage_names:
    resources = stage_resources[name]
    if not isinstance(resources, list) or not resources or not all(isinstance(item, str) for item in resources):
        fail(f"stage resource roster {name} must be a non-empty string list")
    for relative in resources:
        path = pathlib.PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts:
            fail(f"stage resource {relative} must be a safe plugin-relative path")
        if not (installed_root / relative).is_file():
            fail(f"installed stage resource is missing: {relative}")

baseline_commit = contract.get("baselineCommit")
if not isinstance(baseline_commit, str) or not baseline_commit:
    fail("default budget contract must declare baselineCommit")
try:
    baseline_contract = json.loads(subprocess.check_output(
        ["git", "-C", str(repo_root), "show", f"{baseline_commit}:contracts/codex-context-budget-v1.json"],
        text=True,
    ))
except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
    fail(f"cannot load context-budget baseline {baseline_commit}: {exc}")
baseline_resources = baseline_contract.get("stageResources")
if not isinstance(baseline_resources, dict) or set(baseline_resources) != set(stage_names):
    fail("context-budget baseline must define exactly the four stage resource rosters")

def baseline_stage_bytes(stage_name):
    parts = [f'<context-budget-stage name="{stage_name}">']
    for relative in baseline_resources[stage_name]:
        try:
            body = subprocess.check_output(
                ["git", "-C", str(repo_root), "show", f"{baseline_commit}:{relative}"],
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            fail(f"baseline resource missing for {stage_name}: {relative}: {exc}")
        parts.extend((f'<resource path="{relative}">', body, "</resource>"))
    parts.append("</context-budget-stage>")
    return utf8_size("\n".join(parts))

fixed_measurements = {
    "globalPluginSkillCatalog": {
        "bytes": utf8_size(catalog_payload),
        "source": "codex debug prompt-input (installed plugin skill entries)",
        "entryCount": len(catalog_lines),
    },
    "projectHostInstructions": {
        "bytes": utf8_size(host_payload),
        "source": "codex debug prompt-input (wired project host block)",
    },
    "mcpToolSchemas": {
        "bytes": sum(item["bytes"] for item in tool_rows),
        "source": "MCP tools/list",
        "toolCount": len(tool_rows),
        "tools": tool_rows,
    },
}

violations = []
for name, measurement in fixed_measurements.items():
    limit = raw_thresholds[name]
    measurement["limit"] = limit
    measurement["status"] = "pass" if measurement["bytes"] <= limit else "fail"
    if measurement["status"] == "fail":
        violations.append({"source": name, "bytes": measurement["bytes"], "limit": limit})

stages = {}
for name in stage_names:
    stage_text = message_text(load_json(captures / f"stage-{name}.json"))
    pattern = re.compile(
        rf'<context-budget-stage name="{re.escape(name)}">.*?</context-budget-stage>',
        flags=re.DOTALL,
    )
    blocks = pattern.findall(stage_text)
    if len(blocks) != 1:
        fail(f"stage {name} prompt must contain exactly one rendered stage block, found {len(blocks)}")
    block = blocks[0]
    rendered_resources = re.findall(r'<resource path="([^"]+)">', block)
    if rendered_resources != stage_resources[name]:
        fail(f"stage {name} rendered resource roster does not match the budget contract")
    total = utf8_size(block)
    limit = stage_limits[name]
    status = "pass" if total <= limit else "fail"
    stages[name] = {
        "bytes": total,
        "limit": limit,
        "baselineCommit": baseline_commit,
        "baselineBytes": baseline_stage_bytes(name),
        "status": status,
        "source": "codex debug prompt-input (installed stage resources)",
        "resources": stage_resources[name],
    }
    stages[name]["reductionBytes"] = stages[name]["baselineBytes"] - total
    if name in {"capture", "maintenance"} and stages[name]["reductionBytes"] <= 0:
        fail(f"stage {name} did not decrease from baseline {baseline_commit}")
    if status == "fail":
        violations.append({"source": f"stages.{name}", "bytes": total, "limit": limit})

fixed_total = sum(item["bytes"] for item in fixed_measurements.values())
stage_total = sum(item["bytes"] for item in stages.values())
for measurement in fixed_measurements.values():
    measurement["sharePercent"] = measurement["bytes"] / fixed_total * 100
for measurement in stages.values():
    measurement["sharePercent"] = measurement["bytes"] / stage_total * 100

report = {
    "schemaVersion": 1,
    "kind": "grill-adapter.codex-context-budget",
    "status": "pass" if not violations else "fail",
    "measurementUnit": "utf8Bytes",
    "fixedCosts": fixed_measurements,
    "stages": stages,
    "totals": {"fixedBytes": fixed_total, "stageBytes": stage_total},
    "violations": violations,
}

rendered = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if output_arg:
    output = pathlib.Path(output_arg)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
else:
    sys.stdout.write(rendered)

for violation in violations:
    print(
        f"context budget exceeded: {violation['source']} "
        f"bytes={violation['bytes']} limit={violation['limit']}",
        file=sys.stderr,
    )
if violations:
    raise SystemExit(1)
PY
}

if [[ "$MODE" == "captures" ]]; then
  [[ -n "$CAPTURES" ]] || { printf '%s\n' '--from-captures requires a directory' >&2; exit 2; }
  [[ -n "$INSTALLED_ROOT" ]] || { printf '%s\n' '--installed-root is required with --from-captures' >&2; exit 2; }
  analyze_captures
  exit $?
fi

CODEX_BIN="${GRILL_ADAPTER_CODEX_BIN:-$(command -v codex || true)}"
[[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]] || {
  printf 'working Codex CLI not found; set GRILL_ADAPTER_CODEX_BIN\n' >&2
  exit 2
}
[[ -f "$THRESHOLDS" ]] || { printf 'threshold file not found: %s\n' "$THRESHOLDS" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
CAPTURES="$SANDBOX/captures"
UNWIRED="$SANDBOX/unwired-project"
WIRED="$SANDBOX/wired-project"
export CODEX_HOME="$SANDBOX/.codex"
mkdir -p "$CODEX_HOME" "$CAPTURES" "$UNWIRED" "$WIRED"
git -C "$UNWIRED" init -q
git -C "$WIRED" init -q

(cd "$UNWIRED" && "$CODEX_BIN" debug prompt-input >"$CAPTURES/baseline.json")
"$CODEX_BIN" plugin marketplace add "$ROOT" --json >/dev/null
"$CODEX_BIN" plugin add grill-adapter@grill-adapter --json >/dev/null
(cd "$UNWIRED" && "$CODEX_BIN" debug prompt-input >"$CAPTURES/plugin.json")
python3 "$ROOT/lib/install.py" install "$WIRED" --host grill --runtime codex >/dev/null
(cd "$WIRED" && "$CODEX_BIN" debug prompt-input >"$CAPTURES/wired.json")

INSTALLED_ROOT="$(python3 - "$CODEX_HOME" <<'PY'
import json
import pathlib
import sys

roots = []
for manifest in pathlib.Path(sys.argv[1]).glob("plugins/cache/*/*/*/.codex-plugin/plugin.json"):
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    if data.get("name") == "grill-adapter":
        roots.append(manifest.parent.parent)
if len(roots) != 1:
    raise SystemExit(f"expected one installed grill-adapter root, found {len(roots)}")
print(roots[0])
PY
)"

for STAGE in research readiness capture maintenance; do
  STAGE_PAYLOAD="$(python3 - "$INSTALLED_ROOT" \
    "$ROOT/contracts/codex-context-budget-v1.json" "$STAGE" <<'PY'
import json
import pathlib
import sys

installed_root = pathlib.Path(sys.argv[1])
contract = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
stage = sys.argv[3]
resources = contract["stageResources"][stage]
parts = [f'<context-budget-stage name="{stage}">']
for relative in resources:
    body = (installed_root / relative).read_text(encoding="utf-8")
    parts.extend((f'<resource path="{relative}">', body, "</resource>"))
parts.append("</context-budget-stage>")
print("\n".join(parts))
PY
)"
  (cd "$UNWIRED" && "$CODEX_BIN" debug prompt-input "$STAGE_PAYLOAD" \
    >"$CAPTURES/stage-$STAGE.json")
done

python3 - "$INSTALLED_ROOT/mcp/obsidian-wiki/dist/index.js" "$CAPTURES/tools.json" <<'PY'
import json
import pathlib
import subprocess
import sys

bundle = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
process = subprocess.Popen(
    ["node", str(bundle)],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
assert process.stdin is not None
assert process.stdout is not None
requests = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "grill-adapter-context-budget", "version": "1"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
]
try:
    for request in requests:
        process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()
    while True:
        line = process.stdout.readline()
        if not line:
            stderr = process.stderr.read() if process.stderr is not None else ""
            raise SystemExit(f"MCP tools/list ended before a response: {stderr[-500:]}")
        response = json.loads(line)
        if response.get("id") == 2:
            result = response.get("result")
            if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
                raise SystemExit("MCP tools/list returned an invalid result")
            output.write_text(
                json.dumps({"tools": result["tools"]}, ensure_ascii=False),
                encoding="utf-8",
            )
            break
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
PY

analyze_captures
