#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ACCEPTANCE="$ROOT/acceptance/codex-context-isolation-installed.sh"

output="$(bash "$ACCEPTANCE" "$ROOT" --contract-check)"

python3 - "$output" <<'PY'
import json
import sys

contract = json.loads(sys.argv[1])
assert contract == {
    "schemaVersion": 1,
    "kind": "grill-adapter.codex-context-isolation-acceptance",
    "workflowStages": [
        "discovery-planning",
        "task-readiness",
        "direct-implementation",
        "agent-implementation",
        "code-review",
        "capture",
        "maintenance-audit",
        "maintenance-consolidation",
    ],
    "roleContracts": [
        "implementer",
        "reviewer-standards",
        "reviewer-spec",
        "main-session-direct-implementation",
    ],
    "failurePaths": [
        "researcher-dispatch",
        "maintenance-dispatch",
        "researcher-malformed-output",
        "maintenance-stale-report",
        "binding-drift",
        "host-fail-open",
    ],
    "isolationChecks": [
        "unselected-note-body",
        "expired-note-body",
        "catalog-inventory",
        "journal-transcript",
        "agent-reasoning",
        "parent-transcript-inheritance",
        "role-contract-mismatch",
        "proposal-side-effects",
    ],
    "evaluationMetrics": [
        "hardConstraintMisses",
        "irrelevantSelections",
        "expiredInjections",
        "correctionRecurrences",
        "noteBodyReads",
        "endToEndLatencyMs",
    ],
}
PY

grep -Fq 'GRILL_ADAPTER_CODEX_MODEL' "$ACCEPTANCE"
grep -Fq 'GRILL_ADAPTER_CODEX_MODEL' "$ROOT/acceptance/codex-maintenance-installed.sh"
grep -Fq 'ISSUE35_STAGE_MALFORMED_RESEARCHER_OUTPUT' "$ACCEPTANCE"
grep -Fq 'ISSUE35_STAGE_MAINTENANCE_STALE_REPORT' "$ROOT/acceptance/codex-maintenance-installed.sh"
grep -Fq 'researchAndMaintenanceCoordinatorMetadataOnly' "$ACCEPTANCE"
grep -Fq 'GRILL_ADAPTER_CODEX_ACCEPTANCE_REPORT' "$ACCEPTANCE"
grep -Fq '\x1b\[6n' "$ACCEPTANCE"
grep -Fq '\x1b\[6n' "$ROOT/acceptance/codex-maintenance-installed.sh"
grep -Fq 'log_user 0' "$ACCEPTANCE"
grep -Fq 'log_user 0' "$ROOT/acceptance/codex-maintenance-installed.sh"
grep -Fq 'mcp_servers.obsidian-wiki.tools.obsidian_wiki_stage_capture_plan.approval_mode="approve"' "$ACCEPTANCE"
grep -Fq 'ACCEPTANCE_MONITOR_CAPTURE_MCP' "$ACCEPTANCE"
grep -Fq 'pending mcp_tool_call_approval elicitation' "$ACCEPTANCE"
if grep -Fq 'mcp_servers.obsidian-wiki.default_tools_approval_mode="approve"' "$ACCEPTANCE"; then
  printf 'context-isolation acceptance must not auto-approve every Obsidian MCP write tool\n' >&2
  exit 1
fi
if grep -Fq 'terminal_text' "$ACCEPTANCE"; then
  printf 'context-isolation evaluator must not use terminal rendering as evidence\n' >&2
  exit 1
fi

printf 'codex context isolation acceptance contract smoke OK\n'
