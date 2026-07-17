#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-}"

usage() {
  local code="${1:-1}"
  cat >&2 <<EOF
grill-adapter — host-agnostic Claude Code adapter (wiki + Lanhu + source-truth)

grill-adapter ships as a Claude Code plugin: skills, agents, hooks and the shared-wiki MCP
all activate together via \`claude plugin install grill-adapter --scope project|user\`.
These commands only wire the one thing a plugin cannot touch — a project's CLAUDE.md.

Usage:
  $0 install <project-root> [--host grill|plain]    Write the host convention block into a project
  $0 uninstall <project-root>                        Strip the host convention block from a project
  $0 verify <project-root> [--host grill|plain]      Verify the project is wired
  $0 status [project-root]                           Report plugin + convention-block status
  $0 bootstrap-wiki <project-root> [--template name] [--wiki-root project|shared]
  $0 init-wiki <project-root> [analysis-hint]        Emit project inventory for agent-led wiki init
  $0 export-wiki-skills <wiki-repo-root> [--no-graph-ci]
  $0 doctor <project-root>                            Diagnose install + shared-wiki binding for a project
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
    exec "$SCRIPT_DIR/bootstrap-wiki.sh" "$@"
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
    exec "$SCRIPT_DIR/doctor.sh" "$@"
    ;;
  self-test)
    exec "$SCRIPT_DIR/self-test.sh" "$@"
    ;;
  release-check)
    require_project_root "${1:-}"
    exec "$SCRIPT_DIR/release-check.sh" "$@"
    ;;
  help|-h|--help)
    usage 0
    ;;
  *)
    printf 'Unknown command: %s\n\n' "$COMMAND" >&2
    usage 1
    ;;
esac
