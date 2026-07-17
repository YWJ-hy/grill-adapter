#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${2:-$(mktemp -d)}"

"${ROOT}/bootstrap-wiki.sh" "${PROJECT_ROOT}" --template standard > /dev/null

if [[ ! -f "${PROJECT_ROOT}/.adapter/wiki/index.md" ]]; then
  printf 'Expected imported index.md\n' >&2
  exit 1
fi
if [[ -d "${PROJECT_ROOT}/.adapter/wiki/categories" ]]; then
  printf 'Expected template import without categories wrapper\n' >&2
  exit 1
fi
if [[ ! -f "${PROJECT_ROOT}/.adapter/wiki/guides/skills.md" ]]; then
  printf 'Expected imported guides/skills.md discovery catalog\n' >&2
  exit 1
fi
if ! grep -Fq '`skills.md`' "${PROJECT_ROOT}/.adapter/wiki/guides/index.md"; then
  printf 'Expected guides/index.md to reference skills.md\n' >&2
  exit 1
fi

"${ROOT}/bootstrap-wiki.sh" "${PROJECT_ROOT}" --template standard --wiki-root shared > /dev/null
if [[ ! -f "${PROJECT_ROOT}/.shared-adapter/wiki/index.md" ]]; then
  printf 'Expected shared imported index.md\n' >&2
  exit 1
fi
if ! grep -Fq '"sharedNeutrality"' "${PROJECT_ROOT}/.shared-adapter/settings.json"; then
  printf 'Expected shared settings to include sharedNeutrality guard config\n' >&2
  exit 1
fi

printf '# User Index\n\nDo not overwrite.\n' > "${PROJECT_ROOT}/.adapter/wiki/index.md"
if "${ROOT}/bootstrap-wiki.sh" "${PROJECT_ROOT}" --template standard > /dev/null 2>&1; then
  printf 'Expected bootstrap conflict to fail\n' >&2
  exit 1
fi
if ! grep -q 'Do not overwrite' "${PROJECT_ROOT}/.adapter/wiki/index.md"; then
  printf 'Expected bootstrap to preserve conflicting user file\n' >&2
  exit 1
fi

printf 'bootstrap-wiki template import test complete\n'
