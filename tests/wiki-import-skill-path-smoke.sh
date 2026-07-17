#!/usr/bin/env bash
set -euo pipefail

TARGET_INPUT="${1:-}"
PROJECT_ROOT="${2:-}"
if [[ -z "$TARGET_INPUT" || -z "$PROJECT_ROOT" ]]; then
  printf 'Usage: %s <installed-adapter-target> <project-root>\n' "$0" >&2
  exit 1
fi
TARGET_DIR="$(cd "$TARGET_INPUT" && pwd)"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

mkdir -p "$PROJECT_ROOT/.adapter/wiki" "$PROJECT_ROOT/.shared-adapter/wiki"

mkdir -p "$PROJECT_ROOT/wiki/source"
printf '# Imported Skill Path Smoke\n\nOriginal detail must be preserved.\n' > "$PROJECT_ROOT/wiki/source/path-smoke.md"

(cd "$PROJECT_ROOT" && python3 "$TARGET_DIR/scripts/wiki_import.py" wiki/source --hint "skill path smoke" --target imported-skill-path-smoke --merge-existing --authorized-create)

TARGET_FILE="$PROJECT_ROOT/.adapter/wiki/imported-skill-path-smoke/path-smoke.md"
if [[ ! -f "$TARGET_FILE" ]]; then
  printf 'Expected imported target file: %s\n' "$TARGET_FILE" >&2
  exit 1
fi
if ! grep -Fq 'Original detail must be preserved.' "$TARGET_FILE"; then
  printf 'Expected imported source content to be preserved\n' >&2
  exit 1
fi
if [[ ! -f "$PROJECT_ROOT/.adapter/wiki/imported-skill-path-smoke/index.md" ]]; then
  printf 'Expected imported subdirectory index to be refreshed\n' >&2
  exit 1
fi

mkdir -p "$PROJECT_ROOT/wiki/shared-source"
printf '# Shared Imported Skill Path Smoke\n\nShared detail must be preserved.\n' > "$PROJECT_ROOT/wiki/shared-source/shared-path-smoke.md"
(cd "$PROJECT_ROOT" && python3 "$TARGET_DIR/scripts/wiki_import.py" wiki/shared-source --wiki-root shared --target imported-skill-path-smoke --merge-existing --authorized-create)
SHARED_TARGET_FILE="$PROJECT_ROOT/.shared-adapter/wiki/imported-skill-path-smoke/shared-path-smoke.md"
if [[ ! -f "$SHARED_TARGET_FILE" ]]; then
  printf 'Expected shared imported target file: %s\n' "$SHARED_TARGET_FILE" >&2
  exit 1
fi
if ! grep -Fq 'Shared detail must be preserved.' "$SHARED_TARGET_FILE"; then
  printf 'Expected shared imported source content to be preserved\n' >&2
  exit 1
fi
if [[ ! -f "$PROJECT_ROOT/.shared-adapter/wiki/imported-skill-path-smoke/index.md" ]]; then
  printf 'Expected shared imported subdirectory index to be refreshed\n' >&2
  exit 1
fi
if [[ -e "$PROJECT_ROOT/.adapter/wiki/imported-skill-path-smoke/shared-path-smoke.md" ]]; then
  printf 'Expected shared import not to write into project wiki root\n' >&2
  exit 1
fi

printf 'wiki import skill path smoke complete\n'
