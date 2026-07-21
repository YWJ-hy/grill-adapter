#!/usr/bin/env bash
set -euo pipefail

# Public Carry seam for the Obsidian runtime:
# research selection -> v6 sidecar scaffold -> one routing edit -> finalize/preflight.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPT="${TARGET_INPUT}/scripts/wiki_context_render.py"

if [[ ! -f "$SCRIPT" ]]; then
  printf 'Missing wiki context renderer: %s\n' "$SCRIPT" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROSTER="$TMP/feature.ticket-roster.json"
SELECTION="$TMP/feature.obsidian-wiki-selection.json"
CONTEXT="$TMP/new-project/.adapter/context/feature.wiki-context.json"

cat > "$ROSTER" <<'JSON'
{
  "featureSlug": "atomic-note-carry",
  "ticketSource": "manual",
  "tickets": [
    {"taskId": "T1", "taskTitle": "Carry atomic Notes", "text": "# T1\nCarry atomic Note constraints."},
    {"taskId": "T2", "taskTitle": "Bind Skill Cards", "text": "# T2\nBind reviewed Skill Cards."}
  ]
}
JSON

cat > "$SELECTION" <<'JSON'
{
  "status": "ok",
  "phase": "plan",
  "snapshotHash": "sha256:6240d8cadfd2df3df96ee005f0349145191b5b219b922c3c93aab9c7f2bd2e6e",
  "wikiBindings": [
    {
      "sourceId": "project-runtime",
      "role": "project",
      "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798"
    },
    {
      "sourceId": "shared-practices",
      "role": "shared",
      "bindingDigest": "bcf807e3d2a82a76c160c50c2d759d1a31c7da89c5a27f6c8b283f66849cf95c"
    }
  ],
  "wikiNotes": [
    {
      "sourceId": "project-runtime",
      "role": "project",
      "path": "Projects/example/Runtime/constraints.md",
      "wikiId": "project/runtime/constraints",
      "type": "constraint",
      "constraintStrength": "hard",
      "summary": "Runtime writes must preserve the established transaction boundary.",
      "contentHash": "sha256:ab31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
      "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798"
    },
    {
      "sourceId": "shared-practices",
      "role": "shared",
      "path": "Shared/Testing/coverage.md",
      "wikiId": "shared/testing/coverage",
      "type": "guide",
      "constraintStrength": "soft",
      "summary": "Cover durable behavior at the public workflow seam.",
      "contentHash": "sha256:c4c28d1189f02f0bb7cda9cf4d2e7135d47e81a6b8c8af2d6e1e1db821a205b0",
      "bindingDigest": "bcf807e3d2a82a76c160c50c2d759d1a31c7da89c5a27f6c8b283f66849cf95c"
    }
  ],
  "requiredSkills": [
    {
      "sourceId": "shared-practices",
      "role": "shared",
      "path": "Shared/Skills/review-contracts.md",
      "wikiId": "shared/skills/review-contracts",
      "type": "guide",
      "summary": "Contract review Skill Card.",
      "contentHash": "sha256:ca27b3425c495553a30e2723a5e4e8f2a9ce4bfb5a0adf08f92ca3a7f25acef4",
      "bindingDigest": "bcf807e3d2a82a76c160c50c2d759d1a31c7da89c5a27f6c8b283f66849cf95c",
      "skillProvider": "claude-code-project",
      "skillName": "review-contracts",
      "skillVersion": "1.0.0",
      "skillContractHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "skillTriggers": ["contract review"],
      "discoveryState": "discoverable",
      "requiredFor": ["reviewer"]
    }
  ],
  "caveats": [],
  "maintenanceWarnings": []
}
JSON

python3 "$SCRIPT" "$CONTEXT" --scaffold "$SELECTION" --feature-slug atomic-note-carry --ticket-source manual --strict --keep-selection >/dev/null

python3 - "$CONTEXT" <<'PY'
import json
import sys

context = json.load(open(sys.argv[1], encoding='utf-8'))
assert context['schemaVersion'] == 6
assert context['snapshotHash'].startswith('sha256:')
assert context['wikiBindings'][0]['sourceId'] == 'project-runtime'
note = context['wikiNotes'][0]
assert note['wikiId'] == 'project/runtime/constraints'
assert note['path'] == 'Projects/example/Runtime/constraints.md'
assert note['contentHash'].startswith('sha256:')
assert note['destination'] == {'kind': 'task-bound', 'reason': '', 'tasks': []}
assert 'content' not in note
skill = context['requiredSkills'][0]
assert skill['wikiId'] == 'shared/skills/review-contracts'
assert skill['requiredFor'] == ['reviewer']
assert skill['skillProvider'] == 'claude-code-project'
assert skill['skillName'] == 'review-contracts'
assert skill['skillVersion'] == '1.0.0'
assert skill['skillContractHash'].startswith('sha256:')
assert skill['skillTriggers'] == ['contract review']
assert skill['discoveryState'] == 'discoverable'
assert skill['destination'] == {'kind': 'task-bound', 'reason': '', 'tasks': []}
assert context['taskWikiRefs'] == []
print('v6 scaffold structure ok')
PY

python3 - "$CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding='utf-8'))
context['wikiNotes'][0]['destination'].update({
    'reason': 'T1 changes the runtime transaction boundary.',
    'tasks': ['T1'],
})
context['wikiNotes'][1]['destination']['reason'] = 'Planning context only.'
context['requiredSkills'][0]['destination'].update({
    'reason': 'T2 needs the reviewed contract workflow.',
    'tasks': ['T2'],
})
context['taskRouting']['status'] = 'confirmed'
context['taskRouting']['selectedSectionsFrozen'] = True
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(context, handle, ensure_ascii=False, indent=2)
PY

python3 "$SCRIPT" "$CONTEXT" --finalize --strict --ticket-roster "$ROSTER" >/dev/null
python3 "$SCRIPT" "$CONTEXT" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null

MISMATCHED_ROSTER="$TMP/mismatched-feature.ticket-roster.json"
python3 - "$ROSTER" "$MISMATCHED_ROSTER" <<'PY'
import json
import sys

roster = json.load(open(sys.argv[1], encoding='utf-8'))
roster['featureSlug'] = 'other-feature'
with open(sys.argv[2], 'w', encoding='utf-8') as handle:
    json.dump(roster, handle)
PY
if python3 "$SCRIPT" "$CONTEXT" --fingerprint-preflight --strict --execution-ready --ticket-roster "$MISMATCHED_ROSTER" >/tmp/obsidian-v6-feature-roster.out 2>&1; then
  printf 'Expected a cross-feature ticket roster to fail\n' >&2
  exit 1
fi
if ! grep -q 'does not match wiki context featureSlug' /tmp/obsidian-v6-feature-roster.out; then
  cat /tmp/obsidian-v6-feature-roster.out >&2
  exit 1
fi

# Schema-v6 execution rendering is metadata-only; authoritative Note bodies are emitted only by
# wiki-materialize through the bound Obsidian MCP. A missing configured runtime must fail closed.
if python3 "$TARGET_INPUT/scripts/wiki_materialize_task.py" "$CONTEXT" --task-id T1 --strict --execution-ready >/tmp/obsidian-v6-materialize.out 2>&1; then
  printf 'Expected unconfigured Obsidian runtime materialization to fail closed\n' >&2
  exit 1
fi
if ! grep -q 'Obsidian Wiki MCP CLI failed\|Obsidian Wiki MCP CLI could not be resolved' /tmp/obsidian-v6-materialize.out; then
  cat /tmp/obsidian-v6-materialize.out >&2
  exit 1
fi

python3 "$SCRIPT" "$CONTEXT" --task-id T1 --role implementer --strict --execution-ready >/tmp/obsidian-v6-render.out
if ! grep -q 'Runtime writes must preserve' /tmp/obsidian-v6-render.out; then
  cat /tmp/obsidian-v6-render.out >&2
  exit 1
fi

BAD="$TMP/duplicate.wiki-context.json"
cp "$CONTEXT" "$BAD"
python3 - "$BAD" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding='utf-8'))
context['requiredSkills'][0]['wikiId'] = context['wikiNotes'][0]['wikiId']
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(context, handle)
PY
if python3 "$SCRIPT" "$BAD" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/obsidian-v6-duplicate.out 2>&1; then
  printf 'Expected duplicate Note and Skill Card IDs to fail\n' >&2
  exit 1
fi
if ! grep -q 'duplicates wikiId' /tmp/obsidian-v6-duplicate.out; then
  cat /tmp/obsidian-v6-duplicate.out >&2
  exit 1
fi

BAD_SKILL="$TMP/invalid-skill-identity.wiki-context.json"
cp "$CONTEXT" "$BAD_SKILL"
python3 - "$BAD_SKILL" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding='utf-8'))
context['requiredSkills'][0]['skillVersion'] = '1.2'
context['requiredSkills'][0]['requiredFor'] = ['reviewer', 'reviewer']
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(context, handle)
PY
if python3 "$SCRIPT" "$BAD_SKILL" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/obsidian-v6-skill-identity.out 2>&1; then
  printf 'Expected invalid Skill Card identity/routing metadata to fail\n' >&2
  exit 1
fi
if ! grep -q 'requiredFor must be a non-empty unique subset\|skillVersion must be a semantic major.minor.patch version' /tmp/obsidian-v6-skill-identity.out; then
  cat /tmp/obsidian-v6-skill-identity.out >&2
  exit 1
fi

BAD_ROLE="$TMP/mismatched-binding-role.wiki-context.json"
cp "$CONTEXT" "$BAD_ROLE"
python3 - "$BAD_ROLE" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding='utf-8'))
context['wikiNotes'][0]['role'] = 'shared'
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(context, handle)
PY
if python3 "$SCRIPT" "$BAD_ROLE" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/obsidian-v6-binding-role.out 2>&1; then
  printf 'Expected a Note role that disagrees with its bound Source to fail\n' >&2
  exit 1
fi
if ! grep -q 'does not match the declared Source binding role' /tmp/obsidian-v6-binding-role.out; then
  cat /tmp/obsidian-v6-binding-role.out >&2
  exit 1
fi

BAD_BODY="$TMP/note-body.wiki-context.json"
cp "$CONTEXT" "$BAD_BODY"
python3 - "$BAD_BODY" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding='utf-8'))
context['wikiNotes'][0]['body'] = 'A Note body must never cross the Carry boundary.'
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(context, handle)
PY
if python3 "$SCRIPT" "$BAD_BODY" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/obsidian-v6-note-body.out 2>&1; then
  printf 'Expected a Note body field to fail schemaVersion 6 validation\n' >&2
  exit 1
fi
if ! grep -q 'contains unsupported fields: body' /tmp/obsidian-v6-note-body.out; then
  cat /tmp/obsidian-v6-note-body.out >&2
  exit 1
fi

BAD_PHASE="$TMP/brainstorm.obsidian-wiki-selection.json"
python3 - "$SELECTION" "$BAD_PHASE" <<'PY'
import json
import sys

selection = json.load(open(sys.argv[1], encoding='utf-8'))
selection['phase'] = 'brainstorm'
with open(sys.argv[2], 'w', encoding='utf-8') as handle:
    json.dump(selection, handle)
PY
if python3 "$SCRIPT" "$TMP/brainstorm.wiki-context.json" --scaffold "$BAD_PHASE" --strict >/tmp/obsidian-v6-phase.out 2>&1; then
  printf 'Expected a non-plan selection to be rejected by Carry\n' >&2
  exit 1
fi
if ! grep -q 'selection.phase must be plan' /tmp/obsidian-v6-phase.out; then
  cat /tmp/obsidian-v6-phase.out >&2
  exit 1
fi

BAD_STATUS="$TMP/no-results.obsidian-wiki-selection.json"
python3 - "$SELECTION" "$BAD_STATUS" <<'PY'
import json
import sys

selection = json.load(open(sys.argv[1], encoding='utf-8'))
selection['status'] = 'no_relevant_wiki'
with open(sys.argv[2], 'w', encoding='utf-8') as handle:
    json.dump(selection, handle)
PY
if python3 "$SCRIPT" "$TMP/no-results.wiki-context.json" --scaffold "$BAD_STATUS" --strict >/tmp/obsidian-v6-status.out 2>&1; then
  printf 'Expected a no-results selection to be rejected by Carry\n' >&2
  exit 1
fi
if ! grep -q 'selection.status must be ok or partial' /tmp/obsidian-v6-status.out; then
  cat /tmp/obsidian-v6-status.out >&2
  exit 1
fi

printf 'obsidian wiki context v6 smoke test complete\n'
