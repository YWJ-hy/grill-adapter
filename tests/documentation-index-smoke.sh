#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

python3 "$ROOT/scripts/check_documentation_index.py" "$ROOT" --check
python3 "$ROOT/scripts/docs_context_budget.py" --root "$ROOT" --all >/dev/null

grep -qF '变更类型' "$ROOT/docs/DEVELOPMENT_CN.md"
grep -qF 'Codex installed acceptance' "$ROOT/docs/DOCUMENTATION_INDEX_CN.md"
grep -qF '非当前权威' "$ROOT/docs/BUILD_PLAN_CN.md"
grep -qF 'SUPERSEDED' "$ROOT/docs/DECISIONS_CN.md"
! grep -qF '## 附录 · plugin 组件一览' "$ROOT/docs/USER_FLOW_CN.md"

printf 'documentation index smoke OK\n'
