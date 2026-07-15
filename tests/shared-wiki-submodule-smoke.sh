#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PARENT_REPO="${TMP_ROOT}/parent"
SOURCE_REPO="${TMP_ROOT}/wiki-source"
REMOTE_REPO="${TMP_ROOT}/remote-wiki.git"
mkdir -p "${PARENT_REPO}" "${SOURCE_REPO}"

git init -q "${PARENT_REPO}"
git -C "${PARENT_REPO}" config user.name "Test User"
git -C "${PARENT_REPO}" config user.email "test@example.com"
mkdir -p "${PARENT_REPO}/.shared-superpowers/scripts"
cp -R "${ROOT}/shared-superpowers-template/standard/.shared-superpowers/scripts/." "${PARENT_REPO}/.shared-superpowers/scripts/"
cp "${ROOT}/shared-superpowers-template/standard/.shared-superpowers/settings.json" "${PARENT_REPO}/.shared-superpowers/settings.json"
chmod +x "${PARENT_REPO}/.shared-superpowers/scripts/"*.sh "${PARENT_REPO}/.shared-superpowers/scripts/"*.py

python3 - <<'PY' "${PARENT_REPO}/.shared-superpowers/settings.json"
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding='utf-8'))
if 'hooks' not in payload:
    raise SystemExit('missing hooks')
policy = payload.get('wiki', {}).get('updateAuthorization', {})
if policy.get('updateExistingPage') != 'skip':
    raise SystemExit('missing default updateExistingPage policy')
if policy.get('createNewDocument') != 'ask':
    raise SystemExit('missing default createNewDocument policy')
PY

git init -q "${SOURCE_REPO}"
git -C "${SOURCE_REPO}" config user.name "Test User"
git -C "${SOURCE_REPO}" config user.email "test@example.com"
printf '# Shared Wiki\n\nInitial content.\n' > "${SOURCE_REPO}/README.md"
printf '# Shared Wiki Index\n' > "${SOURCE_REPO}/index.md"
git -C "${SOURCE_REPO}" add README.md index.md
git -C "${SOURCE_REPO}" commit -q -m 'docs: seed shared wiki'
git clone -q --bare "${SOURCE_REPO}" "${REMOTE_REPO}"

git -C "${SOURCE_REPO}" remote add origin "${REMOTE_REPO}"
git -C "${SOURCE_REPO}" branch -M main
git -C "${SOURCE_REPO}" push -q -u origin main

git -C "${PARENT_REPO}" -c protocol.file.allow=always submodule add -q -b main "${REMOTE_REPO}" .shared-superpowers/wiki
git -C "${PARENT_REPO}" add .gitmodules .shared-superpowers/wiki .shared-superpowers/scripts .shared-superpowers/settings.json
git -C "${PARENT_REPO}" commit -q -m 'chore: add shared wiki submodule'

(cd "${PARENT_REPO}" && python3 ./.shared-superpowers/scripts/run-hook.py sharedWikiSubmodule:verify)
(cd "${PARENT_REPO}" && python3 ./.shared-superpowers/scripts/run-hook.py sharedWikiSubmodule:status)
(cd "${PARENT_REPO}" && python3 ./.shared-superpowers/scripts/run-hook.py sharedWikiSubmodule:sync)

printf 'more shared wiki\n' >> "${PARENT_REPO}/.shared-superpowers/wiki/README.md"
(cd "${PARENT_REPO}" && python3 ./.shared-superpowers/scripts/run-hook.py sharedWikiSubmodule:publish)

if ! git -C "${PARENT_REPO}" diff --quiet HEAD -- .shared-superpowers/wiki; then
  printf 'Expected parent repo submodule pointer to be clean after publish\n' >&2
  exit 1
fi
if ! grep -Fq 'more shared wiki' "${PARENT_REPO}/.shared-superpowers/wiki/README.md"; then
  printf 'Expected shared wiki content to remain after publish\n' >&2
  exit 1
fi
if ! git -C "${PARENT_REPO}/.shared-superpowers/wiki" log --oneline -1 | grep -Fq 'docs: update shared wiki'; then
  printf 'Expected shared wiki commit to be created by publish\n' >&2
  exit 1
fi

printf 'shared wiki submodule smoke test complete\n'
