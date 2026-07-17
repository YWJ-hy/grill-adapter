#!/usr/bin/env bash
set -euo pipefail

PATH_ARG=""
REMOTE=""
BRANCH=""

usage() {
  printf 'Usage: %s --path <path> [--remote <remote>] [--branch <branch>]\n' "$0" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      PATH_ARG="${2:-}"
      shift 2
      ;;
    --remote)
      REMOTE="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

if [[ -z "$PATH_ARG" ]]; then
  usage
fi

if [[ ! -d "$PATH_ARG" ]]; then
  printf 'Path does not exist: %s\n' "$PATH_ARG" >&2
  exit 1
fi
if ! git -C "$PATH_ARG" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Path is not a git repository or submodule: %s\n' "$PATH_ARG" >&2
  exit 1
fi

if [[ -n "$REMOTE" ]]; then
  if ! git -C "$PATH_ARG" remote | grep -Fxq "$REMOTE"; then
    printf 'Remote not found for %s: %s\n' "$PATH_ARG" "$REMOTE" >&2
    exit 1
  fi
fi

if [[ -n "$BRANCH" ]]; then
  current_branch="$(git -C "$PATH_ARG" branch --show-current)"
  if [[ "$current_branch" != "$BRANCH" ]]; then
    printf 'Expected branch %s for %s, got %s\n' "$BRANCH" "$PATH_ARG" "${current_branch:-detached}" >&2
    exit 1
  fi
fi

printf 'Submodule/repository OK: %s\n' "$PATH_ARG"
