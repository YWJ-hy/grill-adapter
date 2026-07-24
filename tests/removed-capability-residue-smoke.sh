#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
TEXT_TERM='lan''hu'
CN_TERM=$'\u84dd\u6e56'

TRACKED_FILES=()
while IFS= read -r relative; do
  TRACKED_FILES+=("$relative")
done < <(git -C "$ROOT" ls-files)
fail=0
for relative in "${TRACKED_FILES[@]}"; do
  file="$ROOT/$relative"
  [[ -f "$file" ]] || continue
  if grep -Ini --binary-files=without-match -e "$TEXT_TERM" -e "$CN_TERM" "$file"; then
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  printf 'FAIL: removed capability residue remains in tracked product surfaces\n' >&2
  exit 1
fi

printf 'removed capability residue smoke OK\n'
