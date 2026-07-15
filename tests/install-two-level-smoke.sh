#!/usr/bin/env bash
set -euo pipefail

# Exercises the two-level install model (blueprint §8.4): user-level payload + skills/agents,
# project-level hooks + CLAUDE.md block. Verifies placeholder replacement, idempotency,
# host switch, and clean uninstall. Fully sandboxed (throwaway ~/.claude + project).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
INSTALL="$ROOT/lib/install.py"

SANDBOX="$(mktemp -d)"; PROJ="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$PROJ"' EXIT
( cd "$PROJ" && git init -q ) 2>/dev/null || true
export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
export GRILL_ADAPTER_HOME="$SANDBOX/.claude/grill-adapter"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

python3 "$INSTALL" install "$PROJ" --host grill >/dev/null 2>&1 || fail "install failed"

# user-level payload + skills + agents present
[[ -f "$GRILL_ADAPTER_HOME/scripts/wiki_materialize_task.py" ]] || fail "payload scripts missing"
[[ -f "$GRILL_ADAPTER_HOME/hooks/wiki-reread.sh" ]] || fail "payload hooks missing"
[[ -f "$SANDBOX/.claude/skills/wiki-research/SKILL.md" ]] || fail "wiki-research skill not installed"
[[ -f "$SANDBOX/.claude/skills/wiki-materialize/SKILL.md" ]] || fail "wiki-materialize skill not installed"
[[ -f "$SANDBOX/.claude/skills/source-truth-check/SKILL.md" ]] || fail "source-truth-check skill not installed"
[[ -f "$SANDBOX/.claude/agents/wiki-researcher.md" ]] || fail "wiki-researcher agent not installed"

# placeholder fully replaced with the real payload path
grep -Fq "$GRILL_ADAPTER_HOME/scripts/wiki_materialize_task.py" "$SANDBOX/.claude/skills/wiki-materialize/SKILL.md" \
  || fail "placeholder not replaced in installed skill"
! grep -q '__GRILL_ADAPTER_ROOT__' "$SANDBOX/.claude/skills/wiki-materialize/SKILL.md" || fail "placeholder residue in installed skill"

# project-level: hooks + host block
python3 - "$PROJ" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1] + "/.claude/settings.json"))
cmds = [h["command"] for ev in d["hooks"].values() for g in ev for h in g["hooks"]]
assert any("wiki-reread.sh" in c for c in cmds), "wiki-reread hook missing"
assert any("source-truth-lint.sh" in c for c in cmds), "source-truth-lint hook missing"
assert any("wiki-capture-suggest.sh" in c for c in cmds), "wiki-capture-suggest hook missing"
assert all("grill-adapter/hooks/" in c for c in cmds if "hooks/" in c), "hook command not under payload"
PY
grep -q 'grill-adapter:host:grill:start' "$PROJ/CLAUDE.md" || fail "grill host block missing"

# verify passes
python3 "$INSTALL" verify "$PROJ" --host grill >/dev/null 2>&1 || fail "verify failed after install"

# idempotent re-install: hook count unchanged
BEFORE=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(len(g["hooks"]) for ev in d["hooks"].values() for g in ev))' "$PROJ/.claude/settings.json")
python3 "$INSTALL" install "$PROJ" --host grill >/dev/null 2>&1 || fail "re-install failed"
AFTER=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(len(g["hooks"]) for ev in d["hooks"].values() for g in ev))' "$PROJ/.claude/settings.json")
[[ "$BEFORE" == "$AFTER" ]] || fail "re-install duplicated hooks ($BEFORE -> $AFTER)"

# host switch grill -> plain: exactly one host block, plain not grill
python3 "$INSTALL" install "$PROJ" --host plain >/dev/null 2>&1 || fail "host switch failed"
grep -q 'grill-adapter:host:plain:start' "$PROJ/CLAUDE.md" || fail "plain block missing after switch"
! grep -q 'grill-adapter:host:grill:start' "$PROJ/CLAUDE.md" || fail "grill block not replaced on switch"
[[ "$(grep -c 'grill-adapter:host:.*:start' "$PROJ/CLAUDE.md")" == "1" ]] || fail "host blocks accumulated"

# uninstall clears everything
python3 "$INSTALL" uninstall "$PROJ" >/dev/null 2>&1 || fail "uninstall failed"
[[ ! -d "$GRILL_ADAPTER_HOME" ]] || fail "payload not removed on uninstall"
[[ ! -d "$SANDBOX/.claude/skills/wiki-research" ]] || fail "skill not removed on uninstall"
! grep -q 'grill-adapter:host:' "$PROJ/CLAUDE.md" 2>/dev/null || fail "host block not removed on uninstall"

printf 'install two-level smoke OK\n'
