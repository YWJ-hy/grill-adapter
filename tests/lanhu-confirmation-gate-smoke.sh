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
    printf 'Expected installed Lanhu confirmation gate target: %s\n' "$file" >&2
    exit 1
  fi
done

require_in_file() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    printf 'Expected %s to contain Lanhu confirmation gate text: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

for agent in "$LANHU_FRONTEND_AGENT" "$LANHU_BACKEND_AGENT"; do
  for required in \
    'status: need_confirmation' \
    'confirmationGate' \
    'blockingQuestions' \
    'blockingQuestionCount' \
    'resolutionMode' \
    'resolve_confirmation' \
    'confirmationAnswers' \
    'Blocking confirmation classification' \
    'scopeConfirmationSummary' \
    'requirementScopeJudgment' \
    'raw Lanhu tool-result text' \
    'full PRD markdown' \
    'full HTML' \
    'blocking item must also appear in `confirmationGate.blockingQuestions`' \
    'If a user modification may affect already-analyzed' \
    'outputPreference' \
    'packageKind' \
    'Missing implementation field names' \
    'User supplements, corrections, deletions, ignore instructions' \
    'image relevance' \
    'selectiveImageAnalysis' \
    'Compact metadata is not an evidence source'
  do
    require_in_file "$agent" "$required"
  done
done

for required in \
  'status: need_confirmation' \
  'confirmationGate' \
  'blockingQuestions' \
  'blockingQuestionCount' \
  'resolutionMode: resolve_confirmation' \
  'confirmationAnswers' \
  'compact confirmation gate' \
  'confirmationGate.status: clear' \
  'main session must not override `confirmationGate` directly' \
  'lanhu.role' \
  'outputPreference' \
  'packageKind' \
  'Missing implementation field names' \
  'User supplements, corrections, deletions, ignore instructions'
do
  require_in_file "$LANHU_SKILL" "$required"
done




printf 'Lanhu confirmation gate smoke OK\n'
