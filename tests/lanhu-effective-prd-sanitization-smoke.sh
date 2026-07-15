#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
TARGET_INPUT="$(cd "${TARGET_INPUT}" && pwd)"

LANHU_FRONTEND_AGENT="${TARGET_INPUT}/agents/lanhu-frontend-requirements-analyst.md"
LANHU_BACKEND_AGENT="${TARGET_INPUT}/agents/lanhu-backend-requirements-analyst.md"
LANHU_SKILL="${TARGET_INPUT}/skills/lanhu-requirements/SKILL.md"

for file in "$LANHU_FRONTEND_AGENT" "$LANHU_BACKEND_AGENT" "$LANHU_SKILL"; do
  if [[ ! -f "$file" ]]; then
    printf 'Expected installed Lanhu effective PRD sanitization target: %s\n' "$file" >&2
    exit 1
  fi
done

require_in_file() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    printf 'Expected %s to contain Lanhu effective PRD sanitization text: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

# Both generated role analysts inherit the clean effective PRD rule from the
# shared skeleton and embed the role templates that forbid process/history
# traces from user corrections, exclusions, confirmations, and resolved conflicts.
for agent in "$LANHU_FRONTEND_AGENT" "$LANHU_BACKEND_AGENT"; do
  for required in \
    'clean effective requirements' \
    'effective source facts' \
    'Rejected, superseded, ignored, deleted, out-of-scope' \
    'sourceFactsDroppedDetected: []` applies to effective source facts only' \
    'correction log, confirmation log, exclusion audit, or conflict-resolution transcript' \
    'templateCompliance.forbiddenContentDetected' \
    '已确认口径' \
    '已剔除' \
    '不采用' \
    '另一套口径不采用' \
    '用户要求删除' \
    '按明确口径'
  do
    require_in_file "$agent" "$required"
  done
done

# The frontend and backend embedded templates also carry role-specific wording
# so final prd.md / HTML / backend markdown outputs stay clean.
for required in \
  '只保留有效源事实' \
  '最终产物不得出现过程性措辞' \
  '用户确认排除、替代、删除、忽略或判定无效的来源内容不按丢失源事实处理'
do
  require_in_file "$LANHU_FRONTEND_AGENT" "$required"
done

for required in \
  '明确有效内容' \
  '每条明确蓝湖有效原始需求事实' \
  '最终正文不得出现过程性措辞'
do
  require_in_file "$LANHU_BACKEND_AGENT" "$required"
done

# The skill keeps the main session lightweight while requiring analyst-owned
# sanitization and compact metadata gates.
for required in \
  'The role analyst owns final artifact sanitization' \
  'Effective source facts are source facts that remain authoritative' \
  'sourceFactsDroppedDetected: []` for effective source facts only' \
  'Final package artifacts were clean effective requirements' \
  'not retained as process/history trace'
do
  require_in_file "$LANHU_SKILL" "$required"
done

printf 'Lanhu effective PRD sanitization smoke OK\n'
