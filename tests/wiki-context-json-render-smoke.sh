#!/usr/bin/env bash
set -euo pipefail

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

ROSTER="$TMP/roster.json"
CONTEXT="$TMP/feature.wiki-context.json"
cat > "$ROSTER" <<'JSON'
{
  "featureSlug": "example-feature",
  "ticketSource": "manual",
  "tickets": [
    {
      "taskId": "T1",
      "taskTitle": "Implement path-based form updates",
      "text": "# 01 — Implement path-based form updates\n\n**What to build:** field writes go through updateByPath(path, value).\n\n**Blocked by:** None — can start immediately."
    },
    {
      "taskId": "T2",
      "taskTitle": "Add contract coverage",
      "text": "# 02 — Add contract coverage\n\n**What to build:** cover the shared payload contract.\n\n**Blocked by:** 01"
    }
  ]
}
JSON

# Independent fingerprint oracle: recompute the expected digests here rather than trusting the
# engine's own value, so a normalization regression is caught instead of confirmed. Mirrors
# wiki_context_render._normalize_task_text: CRLF->LF, rstrip each line, drop leading/trailing
# blank lines, single trailing newline.
read -r T1_HASH T2_HASH <<<"$(python3 - <<'PY' "$ROSTER"
import hashlib
import json
import sys
from pathlib import Path

roster = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))

def fingerprint(text: str) -> str:
    lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    lines = [line.rstrip() for line in lines]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    normalized = '\n'.join(lines) + '\n'
    return hashlib.sha256(normalized.encode('utf-8')).hexdigest()

hashes = {t['taskId']: fingerprint(t['text']) for t in roster['tickets']}
print(hashes['T1'], hashes['T2'])
PY
)"

cat > "$CONTEXT" <<JSON
{
  "schemaVersion": 5,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "featureSlug": "example-feature",
  "taskRouting": {
    "status": "confirmed",
    "ticketRosterFormat": "grill-adapter-ticket-roster-v1",
    "fingerprintAlgorithm": "sha256:grill-adapter-task-text-v1",
    "selectedSectionsFrozen": true,
    "refreshPolicy": "refresh-taskWikiRefs-and-fingerprints-only"
  },
  "wikiPages": [
    {
      "root": "project",
      "source": "local",
      "displayPath": ".adapter/wiki/frontend/hook-guidelines.md",
      "localPath": "frontend/hook-guidelines.md",
      "documentContext": {
        "title": "Hook Guidelines",
        "overview": "Project-private hook rules for generated form adapters.",
        "contextSource": ".adapter/wiki/frontend/hook-guidelines.index.md"
      },
      "sections": [
        {
          "sectionId": "path-based-update",
          "section_name": "path-based-update",
          "readDepth": "full",
          "relevance": "direct",
          "confidence": "high",
          "reason": "Field updates are in scope.",
          "relevanceTo": "form field updates and adapter state writes",
          "hardConstraint": true,
          "constraints": {
            "implementation": ["Use updateByPath(path, value) for all field updates."],
            "test": ["Verify nested path updates preserve change tracking."],
            "review": ["Reject direct props.model mutation."],
            "general": ["Keep path strings stable across adapter layers.", "Preserve Unicode sentinel  in rendered constraints."]
          },
          "reread": {
            "root": "project",
            "source": "local",
            "localPath": "frontend/hook-guidelines.md",
            "sectionId": "path-based-update",
            "includeDocumentContext": true
          },
          "sourceAnchors": [
            {"heading": "Path-Based Update", "excerpt": "All field updates MUST use updateByPath(path, value)."}
          ],
          "destination": {
            "kind": "task-bound",
            "reason": "This hard constraint applies to the task that changes field update behavior.",
            "tasks": ["T1"]
          }
        },
        {
          "sectionId": "deep-path",
          "section_name": "deep-path",
          "readDepth": "full",
          "relevance": "supporting",
          "confidence": "medium",
          "reason": "Nested paths are nearby selected context.",
          "relevanceTo": "nested object paths",
          "hardConstraint": false,
          "constraints": {
            "implementation": ["Use dot-notation for nested object paths."],
            "test": [],
            "review": [],
            "general": []
          },
          "sourceAnchors": [
            {"heading": "Deep Path Handling", "excerpt": "Use dot-notation paths like user.address.city."}
          ],
          "destination": {
            "kind": "planning-only",
            "reason": "This section shapes task design but does not need execution prompt injection."
          }
        }
      ]
    },
    {
      "root": "shared",
      "source": "github_mcp",
      "displayPath": ".shared-adapter/wiki/frontend/contracts.md",
      "wikiPath": "frontend/contracts.md",
      "revision": {
        "ref": "main",
        "commitSha": "abcdef1234567890",
        "shortSha": "abcdef1"
      },
      "documentContext": {
        "title": "Shared Frontend Contracts",
        "overview": "Portable shared contract rules.",
        "contextSource": "frontend/contracts.index.md"
      },
      "sections": [
        {
          "sectionId": "contract-review",
          "section_name": "contract-review",
          "readDepth": "full",
          "relevance": "direct",
          "confidence": "high",
          "reason": "Task touches shared contract shape.",
          "relevanceTo": "shared contract payload naming",
          "hardConstraint": true,
          "constraints": {
            "implementation": ["Keep shared payload names portable."],
            "test": ["Add contract coverage for shared payload names."],
            "review": ["Check that no project-specific environment names leak into shared docs."],
            "general": []
          },
          "reread": {
            "root": "shared",
            "source": "github_mcp",
            "wikiPath": "frontend/contracts.md",
            "sectionId": "contract-review",
            "includeDocumentContext": true
          },
          "sourceAnchors": [
            {"heading": "Contract Review", "excerpt": "Shared payload names must stay portable."}
          ],
          "destination": {
            "kind": "global",
            "reason": "Portable shared contract naming must be visible to every implementation and review task."
          }
        }
      ]
    }
  ],
  "taskWikiRefs": [
    {
      "taskId": "T1",
      "taskTitle": "Implement path-based form updates",
      "taskFingerprint": "${T1_HASH}"
    },
    {
      "taskId": "T2",
      "taskTitle": "Add contract coverage",
      "taskFingerprint": "${T2_HASH}"
    }
  ],
  "caveats": [],
  "maintenanceWarnings": [
    "shared wiki maintenance: frontend/contracts.md is approaching large-page thresholds; future updates should prefer ownership cleanup or splitting. Selected section rereads remain section-scoped."
  ]
}
JSON

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected %s to contain %s\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'Expected %s not to contain %s\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

EXAMPLE="${TARGET_INPUT}/contracts/wiki-context-v5.example.jsonc"
if [[ ! -f "$EXAMPLE" ]]; then
  printf 'Missing wiki context example contract: %s\n' "$EXAMPLE" >&2
  exit 1
fi
EXAMPLE_TEXT="$(python3 - <<'PY' "$EXAMPLE"
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
assert_contains "example contract" 'Historical schemaVersion 5 compatibility reference' "$EXAMPLE_TEXT"
assert_contains "example contract" 'must not be authored anew' "$EXAMPLE_TEXT"
assert_contains "example contract" 'Do not inspect <plugin-root>/scripts/wiki_context_render.py to infer this format' "$EXAMPLE_TEXT"
assert_contains "example contract" '--bind-fingerprints --strict' "$EXAMPLE_TEXT"
assert_contains "example contract" '--execution-ready --ticket-roster' "$EXAMPLE_TEXT"
assert_contains "example contract" '--fingerprint-preflight' "$EXAMPLE_TEXT"
assert_not_contains "example contract" '0000000000000000' "$EXAMPLE_TEXT"

python3 "$SCRIPT" "$CONTEXT" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null
python3 "$SCRIPT" "$CONTEXT" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null

# --- Adapter fingerprint binding (mechanical taskFingerprint stamping) ---
# Author a sidecar with NO taskFingerprint, then stamp it with --bind-fingerprints.
BIND_CTX="$TMP/bind.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$BIND_CTX"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
for ref in data['taskWikiRefs']:
    ref.pop('taskFingerprint', None)
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
# Pre-bind execution-ready validation must fail because fingerprints are absent.
if python3 "$SCRIPT" "$BIND_CTX" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-prebind.out 2>&1; then
  printf 'Expected validate-only to fail before binding fingerprints\n' >&2
  exit 1
fi
assert_contains "pre-bind validate failure" 'taskFingerprint' "$(cat /tmp/wiki-context-prebind.out)"
# Bind stamps fingerprints, validates execution-ready, and writes in place.
BIND_OUT="$(python3 "$SCRIPT" "$BIND_CTX" --bind-fingerprints --strict --execution-ready --ticket-roster "$ROSTER")"
assert_contains "bind output" 'bound taskFingerprint for 2 task(s)' "$BIND_OUT"
# A clean bind guarantees the execution-side preflight passes.
python3 "$SCRIPT" "$BIND_CTX" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null
# The stamped digest must equal the independently computed plan hash (one algorithm, one source of truth).
BOUND_T1="$(python3 -c "import json,sys;print(next(r['taskFingerprint'] for r in json.load(open(sys.argv[1], encoding='utf-8'))['taskWikiRefs'] if r['taskId']=='T1'))" "$BIND_CTX")"
if [[ "$BOUND_T1" != "$T1_HASH" ]]; then
  printf 'Bound T1 fingerprint %s does not match expected %s\n' "$BOUND_T1" "$T1_HASH" >&2
  exit 1
fi
# Re-binding an already-current sidecar is idempotent.
assert_contains "rebind idempotent" 'already current' "$(python3 "$SCRIPT" "$BIND_CTX" --bind-fingerprints --strict --execution-ready --ticket-roster "$ROSTER")"

# Placeholder fingerprints (e.g. copied skeleton zeros) must be rejected, not silently accepted.
PLACEHOLDER_CTX="$TMP/placeholder.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$PLACEHOLDER_CTX"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['taskWikiRefs'][0]['taskFingerprint'] = '0' * 64
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$PLACEHOLDER_CTX" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-placeholder.out 2>&1; then
  printf 'Expected placeholder fingerprint to fail validation\n' >&2
  exit 1
fi
assert_contains "placeholder failure" 'placeholder' "$(cat /tmp/wiki-context-placeholder.out)"

# Root-cause guard: a well-formed but STALE fingerprint must be caught by validate-only itself
# (with --execution-ready --ticket-roster), not only later at the execution-side preflight.
STALE_CTX="$TMP/stale.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$STALE_CTX"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['taskWikiRefs'][0]['taskFingerprint'] = 'abc1230000000000000000000000000000000000000000000000000000000001'
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$STALE_CTX" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-stale.out 2>&1; then
  printf 'Expected stale fingerprint to fail validate-only with --ticket-roster\n' >&2
  exit 1
fi
assert_contains "stale validate failure" 'fingerprint mismatch' "$(cat /tmp/wiki-context-stale.out)"

# --bind-fingerprints refuses to write when the roster and sidecar task sets disagree.
DRIFT_ROSTER="$TMP/roster-drift.json"
python3 - <<'PY' "$ROSTER" "$DRIFT_ROSTER"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['tickets'].append({'taskId': 'T3', 'taskTitle': 'Extra task', 'text': '# 03 — Extra task\n\n**What to build:** new work.\n\n**Blocked by:** 02'})
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$BIND_CTX" --bind-fingerprints --strict --execution-ready --ticket-roster "$DRIFT_ROSTER" >/tmp/wiki-context-bind-drift.out 2>&1; then
  printf 'Expected bind to refuse when a roster ticket is missing from taskWikiRefs\n' >&2
  exit 1
fi
assert_contains "bind drift failure" 'roster ticket missing from taskWikiRefs: T3' "$(cat /tmp/wiki-context-bind-drift.out)"

T1_OUT="$(python3 "$SCRIPT" "$CONTEXT" --task-id T1 --role implementer --strict --execution-ready)"
assert_contains "T1 render" 'Hook Guidelines' "$T1_OUT"
assert_contains "T1 render" 'Shared Frontend Contracts' "$T1_OUT"
assert_contains "T1 render" 'Use updateByPath(path, value)' "$T1_OUT"
assert_contains "T1 render" 'Keep shared payload names portable' "$T1_OUT"
assert_contains "T1 render" 'Preserve Unicode sentinel  in rendered constraints.' "$T1_OUT"
CP936_OUT="$(PYTHONIOENCODING=cp936:strict python3 "$SCRIPT" "$CONTEXT" --task-id T1 --role implementer --strict --execution-ready)"
assert_contains "cp936 render" 'Preserve Unicode sentinel  in rendered constraints.' "$CP936_OUT"
assert_not_contains "T1 render" 'Use dot-notation for nested object paths' "$T1_OUT"
assert_not_contains "T1 render" 'No selected wiki constraints for this role.' "$T1_OUT"
assert_not_contains "T1 render" 'planning-only' "$T1_OUT"
assert_not_contains "T1 render" 'large-page thresholds' "$T1_OUT"

T2_OUT="$(python3 "$SCRIPT" "$CONTEXT" --task-id T2 --role implementer --strict --execution-ready)"
assert_contains "T2 render" 'Shared Frontend Contracts' "$T2_OUT"
assert_contains "T2 render" 'Keep shared payload names portable' "$T2_OUT"
assert_not_contains "T2 render" 'Use updateByPath(path, value)' "$T2_OUT"
assert_not_contains "T2 render" 'Use dot-notation for nested object paths' "$T2_OUT"

REVIEW_OUT="$(python3 "$SCRIPT" "$CONTEXT" --task-id T1 --role reviewer --strict --execution-ready)"
assert_contains "reviewer render" 'Reject direct props.model mutation' "$REVIEW_OUT"
assert_contains "reviewer render" 'Check that no project-specific environment names leak into shared docs' "$REVIEW_OUT"

REREAD_T1="$(python3 "$SCRIPT" "$CONTEXT" --task-id T1 --reread-list --strict --execution-ready)"
assert_contains "T1 reread list" 'path-based-update' "$REREAD_T1"
assert_contains "T1 reread list" 'contract-review' "$REREAD_T1"
assert_contains "T1 reread list" '"source": "github_mcp"' "$REREAD_T1"
assert_contains "T1 reread list" '"wikiPath": "frontend/contracts.md"' "$REREAD_T1"
assert_contains "T1 reread list" '"revision"' "$REREAD_T1"
assert_contains "T1 reread list" '"commitSha": "abcdef1234567890"' "$REREAD_T1"
assert_not_contains "T1 reread list" 'deep-path' "$REREAD_T1"

REREAD_T2="$(python3 "$SCRIPT" "$CONTEXT" --task-id T2 --reread-list --strict --execution-ready)"
assert_contains "T2 reread list" 'contract-review' "$REREAD_T2"
assert_not_contains "T2 reread list" 'path-based-update' "$REREAD_T2"

EMPTY_CONTEXT="$TMP/empty.wiki-context.json"
printf '{"schemaVersion":5,"kind":"grill-adapter.wiki-context","wikiPages":[]}' > "$EMPTY_CONTEXT"
EMPTY_OUT="$(python3 "$SCRIPT" "$EMPTY_CONTEXT" --role implementer --strict)"
assert_contains "empty render" 'No selected wiki constraints for this role.' "$EMPTY_OUT"

UNKNOWN_TASK_OUT="$TMP/unknown-task.out"
if python3 "$SCRIPT" "$CONTEXT" --task-id T99 --role implementer --strict --execution-ready >"$UNKNOWN_TASK_OUT" 2>&1; then
  printf 'Expected unknown task-id to fail\n' >&2
  exit 1
fi
assert_contains "unknown task failure" 'taskWikiRefs must contain exactly one entry for taskId T99' "$(cat "$UNKNOWN_TASK_OUT")"

LEGACY="$TMP/plan.wiki-context.md"
printf '# Legacy\n' > "$LEGACY"
if python3 "$SCRIPT" "$LEGACY" --role implementer >/tmp/wiki-context-legacy.out 2>&1; then
  printf 'Expected legacy markdown sidecar to fail\n' >&2
  exit 1
fi
assert_contains "legacy failure" 'Legacy .wiki-context.md is not supported' "$(cat /tmp/wiki-context-legacy.out)"

BAD_SCHEMA="$TMP/bad-schema.wiki-context.json"
printf '{"schemaVersion":2,"kind":"grill-adapter.wiki-context","wikiPages":[]}' > "$BAD_SCHEMA"
if python3 "$SCRIPT" "$BAD_SCHEMA" --validate-only >/tmp/wiki-context-bad-schema.out 2>&1; then
  printf 'Expected bad schema to fail\n' >&2
  exit 1
fi
assert_contains "bad schema failure" 'schemaVersion must be one of 5, 6' "$(cat /tmp/wiki-context-bad-schema.out)"

BAD_CATEGORY="$TMP/bad-category.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$BAD_CATEGORY"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['wikiPages'][0]['sections'][0]['constraints']['security'] = ['unknown category']
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if PYTHONIOENCODING=cp936:strict python3 "$SCRIPT" "$BAD_CATEGORY" --role implementer --strict >/tmp/wiki-context-bad-category.out 2>&1; then
  printf 'Expected unknown category to fail in strict mode\n' >&2
  exit 1
fi
assert_contains "bad category failure" 'unsupported categories: security' "$(cat /tmp/wiki-context-bad-category.out)"
assert_not_contains "bad category failure" 'UnicodeEncodeError' "$(cat /tmp/wiki-context-bad-category.out)"

BAD_SECTION_CONTEXT="$TMP/bad-section-context.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$BAD_SECTION_CONTEXT"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['wikiPages'][0]['sections'][0]['documentContext'] = {'title': 'duplicated'}
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$BAD_SECTION_CONTEXT" --role implementer --strict >/tmp/wiki-context-bad-section-context.out 2>&1; then
  printf 'Expected section-level documentContext to fail in strict mode\n' >&2
  exit 1
fi
assert_contains "bad section context failure" 'documentContext is not allowed' "$(cat /tmp/wiki-context-bad-section-context.out)"

TASKBOUND_MISSING="$TMP/taskbound-missing.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$TASKBOUND_MISSING"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
# A task-bound section with no destination.tasks must fail execution-ready validation.
data['wikiPages'][0]['sections'][0]['destination'].pop('tasks', None)
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$TASKBOUND_MISSING" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-taskbound-missing.out 2>&1; then
  printf 'Expected task-bound section with no destination.tasks to fail\n' >&2
  exit 1
fi
assert_contains "task-bound missing failure" 'destination.tasks' "$(cat /tmp/wiki-context-taskbound-missing.out)"

# appliesTo is removed in schemaVersion 5: strict validation rejects it with a migration hint.
APPLIES_TO="$TMP/applies-to.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$APPLIES_TO"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['wikiPages'][0]['sections'][0]['appliesTo'] = ['T1']
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$APPLIES_TO" --validate-only --strict >/tmp/wiki-context-applies-to.out 2>&1; then
  printf 'Expected removed appliesTo field to fail strict validation\n' >&2
  exit 1
fi
assert_contains "appliesTo removed failure" 'appliesTo is removed' "$(cat /tmp/wiki-context-applies-to.out)"

UNKNOWN_TASK_REF="$TMP/unknown-task-ref.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$UNKNOWN_TASK_REF"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
# A task-bound section binding to a task id that is not in the roster must fail.
data['wikiPages'][0]['sections'][0]['destination']['tasks'] = ['T99']
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$UNKNOWN_TASK_REF" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-unknown-task-ref.out 2>&1; then
  printf 'Expected destination.tasks referencing an unknown task id to fail\n' >&2
  exit 1
fi
assert_contains "unknown task ref failure" 'unknown task id T99' "$(cat /tmp/wiki-context-unknown-task-ref.out)"

BAD_DESTINATION="$TMP/bad-destination.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$BAD_DESTINATION"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['wikiPages'][0]['sections'][0]['destination']['kind'] = 'planning-only'
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$BAD_DESTINATION" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-bad-destination.out 2>&1; then
  printf 'Expected hard/direct planning-only destination to fail\n' >&2
  exit 1
fi
assert_contains "bad destination failure" 'planning-only' "$(cat /tmp/wiki-context-bad-destination.out)"

HARD_NO_REREAD="$TMP/hard-no-reread.wiki-context.json"
python3 - <<'PY' "$CONTEXT" "$HARD_NO_REREAD"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
del data['wikiPages'][0]['sections'][0]['reread']
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$HARD_NO_REREAD" --validate-only --strict --execution-ready --ticket-roster "$ROSTER" >/tmp/wiki-context-hard-no-reread.out 2>&1; then
  printf 'Expected hard-constraint section without reread to fail execution-ready validation\n' >&2
  exit 1
fi
assert_contains "hard no reread failure" 'reread' "$(cat /tmp/wiki-context-hard-no-reread.out)"

# A ticket edited after the wiki was bound to it must fail the execution-side preflight.
ROSTER_EDITED="$TMP/roster-edited.json"
python3 - <<'PY' "$ROSTER" "$ROSTER_EDITED"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
original = data['tickets'][0]['text']
edited = original.replace(
    'field writes go through updateByPath(path, value).',
    'field writes go through updateByPath(path, value) and preserve nested change tracking.',
)
# Guard the guard: a no-op replace would leave the fingerprint intact and make this drift case
# silently vacuous (the preflight would pass and the test would fail for the wrong reason).
assert edited != original, 'drift fixture did not change the ticket text'
data['tickets'][0]['text'] = edited
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
if python3 "$SCRIPT" "$CONTEXT" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER_EDITED" >/tmp/wiki-context-bad-fingerprint.out 2>&1; then
  printf 'Expected fingerprint preflight mismatch to fail\n' >&2
  exit 1
fi
assert_contains "bad fingerprint failure" 'fingerprint' "$(cat /tmp/wiki-context-bad-fingerprint.out)"

# R6: source-anchor excerpts are soft-capped at render with an ellipsis hint (a bounded pointer, not
# the authoritative text -- that is the reread's job). Short excerpts pass through unchanged.
python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wcr_cap", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
short = "All field updates MUST use updateByPath(path, value)."
assert m._truncate_excerpt(short) == short, "short excerpt must pass through unchanged"
assert m._truncate_excerpt(None) == "", "None excerpt -> empty string"
long = "x" * 500
out = m._truncate_excerpt(long)
assert out.endswith("(truncated; reread the section for full text)"), out
assert ("x" * 500) not in out and len(out) <= m.MAX_SOURCE_ANCHOR_EXCERPT + 60, out
print("source-anchor excerpt cap ok")
PY

printf 'wiki-context-json-render smoke test complete\n'
