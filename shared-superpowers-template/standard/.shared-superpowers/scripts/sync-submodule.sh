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

if [[ -z "$PATH_ARG" || "$PATH_ARG" == "/" || "$PATH_ARG" == "." ]]; then
  printf 'Invalid --path: %s\n' "$PATH_ARG" >&2
  usage
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TARGET_PATH="$PATH_ARG"
if [[ "$TARGET_PATH" != /* ]]; then
  TARGET_PATH="$PROJECT_ROOT/$TARGET_PATH"
fi
if [[ ! -d "$TARGET_PATH" ]]; then
  printf 'Submodule path does not exist: %s\n' "$PATH_ARG" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
TARGET_PATH="$(cd "$TARGET_PATH" && pwd)"

case "$TARGET_PATH" in
  "$PROJECT_ROOT"/*) ;;
  *) printf 'Path must stay inside project root: %s\n' "$PATH_ARG" >&2; exit 1 ;;
esac
if ! git -C "$TARGET_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Path is not an initialized git repository or submodule: %s\n' "$PATH_ARG" >&2
  exit 1
fi

if [[ -n "$(git -C "$TARGET_PATH" status --porcelain)" ]]; then
  printf 'Refusing to sync with uncommitted changes in %s\n' "$PATH_ARG" >&2
  exit 1
fi

if git -C "$PROJECT_ROOT" config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}' | grep -Fxq "$PATH_ARG"; then
  if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain -- "$PATH_ARG")" ]]; then
    printf 'Refusing to sync while parent repo has pending submodule pointer changes: %s\n' "$PATH_ARG" >&2
    exit 1
  fi
  git -c protocol.file.allow=always -C "$PROJECT_ROOT" submodule update --init --remote -- "$PATH_ARG"
  printf 'Synced submodule %s\n' "$PATH_ARG"
  exit 0
fi

remote_name="$REMOTE"
if [[ -z "$remote_name" ]]; then
  remote_name="$(git -C "$TARGET_PATH" remote 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$remote_name" ]]; then
  printf 'No git remote configured for %s\n' "$PATH_ARG" >&2
  exit 1
fi

git -C "$TARGET_PATH" fetch "$remote_name"
current_branch="$BRANCH"
if [[ -z "$current_branch" ]]; then
  current_branch="$(git -C "$TARGET_PATH" branch --show-current)"
fi
if [[ -z "$current_branch" ]]; then
  printf 'Cannot determine branch for %s\n' "$PATH_ARG" >&2
  exit 1
fi

upstream="$(git -C "$TARGET_PATH" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -n "$BRANCH" ]]; then
  upstream="$remote_name/$BRANCH"
elif [[ -z "$upstream" ]]; then
  upstream="$remote_name/$current_branch"
fi

git -C "$TARGET_PATH" merge --ff-only "$upstream"
printf 'Synced repository %s to %s\n' "$PATH_ARG" "$upstream"
