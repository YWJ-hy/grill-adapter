#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
PROJECT_ROOT="${2:-${ROOT}/..}"

before="$(cd "${PROJECT_ROOT}" && { find .superpowers/wiki .shared-superpowers/wiki -type f -name '*.md' -print0 2>/dev/null || true; } | xargs -0 shasum 2>/dev/null || true)"
json_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/init-wiki.py" . "self-test" --json)"
after="$(cd "${PROJECT_ROOT}" && { find .superpowers/wiki .shared-superpowers/wiki -type f -name '*.md' -print0 2>/dev/null || true; } | xargs -0 shasum 2>/dev/null || true)"

python3 - <<'PY' "${json_output}"
import json, sys
payload = json.loads(sys.argv[1])
for key in ['projectRoot', 'wikiRoot', 'wikiRoots', 'focusHint', 'languages', 'stackSignals', 'topDirectories', 'sampleFiles', 'indexedWikiPages', 'warnings', 'mechanicalOnly']:
    if key not in payload:
        raise SystemExit(f"Missing key: {key}")
if payload.get('mechanicalOnly') is not True:
    raise SystemExit('Expected mechanicalOnly=true')
if payload.get('focusHint') != 'self-test':
    raise SystemExit(f"Expected focus hint to round-trip, got {payload.get('focusHint')}")
if not isinstance(payload.get('indexedWikiPages'), list):
    raise SystemExit('Expected indexedWikiPages list')
PY

if [[ "${before}" != "${after}" ]]; then
  printf 'init-wiki inventory must not modify wiki markdown files\n' >&2
  exit 1
fi

text_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/init-wiki.py" . "self-test")"
case "${text_output}" in
  *"Project inventory only; no wiki content was written."* ) : ;;
  *) printf 'Expected inventory-only text output\n' >&2; exit 1 ;;
esac

printf 'init-wiki inventory smoke test complete\n'
