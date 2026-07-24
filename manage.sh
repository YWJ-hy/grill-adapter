#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="${GRILL_ADAPTER_BASH:-${BASH:-$(command -v bash)}}"
COMMAND="${1:-}"

usage() {
  local code="${1:-1}"
  cat >&2 <<EOF
grill-adapter — host-agnostic Claude Code/Codex adapter (wiki + source-truth + break-loop)

grill-adapter ships as a plugin bundle. These commands wire the one thing a plugin cannot
touch: a project's CLAUDE.md (Claude Code), AGENTS.md (Codex), or both.

Usage:
  $0 install <project-root> [--host grill|plain] [--runtime claude|codex|both]
  $0 uninstall <project-root> [--runtime claude|codex|both]
  $0 verify <project-root> [--host grill|plain] [--runtime claude|codex|both]
  $0 status [project-root] [--runtime claude|codex|both]
  $0 bootstrap-wiki <project-root> [--template name] [--wiki-root project|shared]  Legacy runtime only
  $0 init-wiki <project-root> [analysis-hint]        Emit project inventory for agent-led wiki init
  $0 export-wiki-skills <wiki-repo-root> [--no-graph-ci]
  $0 doctor <project-root>                            Diagnose active Wiki provider + adoption state
  $0 self-test [project-root]                         Run the smoke/regression suite
  $0 release-check <project-root>                     Full pre-release gate (install -> verify -> tests)
  $0 help
EOF
  exit "$code"
}

require_project_root() {
  if [[ -z "${1:-}" ]]; then
    printf 'Missing required project root.\n\n' >&2
    usage 1
  fi
}

[[ -z "$COMMAND" ]] && usage 1
shift || true

case "$COMMAND" in
  install|uninstall|verify|status)
    exec python3 "$SCRIPT_DIR/lib/install.py" "$COMMAND" "$@"
    ;;
  bootstrap-wiki)
    require_project_root "${1:-}"
    exec "$BASH_BIN" "$SCRIPT_DIR/bootstrap-wiki.sh" "$@"
    ;;
  init-wiki)
    require_project_root "${1:-}"
    exec python3 "$SCRIPT_DIR/scripts/init-wiki.py" "$@"
    ;;
  export-wiki-skills)
    require_project_root "${1:-}"
    exec python3 "$SCRIPT_DIR/lib/export_wiki_skills.py" "$SCRIPT_DIR" "$@"
    ;;
  migrate-wiki-sections)
    require_project_root "${1:-}"
    exec python3 "$SCRIPT_DIR/scripts/wiki_migrate_helper.py" "$@"
    ;;
  doctor)
    require_project_root "${1:-}"
    exec "$BASH_BIN" "$SCRIPT_DIR/doctor.sh" "$@"
    ;;
  self-test)
    exec "$BASH_BIN" "$SCRIPT_DIR/self-test.sh" "$@"
    ;;
  release-check)
    require_project_root "${1:-}"
    exec "$BASH_BIN" "$SCRIPT_DIR/release-check.sh" "$@"
    ;;
  help|-h|--help)
    usage 0
    ;;
  *)
    printf 'Unknown command: %s\n\n' "$COMMAND" >&2
    usage 1
    ;;
esac
