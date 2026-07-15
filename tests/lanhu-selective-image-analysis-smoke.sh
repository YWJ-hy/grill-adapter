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
    printf 'Expected installed Lanhu selective image analysis target: %s\n' "$file" >&2
    exit 1
  fi
done

require_in_file() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    printf 'Expected %s to contain Lanhu selective image analysis text: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

for agent in "$LANHU_FRONTEND_AGENT" "$LANHU_BACKEND_AGENT"; do
  for required in \
    'Selective image analysis policy' \
    'designInfo.images' \
    'candidate evidence only' \
    'Do not parse every image resource returned by Lanhu' \
    'direct analysis' \
    'structured source facts' \
    'persistedImages: false' \
    'persistedImageFiles: []' \
    'unresolvedImageQuestions: []' \
    'lanhu_get_prd_scoped_evidence' \
    'output_mode: evidence_only' \
    'must not broaden the allowed Lanhu MCP tool set' \
    'Do not save Lanhu image files' \
    '.lanhu/.../assets/' \
    '.lanhu/.../images/' \
    'raw OCR dumps' \
    'exhaustive image inventories'
  do
    require_in_file "$agent" "$required"
  done
done

for required in \
  '图片、截图和 `designInfo.images` 只在具备范围信号时选择性分析' \
  '默认不保存蓝湖图片' \
  'frontend-prd/design/assets/' \
  '图片资源是候选证据'
do
  require_in_file "$LANHU_FRONTEND_AGENT" "$required"
done

for required in \
  'selective image analysis policy' \
  'broad Lanhu design tools' \
  'selectiveImageAnalysis' \
  'persistedImages: false' \
  'Image files, base64 blobs, remote image references' \
  'frontend-prd/design/assets/' \
  'explicit user request or confirmed offline-audit/demo-support need'
do
  require_in_file "$LANHU_SKILL" "$required"
done



printf 'Lanhu selective image analysis smoke OK\n'
