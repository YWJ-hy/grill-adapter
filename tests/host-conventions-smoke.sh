#!/usr/bin/env bash
set -euo pipefail

# Host conventions are intentionally thin stage routers. The detailed state machines,
# permissions, failures, and recovery paths belong to the entry skills. One canonical
# specification renders both Claude Code and Codex variants, so their syntax cannot drift.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SPEC="$ROOT/contracts/host-conventions-v1.json"
RENDER="$ROOT/scripts/render_host_conventions.py"
BUDGET="$ROOT/contracts/codex-context-budget-v1.json"
GRILL="$ROOT/host-adapters/grill/CLAUDE.md"
PLAIN="$ROOT/host-adapters/plain/CLAUDE.md"
CODEX_GRILL="$ROOT/host-adapters/grill/AGENTS.md"
CODEX_PLAIN="$ROOT/host-adapters/plain/AGENTS.md"
HOOKS_JSON="$ROOT/hooks/hooks.json"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$1 missing: $2"; }
deny() { ! grep -Fq -- "$2" "$1" || fail "$1 must not contain: $2"; }

for f in "$SPEC" "$RENDER" "$BUDGET" "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN" "$HOOKS_JSON"; do
  [[ -f "$f" ]] || fail "missing host convention input: $f"
done

# The committed runtime files are derived outputs, not four independently edited manuals.
python3 "$RENDER" --root "$ROOT" --check || fail "host convention outputs are out of sync"

# The neutral specification itself is the routing contract. Presence-only checks would allow a
# skill to drift into the wrong host stage while all four generated files still agreed.
python3 - "$SPEC" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))

expected = {
    "grill": {
        "routes": [
            ("grill-with-docs", ["wiki-research"]),
            ("to-spec", ["source-truth-check"]),
            ("to-tickets", ["wiki-research", "source-truth-check"]),
            ("implement", ["wiki-readiness"]),
            ("code-review (before reviewers)", ["wiki-readiness"]),
            ("code-review (after accepted review)", ["update-wiki"]),
            ("diagnosing-bugs (after evidence narrows the cause)", ["wiki-research"]),
            ("diagnosing-bugs (after a verified fix)", ["break-loop"]),
        ],
        "crossStage": [
            ("Any stage with a durable candidate", ["candidate-journal"]),
            ("Explicit knowledge upkeep", ["wiki-maintenance"]),
        ],
    },
    "plain": {
        "routes": [
            ("Before an approach", ["wiki-research"]),
            ("Before finalizing a spec", ["source-truth-check"]),
            ("Implementation plan", ["wiki-research", "source-truth-check"]),
            ("Before code changes", ["wiki-readiness"]),
            ("Before reviewers", ["wiki-readiness"]),
            ("Accepted review", ["update-wiki"]),
            ("After evidence narrows the debugging cause", ["wiki-research"]),
            ("After a verified debugging fix", ["break-loop"]),
        ],
        "crossStage": [
            ("Any stage with a durable candidate", ["candidate-journal"]),
            ("Explicit knowledge upkeep", ["wiki-maintenance"]),
        ],
    },
}

actual = {
    host: {
        group: [(entry["moment"], entry["skills"]) for entry in spec["hosts"][host][group]]
        for group in ("routes", "crossStage")
    }
    for host in expected
}
assert actual == expected, f"unexpected host routing: {actual!r}"
PY

# #39 replaces #38's baseline-sized host payload with an approved fixed router budget.
python3 - "$BUDGET" "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
limit = contract["limits"]["projectHostInstructions"]
assert limit == 4096, f"unexpected host instruction budget: {limit}"
for raw_path in sys.argv[2:]:
    path = pathlib.Path(raw_path)
    size = len(path.read_bytes())
    assert size <= limit, f"{path} is {size} bytes; limit is {limit}"
PY

# The grill router must preserve the explicit-stage activation gate and map every existing
# workflow touchpoint to its host-independent entry skill.
need "$GRILL" 'Activation gate:'
need "$GRILL" 'Do not infer a stage from an ordinary request.'
need "$GRILL" 'When no matching stage is active, do not route adapter work.'
need "$GRILL" "During a matching active stage, invoke every listed entry skill at its row's stated workflow moment; the route is mandatory, not advisory. Do not invoke a later-moment route early."
need "$GRILL" 'An explicit adapter-skill invocation remains available outside a grill stage.'
need "$CODEX_GRILL" 'Activation gate:'
need "$CODEX_GRILL" 'Do not infer a stage from an ordinary request.'
need "$CODEX_GRILL" 'When no matching stage is active, do not route adapter work.'
need "$CODEX_GRILL" "During a matching active stage, invoke every listed entry skill at its row's stated workflow moment; the route is mandatory, not advisory. Do not invoke a later-moment route early."
need "$CODEX_GRILL" 'An explicit adapter-skill invocation remains available outside a grill stage.'

for stage in grill-with-docs to-spec to-tickets implement code-review diagnosing-bugs; do
  need "$GRILL" "/$stage"
  need "$CODEX_GRILL" "\$mattpocock-skills:$stage"
done

for skill in wiki-research source-truth-check wiki-readiness update-wiki candidate-journal break-loop wiki-maintenance; do
  need "$GRILL" "/grill-adapter:$skill"
  need "$PLAIN" "/grill-adapter:$skill"
  need "$CODEX_GRILL" "\$grill-adapter:$skill"
  need "$CODEX_PLAIN" "\$grill-adapter:$skill"
done

# Plain hosts keep manual timing, never infer a host workflow stage, and expose the same routes.
for f in "$PLAIN" "$CODEX_PLAIN"; do
  need "$f" 'Activation gate:'
  need "$f" 'Plain workflows do not infer a host stage.'
  need "$f" 'When an explicit workflow moment matches a row, invoke every listed entry skill at that moment; the route is mandatory, not advisory.'
done

# Capture and retrospective routes are mandatory only at their later workflow moments.
python3 - "$GRILL" "$CODEX_GRILL" <<'PY'
import pathlib
import sys

for raw_path in sys.argv[1:]:
    text = pathlib.Path(raw_path).read_text(encoding="utf-8")
    assert text.index("code-review (before reviewers)") < text.index("code-review (after accepted review)")
    assert text.index("diagnosing-bugs (after evidence narrows the cause)") < text.index("diagnosing-bugs (after a verified fix)")
PY

# Task identity and local state are the only durable cross-stage facts a router carries.
need "$GRILL" 'Roster boundary:'
need "$GRILL" 'verbatim ticket text'
need "$PLAIN" 'Roster boundary:'
need "$PLAIN" 'one stable task id'
for f in "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN"; do
  need "$f" 'Each entry skill owns its detailed state machine, permissions, failures, and recovery.'
  need "$f" 'State boundary:'
  need "$f" '.grill-adapter/context/'
  need "$f" "do not commit it or bypass an entry skill's documented workflow when changing it."
  need "$f" '`.grill-adapter/settings.json` is project configuration.'
  need "$f" 'never patches host skills'
  deny "$f" 'do not hand-edit or commit it.'
  deny "$f" '__GRILL_ADAPTER_ROOT__'
  deny "$f" 'CLAUDE_PLUGIN_ROOT'
  deny "$f" 'PLUGIN_ROOT'
  deny "$f" 'wiki_context_render.py'
  deny "$f" 'wiki_readiness.py'
  deny "$f" 'obsidian_wiki_'
  deny "$f" 'wiki-materialize'
  deny "$f" 'review-handoff'
  deny "$f" 'wiki-implement.md'
  deny "$f" 'wiki-review.md'
  deny "$f" 'fork_turns'
done

deny "$GRILL" '$grill-adapter:'
deny "$PLAIN" '$grill-adapter:'
deny "$CODEX_GRILL" '/grill-adapter:'
deny "$CODEX_PLAIN" '/grill-adapter:'

# Detailed operational behavior is still owned by the entry skills, rather than copied into
# project instructions.
need "$ROOT/skills/wiki-research/SKILL.md" 'ticket roster'
need "$ROOT/skills/wiki-research/SKILL.md" 'grill-local-scratch'
need "$ROOT/skills/wiki-research/SKILL.md" 'github-issues'
need "$ROOT/docs/USER_FLOW_CN.md" 'roster 怎么填由 `wiki-research` skill 规定'
deny "$ROOT/docs/USER_FLOW_CN.md" 'roster 怎么填由 host 约定块规定'
need "$ROOT/skills/wiki-readiness/SKILL.md" 'review-handoff'
need "$ROOT/skills/update-wiki/SKILL.md" 'Capture transaction'
need "$ROOT/skills/source-truth-check/SKILL.md" 'truth/edit: never'
need "$ROOT/skills/candidate-journal/SKILL.md" 'append-only'
need "$ROOT/skills/wiki-maintenance/SKILL.md" 'Codex dispatch transaction'
need "$ROOT/skills/break-loop/SKILL.md" 'Handoff Rules'

# No residual Superpowers host references in the router output.
if grep -nE 'Superpowers' "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN"; then
  fail "host blocks still reference Superpowers"
fi

# Plugin hooks remain host-independent and are registered from plugin content.
python3 - "$HOOKS_JSON" <<'PY' || exit 1
import json
import sys

hooks = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]

def commands(event):
    return [entry["command"] for group in hooks.get(event, []) for entry in group["hooks"]]

assert not commands("UserPromptSubmit"), "UserPromptSubmit must not reread wiki constraints"
assert any("wiki-reread.sh" in command for command in commands("SessionStart"))
assert any("source-truth-lint.sh" in command for command in commands("PostToolUse"))
assert any("wiki-capture-suggest.sh" in command for command in commands("Stop"))
every = [entry["command"] for groups in hooks.values() for group in groups for entry in group["hooks"]]
assert all("${CLAUDE_PLUGIN_ROOT}/hooks/" in command for command in every)
PY

printf 'host conventions smoke OK\n'
