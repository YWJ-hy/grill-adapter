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
    printf 'Expected installed Lanhu contradiction detection target: %s\n' "$file" >&2
    exit 1
  fi
done

require_in_file() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    printf 'Expected %s to contain Lanhu contradiction detection text: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

# Both generated role analysts inherit the contradiction-handling rule from the
# shared skeleton: surface source-internal factual conflicts via the existing
# confirmation gate, never resolve/merge them, and keep them distinct from the
# Lanhu-returned 遗漏/矛盾检查 label.
for agent in "$LANHU_FRONTEND_AGENT" "$LANHU_BACKEND_AGENT"; do
  for required in \
    'source-fact-conflict' \
    'Do not silently pick one side, merge the two' \
    'opportunistic over the evidence you already read' \
    'must never become a package heading' \
    '遗漏/矛盾检查'
  do
    require_in_file "$agent" "$required"
  done
done

# The skill surfaces contradictions through confirmationGate, distinguishes them
# from the Lanhu label, and gates Superpowers via its completion checklist.
for required in \
  'impact: source-fact-conflict' \
  'is never copied from or labeled as the Lanhu' \
  'not written as a 矛盾分析 heading'
do
  require_in_file "$LANHU_SKILL" "$required"
done

printf 'Lanhu contradiction detection smoke OK\n'
