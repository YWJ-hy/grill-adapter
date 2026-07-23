#!/usr/bin/env bash
set -euo pipefail

# Asserts the host-adapter convention blocks carry every touchpoint the dropped native
# patches used to inject (blueprint §3, §8.5-8.7), and that the plugin's hooks.json wires the
# three hooks to the right events. This is the convention-based replacement for the removed
# "patch into Superpowers brainstorming/writing-plans/..." coupling.
#
# The blocks are written into a target project's CLAUDE.md, which is NOT plugin content, so
# Claude Code never substitutes ${CLAUDE_PLUGIN_ROOT} there and the version-scoped plugin
# path must not be baked in either. Hence: the blocks name skills, and carry no path at all.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
GRILL="$ROOT/host-adapters/grill/CLAUDE.md"
PLAIN="$ROOT/host-adapters/plain/CLAUDE.md"
CODEX_GRILL="$ROOT/host-adapters/grill/AGENTS.md"
CODEX_PLAIN="$ROOT/host-adapters/plain/AGENTS.md"
HOOKS_JSON="$ROOT/hooks/hooks.json"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }
deny() { ! grep -Fq "$2" "$1" || fail "$1 must not contain: $2"; }

for f in "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN" "$HOOKS_JSON"; do
  [[ -f "$f" ]] || fail "missing host-adapter file: $f"
done

# Codex blocks carry the same touchpoints with native skill mentions.
for skill in wiki-readiness wiki-research wiki-materialize update-wiki candidate-journal source-truth-check break-loop; do
  need "$CODEX_GRILL" "\$grill-adapter:$skill"
done
need "$CODEX_GRILL" '$mattpocock-skills:grill-with-docs'
need "$CODEX_GRILL" '$mattpocock-skills:to-tickets'
need "$CODEX_GRILL" '$mattpocock-skills:implement'
need "$CODEX_PLAIN" '$grill-adapter:wiki-research'
need "$CODEX_PLAIN" '$grill-adapter:wiki-readiness'
need "$CODEX_PLAIN" '$grill-adapter:wiki-materialize'
need "$CODEX_PLAIN" 'plain Codex host'

# grill block: markers + zero-patch invariant + all four wiki touchpoints + subsystems.
# Skills are plugin skills, so every invocation must carry the grill-adapter: namespace.
need "$GRILL" 'grill-adapter:host:grill:start'
need "$GRILL" 'grill-adapter:host:grill:end'
need "$GRILL" 'never patches any grill skill'
need "$GRILL" '/grill-adapter:wiki-research'       # Disclose
need "$GRILL" '/grill-adapter:wiki-readiness'      # implementation-entry readiness
need "$GRILL" '/grill-adapter:wiki-materialize'    # Bind
need "$GRILL" '/grill-adapter:update-wiki'         # Capture
need "$GRILL" '/grill-adapter:candidate-journal'   # feature journal
need "$GRILL" '/grill-adapter:source-truth-check'  # source-of-truth Verify
need "$GRILL" '/grill-adapter:break-loop'          # break-loop
need "$GRILL" 'grill-with-docs'
need "$GRILL" 'to-tickets'
need "$GRILL" 'diagnosing-bugs'

# plain block: same touchpoints, host-name-free framing
need "$PLAIN" 'grill-adapter:host:plain:start'
need "$PLAIN" '/grill-adapter:wiki-research'
need "$PLAIN" '/grill-adapter:wiki-readiness'
need "$PLAIN" '/grill-adapter:wiki-materialize'
need "$PLAIN" '/grill-adapter:update-wiki'
need "$PLAIN" '/grill-adapter:candidate-journal'
need "$PLAIN" '/grill-adapter:source-truth-check'
need "$PLAIN" '/grill-adapter:break-loop'
need "$PLAIN" 'no host skill is patched'

# Every knowledge-producing workflow stage targets the same mechanical feature journal.
for f in "$GRILL" "$PLAIN"; do
  need "$f" 'grill-with-docs'
  need "$f" 'specification'
  need "$f" 'tickets'
  need "$f" 'implementation'
  need "$f" 'review'
  need "$f" 'debugging'
  need "$f" 'wiki-candidates.jsonl'
done

# The implementation entry is one readiness seam for formal tickets, direct tracker issues,
# and confirmed conversational work. It must run before code changes and preserve fail-open host
# availability without allowing broken or partial Wiki content into execution.
for f in "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN"; do
  need "$f" 'before the first code edit'
  need "$f" 'formal finalized context'
  need "$f" 'direct tracker issue'
  need "$f" 'manual'
  need "$f" 'no-relevant'
  need "$f" 'disabled'
  need "$f" 'broken'
  need "$f" 'continue without Wiki context'
  need "$f" 'must not'
done

# Neither block may carry an install path: they land outside plugin content, where
# ${CLAUDE_PLUGIN_ROOT} is never substituted, and a baked absolute path would rot on the
# next plugin update (the cache path is version-scoped).
for f in "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN"; do
  need "$f" 'resumable publisher'
  need "$f" 'explicit Git publishing confirmation'
  need "$f" 'Open PR content remains unavailable to formal research'
  deny "$f" '__GRILL_ADAPTER_ROOT__'
  deny "$f" 'CLAUDE_PLUGIN_ROOT'
  deny "$f" 'PLUGIN_ROOT'
  deny "$f" 'grill_context_to_candidates.py'
done

# Removed capabilities must not remain in project instructions for either runtime.
REMOVED_CAPABILITY='lan''hu'
REMOVED_CAPABILITY_CN=$'\u84dd\u6e56'
for f in "$GRILL" "$PLAIN" "$CODEX_GRILL" "$CODEX_PLAIN"; do
  ! grep -Fiq "$REMOVED_CAPABILITY" "$f" || fail "$f still references a removed capability"
  ! grep -Fq "$REMOVED_CAPABILITY_CN" "$f" || fail "$f still references a removed capability"
done

# ...and the grill->wiki bridge the blocks used to invoke now lives in the skill that
# consumes its output, where the path does get substituted.
need "$ROOT/skills/update-wiki/SKILL.md" 'grill_context_to_candidates.py'
need "$ROOT/skills/update-wiki/SKILL.md" '${CLAUDE_PLUGIN_ROOT}/scripts/grill_context_to_candidates.py'
need "$ROOT/skills/update-wiki/SKILL.md" '${CLAUDE_PLUGIN_ROOT}/mcp/obsidian-wiki/dist/index.js publish'

# no residual Superpowers host references in the host blocks
if grep -nE 'Superpowers' "$GRILL" "$PLAIN" | grep -vE '\.adapter/'; then
  fail "host blocks still reference Superpowers"
fi

# plugin hooks.json wires the three hooks to the right events, rooted at the plugin
python3 - "$HOOKS_JSON" <<'PY' || exit 1
import json, sys
h = json.load(open(sys.argv[1], encoding='utf-8'))["hooks"]
def cmds(ev): return [x["command"] for g in h.get(ev, []) for x in g["hooks"]]
assert not cmds("UserPromptSubmit"), "UserPromptSubmit must not reread wiki constraints"
assert any("wiki-reread.sh" in c for c in cmds("SessionStart")), "wiki-reread not on SessionStart"
assert any("source-truth-lint.sh" in c for c in cmds("PostToolUse")), "source-truth-lint not on PostToolUse"
assert any("wiki-capture-suggest.sh" in c for c in cmds("Stop")), "wiki-capture-suggest not on Stop"
every = [x["command"] for ev in h.values() for g in ev for x in g["hooks"]]
assert all("${CLAUDE_PLUGIN_ROOT}/hooks/" in c for c in every), "hook command not plugin-rooted"
PY

printf 'host conventions smoke OK\n'
