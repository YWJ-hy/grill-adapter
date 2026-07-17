#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
PROJECT_ROOT="${2:-${ROOT}/..}"
TMP_PROJECT="$(mktemp -d)"
trap 'rm -rf "${TMP_PROJECT}"' EXIT

json_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/wiki_update_check.py" --wiki-root all --json)"
python3 - <<'PY' "${json_output}"
import json, sys
payload = json.loads(sys.argv[1])
if payload.get('status') not in {'valid', 'warning', 'invalid'}:
    raise SystemExit(f"Unexpected status: {payload.get('status')}")
for key in ['filesChecked', 'warnings', 'errors', 'roots', 'mechanicalOnly']:
    if key not in payload:
        raise SystemExit(f"Missing key: {key}")
if 'oversizedPages' in payload:
    raise SystemExit('Unexpected oversizedPages key after size-threshold removal')
if payload.get('mechanicalOnly') is not True:
    raise SystemExit('Expected mechanicalOnly=true')
for forbidden in ['nextSteps', 'signals']:
    if forbidden in payload:
        raise SystemExit(f"Unexpected semantic recommendation key: {forbidden}")
PY

text_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/wiki_update_check.py" --summary "normalize api error contract" --changed-file "src/api/error_handler.py")"
case "${text_output}" in
  *"WIKI_UPDATE_CHECK_"* ) : ;;
  *) printf 'Expected mechanical status output from wiki_update_check\n' >&2; exit 1 ;;
esac
python3 - <<'PY' "${text_output}"
import sys
text = sys.argv[1]
for forbidden in ['nextSteps', 'signals', 'one-shot update runner']:
    if forbidden in text:
        raise SystemExit(f'Unexpected semantic recommendation output: {forbidden}')
PY

mkdir -p "${TMP_PROJECT}/.adapter/wiki"
python3 - <<'PY' "${TMP_PROJECT}/.adapter/wiki"
from pathlib import Path
import sys
wiki = Path(sys.argv[1])
(wiki / 'index.md').write_text('# Wiki\n\n<!-- adapter:auto-index:start -->\n- `large.md`\n<!-- adapter:auto-index:end -->\n', encoding='utf-8')
body = '# Large Page\n\n' + '\n'.join(f'- durable rule {i}' for i in range(260)) + '\n'
(wiki / 'large.md').write_text(body, encoding='utf-8')
PY
large_json="$(cd "${TMP_PROJECT}" && python3 "${TARGET_INPUT}/scripts/wiki_update_check.py" --json)"
python3 - <<'PY' "${large_json}"
import json, sys
payload = json.loads(sys.argv[1])
if 'oversizedPages' in payload:
    raise SystemExit('Unexpected oversizedPages entry after size-threshold removal')
if any('Oversized indexed wiki page' in warning for warning in payload.get('warnings', [])):
    raise SystemExit('Unexpected oversized warning after size-threshold removal')
if payload.get('status') != 'warning':
    raise SystemExit(f"Expected warning status for missing section markers, got {payload.get('status')}")
if not any('Leaf page over 100 lines without section markers' in warning for warning in payload.get('warnings', [])):
    raise SystemExit('Expected structural marker warning for long unmarked leaf page')
for forbidden in ['nextSteps', 'signals']:
    if forbidden in payload:
        raise SystemExit(f"Unexpected semantic recommendation key: {forbidden}")
PY
large_text="$(cd "${TMP_PROJECT}" && python3 "${TARGET_INPUT}/scripts/wiki_update_check.py")"
case "${large_text}" in
  *"Oversized pages:"* ) printf 'Unexpected oversized pages section from wiki_update_check\n' >&2; exit 1 ;;
esac

candidate_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/wiki_select_target.py" --wiki-root all --json)"
python3 - <<'PY' "${candidate_output}"
import json, sys
payload = json.loads(sys.argv[1])
if payload.get('decisionMade') is not False:
    raise SystemExit('Expected candidate listing to make no target decision')
if 'candidates' not in payload:
    raise SystemExit('Expected candidates list')
for candidate in payload.get('candidates', []):
    for key in ['root', 'wikiRoot', 'relativePath']:
        if key not in candidate:
            raise SystemExit(f'Missing candidate key: {key}')
PY

printf 'wiki-update-check smoke test complete\n'
