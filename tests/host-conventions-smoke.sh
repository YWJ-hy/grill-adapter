#!/usr/bin/env bash
set -euo pipefail

# Asserts the host-adapter convention blocks carry every touchpoint the dropped native
# patches used to inject (blueprint §3, §8.5-8.7), and that the canonical hook fragment
# wires the three hooks to the right events. This is the convention-based replacement for
# the removed "patch into Superpowers brainstorming/writing-plans/..." coupling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
GRILL="$ROOT/host-adapters/grill/CLAUDE.md"
PLAIN="$ROOT/host-adapters/plain/CLAUDE.md"
HOOKS_JSON="$ROOT/host-adapters/hooks.settings.json"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

for f in "$GRILL" "$PLAIN" "$HOOKS_JSON"; do
  [[ -f "$f" ]] || fail "missing host-adapter file: $f"
done

# grill block: markers + zero-patch invariant + all four wiki touchpoints + subsystems
need "$GRILL" 'grill-adapter:host:grill:start'
need "$GRILL" 'grill-adapter:host:grill:end'
need "$GRILL" 'never patches any grill skill'
need "$GRILL" '/wiki-research'          # Disclose
need "$GRILL" '/wiki-materialize'       # Bind
need "$GRILL" '/update-wiki'            # Capture
need "$GRILL" '/source-truth-check'     # source-of-truth Verify
need "$GRILL" '/lanhu-requirements'     # Lanhu Intake
need "$GRILL" '/break-loop'             # break-loop
need "$GRILL" 'grill_context_to_candidates.py'   # grill->wiki bridge
need "$GRILL" '__GRILL_ADAPTER_ROOT__'  # payload placeholder (install replaces it)
need "$GRILL" 'grill-with-docs'
need "$GRILL" 'to-tickets'
need "$GRILL" 'diagnosing-bugs'
# Lanhu evidence boundary preserved
need "$GRILL" 'input only'

# plain block: same touchpoints, host-name-free framing
need "$PLAIN" 'grill-adapter:host:plain:start'
need "$PLAIN" '/wiki-research'
need "$PLAIN" '/wiki-materialize'
need "$PLAIN" '/update-wiki'
need "$PLAIN" '/source-truth-check'
need "$PLAIN" '/break-loop'
need "$PLAIN" 'no host skill is patched'

# no residual Superpowers host references in the host blocks
if grep -nE 'Superpowers' "$GRILL" "$PLAIN" | grep -vE '\.adapter/'; then
  fail "host blocks still reference Superpowers"
fi

# canonical hook fragment wires the three hooks to the right events
python3 - "$HOOKS_JSON" <<'PY' || exit 1
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
def cmds(ev): return [x["command"] for g in h.get(ev, []) for x in g["hooks"]]
assert any("wiki-reread.sh" in c for c in cmds("UserPromptSubmit")), "wiki-reread not on UserPromptSubmit"
assert any("wiki-reread.sh" in c for c in cmds("SessionStart")), "wiki-reread not on SessionStart"
assert any("source-truth-lint.sh" in c for c in cmds("PostToolUse")), "source-truth-lint not on PostToolUse"
assert any("wiki-capture-suggest.sh" in c for c in cmds("Stop")), "wiki-capture-suggest not on Stop"
assert all("__GRILL_ADAPTER_ROOT__/hooks/" in c for ev in h.values() for g in ev for c in [x["command"] for x in g["hooks"]]), "hook command not payload-rooted"
PY

printf 'host conventions smoke OK\n'
