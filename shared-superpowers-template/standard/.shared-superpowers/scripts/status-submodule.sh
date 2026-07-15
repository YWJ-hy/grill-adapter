#!/usr/bin/env bash
set -euo pipefail

PATH_ARG=""

usage() {
  printf 'Usage: %s --path <path>\n' "$0" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      PATH_ARG="${2:-}"
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
  printf 'status: missing\npath: %s\n' "$PATH_ARG"
  exit 0
fi
if ! git -C "$PATH_ARG" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'status: not-git\npath: %s\n' "$PATH_ARG"
  exit 0
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
kind="repository"
if git -C "$PROJECT_ROOT" config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}' | grep -Fxq "$PATH_ARG"; then
  kind="submodule"
fi
branch="$(git -C "$PATH_ARG" branch --show-current || true)"
head="$(git -C "$PATH_ARG" rev-parse --short HEAD)"
remote="$(git -C "$PATH_ARG" remote 2>/dev/null | head -n 1 || true)"

printf 'status: %s\n' "$kind"
printf 'path: %s\n' "$PATH_ARG"
printf 'branch: %s\n' "${branch:-detached}"
printf 'head: %s\n' "$head"
if [[ -n "$remote" ]]; then
  printf 'remote: %s\n' "$remote"
fi
git -C "$PATH_ARG" status --short
