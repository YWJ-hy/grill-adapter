#!/usr/bin/env bash
# grill-adapter release-check — full pre-release gate. Non-destructive: installs into a
# throwaway sandbox home + a throwaway project, so the caller's real ~/.claude and the
# passed project are never mutated. The passed <project-root> is used read-only by doctor.
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
if grep -rn '__SUPERPOWER_ADAPTER' "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/skills" "$SCRIPT_DIR/agents" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/hooks" "$SCRIPT_DIR/contracts" 2>/dev/null; then
  echo "  FAIL (superpower-adapter placeholder residue)"; fail=1
else
  echo "  OK"
fi

step "4. shared-wiki MCP build + tests"
if command -v npm >/dev/null 2>&1; then
  ( cd "$SCRIPT_DIR/mcp/shared-wiki" && npm install --no-audit --no-fund >/dev/null 2>&1 && npm run build >/dev/null 2>&1 && npm test >/dev/null 2>&1 )
  check test $? -eq 0
else
  echo "  SKIP (npm not found)"
fi

step "5. Sandbox install + verify (throwaway home + project)"
SANDBOX="$(mktemp -d)"
SANDBOX_PROJECT="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$SANDBOX_PROJECT"' EXIT
export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
export GRILL_ADAPTER_HOME="$SANDBOX/.claude/grill-adapter"
if python3 "$SCRIPT_DIR/lib/install.py" install "$SANDBOX_PROJECT" --host grill >/tmp/grill-rc-install.$$.log 2>&1; then
  echo "  install OK"
else
  echo "  install FAIL"; sed 's/^/    /' /tmp/grill-rc-install.$$.log | tail -20; fail=1
fi
check python3 "$SCRIPT_DIR/lib/install.py" verify "$SANDBOX_PROJECT" --host grill
rm -f /tmp/grill-rc-install.$$.log
unset CLAUDE_CONFIG_DIR GRILL_ADAPTER_HOME

step "6. Smoke/regression suite"
if bash "$SCRIPT_DIR/self-test.sh" "$SANDBOX_PROJECT"; then echo "  OK"; else echo "  FAIL"; fail=1; fi

step "7. doctor on the passed project (read-only)"
bash "$SCRIPT_DIR/doctor.sh" "$PROJECT_ROOT" || true

echo ""
if [[ $fail -eq 0 ]]; then
  echo "release-check: PASS"
else
  echo "release-check: FAIL"; exit 1
fi
