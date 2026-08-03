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
    "installedHost": "grill",
    "hostStages": [
        "grill-with-docs",
        "to-spec",
        "to-tickets",
        "implement",
        "code-review",
        "diagnosing-bugs",
    ],
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
        "researcher-child-side-loader",
        "implementer",
        "reviewer-standards",
        "reviewer-spec",
        "main-session-direct-implementation",
    ],
    "failurePaths": [
        "researcher-dispatch",
        "researcher-role-load",
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
        "researcher-role-private-in-coordinator",
        "researcher-role-loaded-by-child",
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
grep -Fq 'install "$PROJECT" --host grill --runtime codex' "$ACCEPTANCE"
grep -Fq 'GRILL_ADAPTER_MATTPOCOCK_SKILLS_ROOT' "$ACCEPTANCE"
grep -Fq 'plugin add mattpocock-skills@mattpocock' "$ACCEPTANCE"
grep -Fq '.claude-plugin/plugin.json' "$ACCEPTANCE"
grep -Fq 'plugin marketplace list --json' "$ACCEPTANCE"
grep -Fq '"sourceOfTruth"' "$ACCEPTANCE"
grep -Fq 'source_truth_settings.py' "$ACCEPTANCE"
grep -Fq '"--render-prompt", "plan-pre"' "$ACCEPTANCE"
grep -Fq 'GRILL_ADAPTER_CODEX_MODEL' "$ROOT/acceptance/codex-maintenance-installed.sh"
grep -Fq 'ISSUE35_STAGE_MALFORMED_RESEARCHER_OUTPUT' "$ACCEPTANCE"
grep -Fq 'ISSUE35_STAGE_MAINTENANCE_STALE_REPORT' "$ROOT/acceptance/codex-maintenance-installed.sh"
grep -Fq 'researchAndMaintenanceCoordinatorMetadataOnly' "$ACCEPTANCE"
grep -Fq 'researcher_role_marker' "$ACCEPTANCE"
grep -Fq 'child_role_loader.py' "$ACCEPTANCE"
grep -Fq 'research_loader_calls' "$ACCEPTANCE"
grep -Fq 'research_loader_first_call' "$ACCEPTANCE"
grep -Fq 'research_waits_until_terminal' "$ACCEPTANCE"
grep -Fq 'ISSUE40_STAGE_RESEARCH_ROLE_LOAD_FAILURE' "$ACCEPTANCE"
grep -Fq 'role_load_failure_child_calls' "$ACCEPTANCE"
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

python3 - "$ACCEPTANCE" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

for marker, stage in (
    ("ISSUE39_STAGE_GRILL_WITH_DOCS", "grill-with-docs"),
    ("ISSUE39_STAGE_TO_SPEC", "to-spec"),
    ("ISSUE35_STAGE_RESEARCH_SUCCESS", "to-tickets"),
    ("ISSUE35_STAGE_TASK_READINESS", "implement"),
    ("ISSUE35_STAGE_CODE_REVIEW", "code-review"),
    ("ISSUE39_STAGE_DIAGNOSING_BUGS", "diagnosing-bugs"),
):
    start = source.index(f"export ACCEPTANCE_PROMPT='{marker}.")
    end = source.index("\nrun_codex_acceptance", start)
    prompt = source[start:end]
    assert f"$mattpocock-skills:{stage}" in prompt, (marker, prompt)
    assert "$grill-adapter:" not in prompt, (marker, prompt)

start = source.index("export ACCEPTANCE_PROMPT='ISSUE35_STAGE_RESEARCH_SUCCESS.")
end = source.index("\nrun_codex_acceptance", start)
prompt = source[start:end]
assert "$mattpocock-skills:to-tickets" in prompt
assert "$grill-adapter:wiki-research" not in prompt
assert "$grill-adapter:source-truth-check" not in prompt
assert "issue35_wiki_researcher" not in prompt
assert "fork_turns" not in prompt
assert "role file contents" not in prompt

start = source.index("export ACCEPTANCE_PROMPT='ISSUE35_STAGE_CODE_REVIEW.")
end = source.index("\nrun_codex_acceptance", start)
prompt = source[start:end]
assert "feature issue-35" in prompt
assert "issue35_capture" in prompt
assert '"captureStatus":"skipped"' in prompt

start = source.index("export ACCEPTANCE_PROMPT='ISSUE39_STAGE_DIAGNOSING_BUGS.")
end = source.index("\nrun_codex_acceptance", start)
prompt = source[start:end]
assert "prescribed analysis" in prompt

for required in (
    "review_capture_children",
    "review_capture_calls",
    "obsidian_wiki_stage_capture_plan",
    "snapshot_repository_state",
    "REVIEW_ROUTER_PRODUCT_BEFORE",
    "REVIEW_ROUTER_VAULT_BEFORE",
    "REVIEW_ROUTER_OUTBOX_BEFORE",
    "review_capture_spawn_outputs",
    "review_capture_wait_outputs",
    "review_capture_wait_results",
    "review_child_terminal_messages",
    "waits_until_capture_terminal",
    "review_capture_terminal_messages",
    "researcher-role-private-in-coordinator",
    "researcher-role-loaded-by-child",
    "research_waits_until_terminal",
    "role_load_failure_events",
    "<name>grill-adapter:break-loop</name>",
    "debug_terminal = terminal_message(debug_events)",
):
    assert required in source, required

review_prompt = source.index("export ACCEPTANCE_PROMPT='ISSUE35_STAGE_CODE_REVIEW.")
review_snapshot = source.rfind('REVIEW_ROUTER_PRODUCT_BEFORE="$(snapshot_repository_state', 0, review_prompt)
review_state_assertion = source.index("router-driven review Capture changed project state", review_prompt)
assert review_snapshot >= 0
assert review_snapshot < review_prompt < review_state_assertion

capture_spawn = source.index("review_capture_spawns = [")
assert source.index('"wait_agent"', capture_spawn) > capture_spawn
assert source.index('["task_name"] == review_capture_child_path', capture_spawn) > capture_spawn
assert source.index('review_capture_wait_outputs = [', capture_spawn) > capture_spawn
assert source.index('review_capture_wait_results = [', capture_spawn) > capture_spawn
assert source.index('"message": "Wait timed out."', capture_spawn) > capture_spawn
assert source.index('review_capture_wait_results[-1] == {"message": "Wait completed.", "timed_out": False}', capture_spawn) > capture_spawn
assert source.index('review_child_terminal_messages = [', capture_spawn) > capture_spawn
assert source.index('review_capture_terminal_messages[0][1].get("author") == review_capture_child_path', capture_spawn) > capture_spawn
assert source.index('all(call.get("name") == "wait_agent" for _, call in waits_until_capture_terminal)', capture_spawn) > capture_spawn
assert source.index('review_capture_result["status"] == "ok"', capture_spawn) > capture_spawn

runner = source.index("run_codex_acceptance()")
eof_handler = source.index("    eof {", runner)
cleanup = source.index("if {!$child_closed} {", eof_handler)
assert source.index("set child_closed 0", runner, eof_handler) >= 0
assert source.index("set child_closed 1", eof_handler, cleanup) >= 0
assert source.index('send -- "\\003"', cleanup) > cleanup
PY

printf 'codex context isolation acceptance contract smoke OK\n'
