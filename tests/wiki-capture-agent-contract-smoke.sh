#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
agent = (root / "agents" / "wiki-capture.md").read_text(encoding="utf-8")
outbox_agent = (root / "agents" / "wiki-outbox-consolidation.md").read_text(encoding="utf-8")
skill = (root / "skills" / "update-wiki" / "SKILL.md").read_text(encoding="utf-8")
server = (root / "mcp" / "obsidian-wiki" / "src" / "server.ts").read_text(encoding="utf-8")
outbox = (root / "mcp" / "obsidian-wiki" / "src" / "outbox.ts").read_text(encoding="utf-8")
role_manifest = (root / "contracts" / "child-role-loader-v1.json").read_text(encoding="utf-8")

for required in (
    "name: wiki-capture",
    "disallowedTools: Task, Agent, Bash, Write, Edit",
    "obsidian_wiki_consolidation_candidates",
    "obsidian_wiki_capture_draft_view",
    "obsidian_wiki_stage_capture_plan",
    "exactly once",
    "at most `noteReadLimit`",
    "Do not call `obsidian_wiki_propose_note_change`",
    "Do not modify the formal Vault or base worktree",
    "Do not run Git",
    "Do not modify a candidate journal",
    "Never return candidate claims",
    "Return exactly one JSON object and no prose",
    '"kind": "grill-adapter.wiki-capture-result"',
    '"counts": { "queued": 0, "skipped": 0, "needsDecision": 0 }',
    '"status": "broken"',
):
    assert required in agent, required

for required in (
    "`Capture` is the default mode",
    "Spawn exactly one Capture agent",
    "agent path is a handle, not a result",
    "The wait is the only legal next operation after dispatch",
    "same agent path until terminal",
    "fork_turns: \"none\"",
    "collaboration.spawn_agent",
    "collaboration.wait_agent",
    "300000",
    "Never call the generic",
    "roleDescriptor",
    "expectedDigest",
    "child_role_loader.py load",
    "role-load-failed",
    "no feature slug",
    "outbox status",
    "outbox review",
    "outbox correct",
    "outbox publish",
    "outbox-consolidation",
    "semantically equivalent",
    "contradictory",
    "immutable successor",
    "exact digest-bound",
    "`queued`, `pr-open`, and `active`",
    "broken",
):
    assert required in skill, required

for required in (
    "obsidian_wiki_stage_capture_plan",
    "obsidian_wiki_capture_draft_view",
    "destructiveHint: false",
    "readOnlyHint: true",
):
    assert required in server, required

for required in (
    "name: wiki-outbox-consolidation",
    '"mode":"outbox-consolidation"',
    "obsidian_wiki_outbox_review",
    "obsidian_wiki_outbox_correct",
    "action: merge",
    "action: defer",
    "Leave independent contracts unchanged",
    "Never exclude or delete automatically",
):
    assert required in outbox_agent, required

for forbidden in (
    "obsidian_wiki_maintenance_summary",
    "obsidian_wiki_consolidation_candidates",
    "mode: audit",
    "mode: consolidation",
):
    assert forbidden not in outbox_agent, forbidden

for required in (
    "grill-adapter:wiki-capture",
    "grill-adapter:wiki-maintenance-audit",
    "grill-adapter:wiki-maintenance-consolidation",
    "grill-adapter:wiki-outbox-consolidation",
):
    assert required in role_manifest, required

for required in (
    "refs/grill-adapter/outbox/",
    "worktree",
    "projectId",
    "Capture Plan journal snapshot drift",
    "base drift requires a refreshed Outbox review",
    "planDigest",
    "OutboxCorrectionSchema",
    "supersedes",
    "same-path-base-drift",
):
    assert required in outbox, required

for forbidden in (
    "Default Capture ends after all outcomes are recorded",
    "publish <feature-slug>",
    "obsidian_wiki_apply_note_change` only when policy permits",
):
    assert forbidden not in skill, forbidden
PY

printf 'wiki capture agent contract smoke OK\n'
