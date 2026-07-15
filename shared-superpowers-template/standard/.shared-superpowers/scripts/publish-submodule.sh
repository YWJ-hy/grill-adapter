#!/usr/bin/env bash
set -euo pipefail

PATH_ARG=""
REMOTE="origin"
BRANCH=""
MESSAGE="docs: update shared wiki"
PARENT_MESSAGE="chore: update shared wiki submodule"

usage() {
  printf 'Usage: %s --path <path> [--remote <remote>] [--branch <branch>] [--message <message>] [--parent-message <message>]\n' "$0" >&2
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
    --message)
      MESSAGE="${2:-}"
      shift 2
      ;;
    --parent-message)
      PARENT_MESSAGE="${2:-}"
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

other_parent_changes="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all | grep -vE "^.. ${PATH_ARG}($|/)" || true)"
if [[ -n "$other_parent_changes" ]]; then
  printf 'Refusing to publish with unrelated parent repository changes:\n%s\n' "$other_parent_changes" >&2
  exit 1
fi

if [[ -n "$(git -C "$TARGET_PATH" status --porcelain)" ]]; then
  git -C "$TARGET_PATH" add -A
  if ! git -C "$TARGET_PATH" diff --cached --quiet; then
    git -C "$TARGET_PATH" commit -m "$MESSAGE"
  fi
fi

if [[ -n "$BRANCH" ]]; then
  git -C "$TARGET_PATH" push "$REMOTE" "$BRANCH"
else
  current_branch="$(git -C "$TARGET_PATH" branch --show-current)"
  if [[ -z "$current_branch" ]]; then
    printf 'Cannot determine branch for %s\n' "$PATH_ARG" >&2
    exit 1
  fi
  git -C "$TARGET_PATH" push "$REMOTE" "$current_branch"
fi

parent_status_before="$(git -C "$PROJECT_ROOT" status --porcelain -- "$PATH_ARG")"
git -C "$PROJECT_ROOT" add "$PATH_ARG"
if ! git -C "$PROJECT_ROOT" diff --cached --quiet -- "$PATH_ARG"; then
  git -C "$PROJECT_ROOT" commit -m "$PARENT_MESSAGE"
fi
parent_status_after="$(git -C "$PROJECT_ROOT" status --porcelain -- "$PATH_ARG")"
if [[ -n "$parent_status_before" && -n "$parent_status_after" ]]; then
  printf 'Warning: parent submodule path still shows changes after publish: %s\n' "$PATH_ARG" >&2
fi
printf 'Published submodule %s\n' "$PATH_ARG"
