#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
TARGET_DIR="$(cd "${TARGET_INPUT}" && pwd)"
TMP_PARENT="${CLAUDE_JOB_DIR:-${TMPDIR:-/tmp}}"
PROJECT_ROOT="$(mktemp -d "${TMP_PARENT%/}/lanhu-unified-settings.XXXXXX")"
trap 'rm -rf "${PROJECT_ROOT}"' EXIT

mkdir -p "${PROJECT_ROOT}/.adapter"

assert_json_field() {
  local file="$1"
  local expression="$2"
  python3 - "$file" "$expression" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expression = sys.argv[2]
if not eval(expression, {"payload": payload}):
    raise SystemExit(f"Assertion failed: {expression}; payload={payload!r}")
PY
}

python3 "${TARGET_DIR}/scripts/lanhu_settings.py" frontend "${PROJECT_ROOT}" > "${PROJECT_ROOT}/default-frontend.json"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['role'] == 'frontend'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['configuredRole'] is None"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['roleSource'] == 'argument'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['packageKind'] == 'frontend_unified'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['settingsPath'] is None"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['primaryOutput']['kind'] == 'frontend_role_prd'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['primaryOutput']['filename'] == 'frontend-prd/prd.md'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['frontendPackage']['enabled'] is True"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['frontendPackage']['designDemoPath'] == 'frontend-prd/design/index.html'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['frontendPackage']['assetsDir'] == 'frontend-prd/design/assets/'"
assert_json_field "${PROJECT_ROOT}/default-frontend.json" "payload['deprecatedSettings']['ignored'] is False"

python3 - "${PROJECT_ROOT}/.adapter/settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(json.dumps({
    "lanhu": {
        "role": "frontend",
        "frontend": {
            "output": {
                "format": "html"
            }
        }
    }
}, indent=2) + "\n", encoding="utf-8")
PY

python3 "${TARGET_DIR}/scripts/lanhu_settings.py" frontend "${PROJECT_ROOT}" > "${PROJECT_ROOT}/legacy-html-frontend.json"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['role'] == 'frontend'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['configuredRole'] == 'frontend'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['roleSource'] == 'argument'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['packageKind'] == 'frontend_unified'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['primaryOutput']['kind'] == 'frontend_role_prd'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['primaryOutput']['filename'] == 'frontend-prd/prd.md'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['deprecatedSettings']['lanhu.frontend.output.format'] == 'html'"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "payload['deprecatedSettings']['ignored'] is True"
assert_json_field "${PROJECT_ROOT}/legacy-html-frontend.json" "'deprecated and ignored' in payload['warnings'][0]"

python3 "${TARGET_DIR}/scripts/lanhu_settings.py" "${PROJECT_ROOT}" > "${PROJECT_ROOT}/configured-role.json"
assert_json_field "${PROJECT_ROOT}/configured-role.json" "payload['role'] == 'frontend'"
assert_json_field "${PROJECT_ROOT}/configured-role.json" "payload['configuredRole'] == 'frontend'"
assert_json_field "${PROJECT_ROOT}/configured-role.json" "payload['roleSource'] == '.adapter/settings.json'"
assert_json_field "${PROJECT_ROOT}/configured-role.json" "payload['packageKind'] == 'frontend_unified'"

python3 "${TARGET_DIR}/scripts/lanhu_settings.py" backend "${PROJECT_ROOT}" > "${PROJECT_ROOT}/backend.json"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['role'] == 'backend'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['configuredRole'] == 'frontend'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['roleSource'] == 'argument'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['packageKind'] == 'backend_markdown'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['primaryOutput']['kind'] == 'backend_markdown_prd'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['primaryOutput']['filename'] == 'backend-prd/prd.md'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['backendPackage']['primaryPath'] == 'backend-prd/prd.md'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['backendPackage']['splitDir'] == 'backend-prd/prds/'"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['backendPackage']['markdownOnly'] is True"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['frontendPackage']['enabled'] is False"
assert_json_field "${PROJECT_ROOT}/backend.json" "payload['deprecatedSettings']['ignored'] is True"

python3 - "${PROJECT_ROOT}/.adapter/settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(json.dumps({
    "lanhu": {
        "role": "frontend",
        "frontend": {
            "output": {
                "format": "markdown+html"
            }
        }
    }
}, indent=2) + "\n", encoding="utf-8")
PY
python3 "${TARGET_DIR}/scripts/lanhu_settings.py" frontend "${PROJECT_ROOT}" > "${PROJECT_ROOT}/unsupported-legacy-format.json"
assert_json_field "${PROJECT_ROOT}/unsupported-legacy-format.json" "payload['packageKind'] == 'frontend_unified'"
assert_json_field "${PROJECT_ROOT}/unsupported-legacy-format.json" "payload['deprecatedSettings']['lanhu.frontend.output.format'] == 'markdown+html'"
assert_json_field "${PROJECT_ROOT}/unsupported-legacy-format.json" "'unsupported legacy value' in payload['warnings'][0]"

python3 - "${PROJECT_ROOT}/.adapter/settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(json.dumps({
    "lanhu": {
        "role": "fullstack"
    }
}, indent=2) + "\n", encoding="utf-8")
PY
if python3 "${TARGET_DIR}/scripts/lanhu_settings.py" "${PROJECT_ROOT}" > "${PROJECT_ROOT}/invalid-role.out" 2>&1; then
  printf 'Expected invalid lanhu.role to fail\n' >&2
  exit 1
fi
if ! grep -Fq 'Invalid lanhu.role' "${PROJECT_ROOT}/invalid-role.out"; then
  printf 'Expected invalid role error message\n' >&2
  exit 1
fi

printf '{ invalid json' > "${PROJECT_ROOT}/.adapter/settings.json"
if python3 "${TARGET_DIR}/scripts/lanhu_settings.py" frontend "${PROJECT_ROOT}" > "${PROJECT_ROOT}/malformed.out" 2>&1; then
  printf 'Expected malformed settings JSON to fail\n' >&2
  exit 1
fi
if ! grep -Fq 'Invalid JSON' "${PROJECT_ROOT}/malformed.out"; then
  printf 'Expected malformed JSON error message\n' >&2
  exit 1
fi

printf 'Lanhu unified frontend settings smoke OK\n'
