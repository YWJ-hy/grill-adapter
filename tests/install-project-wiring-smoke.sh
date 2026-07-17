#!/usr/bin/env bash
set -euo pipefail

# Exercises the project-wiring install model: grill-adapter ships as a Claude Code plugin, so
# `install` writes exactly one thing -- the host convention block in the target project's
# CLAUDE.md. Skills, agents, hooks and the shared-wiki MCP all travel inside the plugin and
# are activated by `claude plugin install`, never copied by this engine.
#
# Verifies content preservation, idempotency, host switch, clean uninstall, and -- the two
# assertions that lock the plugin model in -- that install touches neither ~/.claude nor the
# project's .claude/settings.json. Fully sandboxed (throwaway ~/.claude + project).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
INSTALL="$ROOT/lib/install.py"

SANDBOX="$(mktemp -d)"; PROJ="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$PROJ"' EXIT
( cd "$PROJ" && git init -q ) 2>/dev/null || true
export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

printf '# Demo project\n\nPre-existing content.\n' > "$PROJ/CLAUDE.md"

python3 "$INSTALL" install "$PROJ" --host grill >/dev/null 2>&1 || fail "install failed"

# the one thing install does: write the host block, keeping what was already there
grep -q 'grill-adapter:host:grill:start' "$PROJ/CLAUDE.md" || fail "grill host block missing"
grep -q 'Pre-existing content.' "$PROJ/CLAUDE.md" || fail "install clobbered existing CLAUDE.md content"

# nothing is installed user-level any more -- the plugin carries skills/agents/payload
[[ ! -d "$SANDBOX/.claude/skills" ]] || fail "install wrote user-level skills (plugin should carry them)"
[[ ! -d "$SANDBOX/.claude/agents" ]] || fail "install wrote user-level agents (plugin should carry them)"
[[ ! -d "$SANDBOX/.claude/grill-adapter" ]] || fail "install wrote a user-level payload (plugin should carry it)"

# hooks ship as plugin hooks/hooks.json -- never merged into the project's settings.json
if [[ -f "$PROJ/.claude/settings.json" ]]; then
  ! grep -q 'wiki-reread\.sh\|source-truth-lint\.sh\|wiki-capture-suggest\.sh' "$PROJ/.claude/settings.json" \
    || fail "install merged hooks into project settings.json (plugin hooks/hooks.json should register them)"
fi

# the convention block hard-codes no install path: the plugin root is version-scoped and
# would go stale on the next plugin update
! grep -q '__GRILL_ADAPTER_ROOT__' "$PROJ/CLAUDE.md" || fail "dead placeholder in written host block"
! grep -q 'CLAUDE_PLUGIN_ROOT' "$PROJ/CLAUDE.md" \
  || fail "host block references \${CLAUDE_PLUGIN_ROOT}, which is never substituted outside plugin content"

# verify passes
python3 "$INSTALL" verify "$PROJ" --host grill >/dev/null 2>&1 || fail "verify failed after install"

# idempotent re-install: exactly one block
python3 "$INSTALL" install "$PROJ" --host grill >/dev/null 2>&1 || fail "re-install failed"
[[ "$(grep -c 'grill-adapter:host:.*:start' "$PROJ/CLAUDE.md")" == "1" ]] || fail "re-install duplicated the host block"

# host switch grill -> plain: exactly one host block, plain not grill
python3 "$INSTALL" install "$PROJ" --host plain >/dev/null 2>&1 || fail "host switch failed"
grep -q 'grill-adapter:host:plain:start' "$PROJ/CLAUDE.md" || fail "plain block missing after switch"
! grep -q 'grill-adapter:host:grill:start' "$PROJ/CLAUDE.md" || fail "grill block not replaced on switch"
[[ "$(grep -c 'grill-adapter:host:.*:start' "$PROJ/CLAUDE.md")" == "1" ]] || fail "host blocks accumulated"

# uninstall strips the block and leaves the rest of CLAUDE.md intact
python3 "$INSTALL" uninstall "$PROJ" >/dev/null 2>&1 || fail "uninstall failed"
! grep -q 'grill-adapter:host:' "$PROJ/CLAUDE.md" 2>/dev/null || fail "host block not removed on uninstall"
grep -q 'Pre-existing content.' "$PROJ/CLAUDE.md" || fail "uninstall clobbered existing CLAUDE.md content"

# verify fails closed once unwired
if python3 "$INSTALL" verify "$PROJ" --host grill >/dev/null 2>&1; then
  fail "verify passed on an unwired project"
fi

printf 'install project-wiring smoke OK\n'
