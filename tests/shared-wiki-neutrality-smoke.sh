#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(mktemp -d)"
SCRIPTS_DIR="${ROOT}/scripts"

mkdir -p "${PROJECT_ROOT}/.adapter/wiki" "${PROJECT_ROOT}/.shared-adapter/wiki"
cat > "${PROJECT_ROOT}/.adapter/wiki/index.md" <<'EOF'
# Project Wiki

<!-- grill-adapter:auto:start -->
<!-- grill-adapter:auto:end -->
EOF
cat > "${PROJECT_ROOT}/.shared-adapter/wiki/index.md" <<'EOF'
# Shared Wiki

<!-- grill-adapter:auto:start -->
<!-- grill-adapter:auto:end -->
EOF
cat > "${PROJECT_ROOT}/.shared-adapter/settings.json" <<'EOF'
{
  "wiki": {
    "updateAuthorization": {
      "updateExistingPage": "skip",
      "createNewDocument": "skip"
    },
    "sharedNeutrality": {
      "blockedTerms": ["FOO_SYSTEM"],
      "blockedPatterns": ["SYS-[0-9]+"]
    }
  }
}
EOF

if (cd "${PROJECT_ROOT}" && python3 "${SCRIPTS_DIR}/wiki_apply_update.py" --wiki-root shared shared/unsafe.md 'FOO_SYSTEM contract' 'from FOO_SYSTEM' 'SYS-123 rule') > /tmp/shared-neutrality-unsafe-update.out 2>&1; then
  printf 'Expected unsafe shared update to fail\n' >&2
  exit 1
fi
if [[ -e "${PROJECT_ROOT}/.shared-adapter/wiki/shared/unsafe.md" ]]; then
  printf 'Expected unsafe shared update not to create target file\n' >&2
  exit 1
fi
if grep -Fq 'shared/unsafe.md' "${PROJECT_ROOT}/.shared-adapter/wiki/index.md"; then
  printf 'Expected unsafe shared update not to modify index\n' >&2
  exit 1
fi
if ! grep -Fq 'neutral/portable' /tmp/shared-neutrality-unsafe-update.out; then
  printf 'Expected unsafe shared update error to mention neutral/portable content\n' >&2
  exit 1
fi

(cd "${PROJECT_ROOT}" && python3 "${SCRIPTS_DIR}/wiki_apply_update.py" --wiki-root project --authorized-create project/unsafe.md 'FOO_SYSTEM contract' 'from FOO_SYSTEM' 'SYS-123 rule') > /dev/null
if [[ ! -f "${PROJECT_ROOT}/.adapter/wiki/project/unsafe.md" ]]; then
  printf 'Expected project wiki update with system identifier to succeed\n' >&2
  exit 1
fi

(cd "${PROJECT_ROOT}" && python3 "${SCRIPTS_DIR}/wiki_apply_update.py" --wiki-root shared shared/safe.md 'Shared contract' 'Reusable across sibling systems' 'Use neutral provider terminology') > /dev/null
if [[ ! -f "${PROJECT_ROOT}/.shared-adapter/wiki/shared/safe.md" ]]; then
  printf 'Expected safe shared update to create target file\n' >&2
  exit 1
fi

SOURCE_DIR="${PROJECT_ROOT}/source-wiki"
mkdir -p "${SOURCE_DIR}"
printf '# Unsafe Import\n\nFOO_SYSTEM must do this.\n' > "${SOURCE_DIR}/unsafe.md"
if (cd "${PROJECT_ROOT}" && python3 "${SCRIPTS_DIR}/wiki_import.py" "${SOURCE_DIR}" --wiki-root shared --target imported --authorized-create) > /tmp/shared-neutrality-import.out 2>&1; then
  printf 'Expected unsafe shared import to fail\n' >&2
  exit 1
fi
if [[ -e "${PROJECT_ROOT}/.shared-adapter/wiki/imported/unsafe.md" ]]; then
  printf 'Expected unsafe shared import not to create target file\n' >&2
  exit 1
fi
if ! grep -Fq 'neutral/portable' /tmp/shared-neutrality-import.out; then
  printf 'Expected unsafe shared import error to mention neutral/portable content\n' >&2
  exit 1
fi

mkdir -p "${PROJECT_ROOT}/.shared-adapter/wiki/leaks"
cat > "${PROJECT_ROOT}/.shared-adapter/wiki/leaks/index.md" <<'EOF'
# Leaks

<!-- grill-adapter:auto:start -->
- `dirty.md`
<!-- grill-adapter:auto:end -->
EOF
cat > "${PROJECT_ROOT}/.shared-adapter/wiki/leaks/dirty.md" <<'EOF'
# Dirty Shared Page

FOO_SYSTEM should never leak into shared indexes.
EOF
python3 - "${PROJECT_ROOT}/.shared-adapter/wiki/index.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('<!-- grill-adapter:auto:start -->\n', '<!-- grill-adapter:auto:start -->\n- `leaks/`\n')
path.write_text(text)
PY
before_index="$(cat "${PROJECT_ROOT}/.shared-adapter/wiki/leaks/index.md")"
if (cd "${PROJECT_ROOT}" && python3 "${SCRIPTS_DIR}/update-wiki.py" --wiki-root shared --authorized-update) > /tmp/shared-neutrality-refresh.out 2>&1; then
  printf 'Expected shared index refresh with leaking summary to fail\n' >&2
  exit 1
fi
after_index="$(cat "${PROJECT_ROOT}/.shared-adapter/wiki/leaks/index.md")"
if [[ "${before_index}" != "${after_index}" ]]; then
  printf 'Expected failed shared index refresh not to write leaking index\n' >&2
  exit 1
fi

if (cd "${PROJECT_ROOT}" && python3 "${SCRIPTS_DIR}/wiki_update_check.py" --wiki-root shared) > /tmp/shared-neutrality-check.out 2>&1; then
  printf 'Expected shared validator to fail for dirty shared leaf\n' >&2
  exit 1
fi
if ! grep -Fq 'blocked term' /tmp/shared-neutrality-check.out; then
  printf 'Expected shared validator to report blocked term\n' >&2
  exit 1
fi

printf 'shared wiki neutrality smoke test complete\n'
