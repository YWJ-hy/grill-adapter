#!/usr/bin/env bash
# grill-adapter release-check — full pre-release gate. Non-destructive: the plugin is loaded
# read-only via --plugin-dir and project wiring is exercised against a throwaway project, so
# the caller's real ~/.claude and the passed project are never mutated. The passed
# <project-root> is used read-only by doctor.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-}"
if [[ -z "$PROJECT_ROOT" ]]; then
  printf 'Usage: %s <project-root>\n' "$0" >&2
  exit 1
fi

fail=0
step() { printf '\n=== %s ===\n' "$1"; }
check() { if "$@"; then echo "  OK"; else echo "  FAIL"; fail=1; fi; }

step "1. Python compiles (scripts + lib)"
check python3 -m py_compile "$SCRIPT_DIR"/scripts/*.py "$SCRIPT_DIR"/lib/*.py

step "2. role-prd sync is idempotent (no drift)"
python3 "$SCRIPT_DIR/lib/sync_role_prd.py" sync "$SCRIPT_DIR" >/dev/null 2>&1 || true
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -z "$(git -C "$SCRIPT_DIR" status --porcelain -- agents/lanhu-*-requirements-analyst.md)" ]]; then
    echo "  OK (analysts match sources)"
  else
    echo "  FAIL (sync produced drift; commit the regenerated analysts)"; fail=1
  fi
else
  echo "  SKIP (not a git repo)"
fi

step "3. Placeholder residue check"
# __GRILL_ADAPTER_ROOT__ is dead in plugin content: Claude Code substitutes ${CLAUDE_PLUGIN_ROOT}
# in skill/agent bodies, and nothing install-time rewrites these files any more, so a leftover
# would ship to users verbatim.
residue=0
if grep -rn '__SUPERPOWER_ADAPTER' "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/skills" "$SCRIPT_DIR/agents" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/hooks" "$SCRIPT_DIR/contracts" 2>/dev/null; then
  echo "  FAIL (superpower-adapter placeholder residue)"; residue=1
fi
if grep -rn '__GRILL_ADAPTER_ROOT__' "$SCRIPT_DIR/skills" "$SCRIPT_DIR/agents" "$SCRIPT_DIR/role-prd" "$SCRIPT_DIR/host-adapters" 2>/dev/null; then
  echo "  FAIL (dead __GRILL_ADAPTER_ROOT__ placeholder; use \${CLAUDE_PLUGIN_ROOT} in plugin content, and no install path at all in host-adapters)"; residue=1
fi
[[ $residue -eq 0 ]] && echo "  OK" || fail=1

step "4. shared-wiki MCP typecheck + build + tests"
# `build` is esbuild (a bundler, not a typechecker), so typecheck explicitly -- dropping it
# here would let type errors ship in a green bundle.
if command -v npm >/dev/null 2>&1; then
  ( cd "$SCRIPT_DIR/mcp/shared-wiki" && npm install --no-audit --no-fund >/dev/null 2>&1 && npm run typecheck >/dev/null 2>&1 && npm run build >/dev/null 2>&1 && npm test >/dev/null 2>&1 )
  check test $? -eq 0
else
  echo "  SKIP (npm not found)"
fi

step "5. shared-wiki MCP bundle is committed and matches src"
# The plugin cache has no install-time build step: the plugin's .mcp.json starts dist/index.js
# exactly as committed. A bundle left stale would ship src changes that never reach users.
# Relies on step 4 having just rebuilt it.
if [[ ! -f "$SCRIPT_DIR/mcp/shared-wiki/dist/index.js" ]]; then
  echo "  FAIL (no bundle; run 'npm run build' in mcp/shared-wiki and commit dist/index.js)"; fail=1
elif ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "  SKIP (not a git repo)"
elif [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- mcp/shared-wiki/dist)" ]]; then
  echo "  FAIL (bundle drifted from src; commit the rebuilt mcp/shared-wiki/dist/index.js)"; fail=1
else
  echo "  OK (bundle matches src)"
fi

step "6. Plugin loads with its full component inventory"
# The real acceptance surface: Claude Code must discover every skill/agent/hook/MCP from the
# plugin layout. A phantom agent (a generation source parked in agents/) or a skill that fails
# to parse shows up here as a wrong count.
if command -v claude >/dev/null 2>&1; then
  inventory="$(claude --plugin-dir "$SCRIPT_DIR" plugin details grill-adapter 2>&1 || true)"
  inv_fail=0
  for expected in "Skills (12)" "Agents (3)" "Hooks (4)" "MCP servers (1)"; do
    if ! grep -qF "$expected" <<<"$inventory"; then
      echo "  FAIL (expected '$expected' in plugin inventory)"; inv_fail=1
    fi
  done
  if [[ $inv_fail -eq 0 ]]; then echo "  OK (12 skills, 3 agents, 4 hooks, 1 MCP)"; else
    sed 's/^/    /' <<<"$inventory" | head -12; fail=1
  fi
else
  echo "  SKIP (claude CLI not found)"
fi

step "7. Sandbox project wiring + verify (throwaway project)"
SANDBOX_PROJECT="$(mktemp -d)"
trap 'rm -rf "$SANDBOX_PROJECT"' EXIT
if python3 "$SCRIPT_DIR/lib/install.py" install "$SANDBOX_PROJECT" --host grill >/tmp/grill-rc-install.$$.log 2>&1; then
  echo "  install OK"
else
  echo "  install FAIL"; sed 's/^/    /' /tmp/grill-rc-install.$$.log | tail -20; fail=1
fi
check python3 "$SCRIPT_DIR/lib/install.py" verify "$SANDBOX_PROJECT" --host grill
rm -f /tmp/grill-rc-install.$$.log

step "8. Smoke/regression suite"
if bash "$SCRIPT_DIR/self-test.sh" "$SANDBOX_PROJECT"; then echo "  OK"; else echo "  FAIL"; fail=1; fi

step "9. doctor on the passed project (read-only)"
bash "$SCRIPT_DIR/doctor.sh" "$PROJECT_ROOT" || true

echo ""
if [[ $fail -eq 0 ]]; then
  echo "release-check: PASS"
else
  echo "release-check: FAIL"; exit 1
fi
