#!/usr/bin/env bash
set -euo pipefail

# Exercises project wiring for both plugin runtimes. `install` writes only the host convention
# block into CLAUDE.md and/or AGENTS.md; the plugin carries every runtime component.
#
# Verifies content preservation, idempotency, host switch, clean uninstall, and -- the two
# assertions that lock the plugin model in -- that install touches neither ~/.claude nor the
# project's .claude/settings.json. Fully sandboxed (throwaway ~/.claude + project).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
INSTALL="$ROOT/lib/install.py"
source "${SCRIPT_DIR}/_windows-compat.bash"

SANDBOX="$(mktemp -d)"; PROJ="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$PROJ"' EXIT
( cd "$PROJ" && git init -q ) 2>/dev/null || true
export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
export CODEX_HOME="$SANDBOX/.codex"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

printf '# Demo project\n\nPre-existing content.\n' > "$PROJ/CLAUDE.md"
printf '# Demo Codex project\n\nPre-existing Codex content.\n' > "$PROJ/AGENTS.md"

# Unknown legacy settings and user-owned historical artifacts survive every lifecycle command.
REMOVED_KEY='lan''hu'
REMOVED_DIR="$PROJ/.$REMOVED_KEY"
mkdir -p "$REMOVED_DIR" "$PROJ/.adapter"
printf 'historical user artifact\n' > "$REMOVED_DIR/index.md"
printf '{"%s":{"role":"frontend"}}\n' "$REMOVED_KEY" > "$PROJ/.adapter/settings.json"
ARTIFACT_HASH="$(sha256_file "$REMOVED_DIR/index.md")"
SETTINGS_HASH="$(sha256_file "$PROJ/.adapter/settings.json")"

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
[[ ! -d "$SANDBOX/.codex/skills" ]] || fail "install wrote user-level Codex skills"
[[ ! -d "$SANDBOX/.codex/plugins" ]] || fail "project wiring installed a Codex plugin"

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

# Codex wiring targets AGENTS.md and leaves CLAUDE.md untouched.
python3 "$INSTALL" install "$PROJ" --host grill --runtime codex >/dev/null 2>&1 || fail "Codex install failed"
grep -q 'grill-adapter:host:grill:start' "$PROJ/AGENTS.md" || fail "Codex grill host block missing"
grep -q 'Pre-existing Codex content.' "$PROJ/AGENTS.md" || fail "Codex install clobbered AGENTS.md"
grep -q '\$grill-adapter:wiki-research' "$PROJ/AGENTS.md" || fail "Codex skill reference missing"
! grep -q 'CLAUDE_PLUGIN_ROOT\|PLUGIN_ROOT' "$PROJ/AGENTS.md" || fail "Codex host block contains a plugin path"
python3 "$INSTALL" verify "$PROJ" --host grill --runtime codex >/dev/null 2>&1 || fail "Codex verify failed"
python3 "$INSTALL" install "$PROJ" --host plain --runtime codex >/dev/null 2>&1 || fail "Codex host switch failed"
grep -q 'grill-adapter:host:plain:start' "$PROJ/AGENTS.md" || fail "Codex plain block missing"
[[ "$(grep -c 'grill-adapter:host:.*:start' "$PROJ/AGENTS.md")" == "1" ]] || fail "Codex host blocks accumulated"
python3 "$INSTALL" uninstall "$PROJ" --runtime codex >/dev/null 2>&1 || fail "Codex uninstall failed"
! grep -q 'grill-adapter:host:' "$PROJ/AGENTS.md" || fail "Codex host block not removed"
grep -q 'Pre-existing Codex content.' "$PROJ/AGENTS.md" || fail "Codex uninstall clobbered AGENTS.md"

# A dual-runtime project can wire and verify both instruction files in one command.
python3 "$INSTALL" install "$PROJ" --host grill --runtime both >/dev/null 2>&1 || fail "dual-runtime install failed"
python3 "$INSTALL" verify "$PROJ" --host grill --runtime both >/dev/null 2>&1 || fail "dual-runtime verify failed"
[[ "$(sha256_file "$REMOVED_DIR/index.md")" == "$ARTIFACT_HASH" ]] || fail "install/verify changed a historical artifact"
[[ "$(sha256_file "$PROJ/.adapter/settings.json")" == "$SETTINGS_HASH" ]] || fail "install/verify changed legacy settings"
bash "$ROOT/doctor.sh" "$PROJ" >/dev/null 2>&1 || fail "doctor rejected unrelated legacy settings"
[[ "$(sha256_file "$REMOVED_DIR/index.md")" == "$ARTIFACT_HASH" ]] || fail "doctor changed a historical artifact"
[[ "$(sha256_file "$PROJ/.adapter/settings.json")" == "$SETTINGS_HASH" ]] || fail "doctor changed legacy settings"
python3 "$INSTALL" uninstall "$PROJ" --runtime both >/dev/null 2>&1 || fail "dual-runtime uninstall failed"

printf 'install project-wiring smoke OK\n'
