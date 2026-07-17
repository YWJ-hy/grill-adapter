#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the mechanical wiki-context sidecar generator:
#   wiki-researcher selection JSON --scaffold--> complete-shaped sidecar
#   plan headings            --scaffold-tasks--> taskWikiRefs scaffold (idempotent)
#   author edits routing -> --bind-fingerprints --execution-ready -> --fingerprint-preflight
# Proves the generate-then-edit chain so the planning agent edits a complete structure instead of
# hand-authoring deep JSON (which dropped fields like reread/destination and failed validation late).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPT="${TARGET_INPUT}/scripts/wiki_context_render.py"
SELECTION_EXAMPLE="${TARGET_INPUT}/contracts/wiki-selection-v1.example.jsonc"

if [[ ! -f "$SCRIPT" ]]; then
  printf 'Missing wiki context renderer: %s\n' "$SCRIPT" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected %s to contain %s\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'Expected %s not to contain %s\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

# --- The shipped selection contract documents the researcher OUTPUT shape. ---
if [[ ! -f "$SELECTION_EXAMPLE" ]]; then
  printf 'Missing wiki selection example contract: %s\n' "$SELECTION_EXAMPLE" >&2
  exit 1
fi
SELECTION_TEXT="$(python3 - <<'PY' "$SELECTION_EXAMPLE"
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
assert_contains "selection contract" 'wiki-researcher OUTPUT contract' "$SELECTION_TEXT"
assert_contains "selection contract" '--scaffold' "$SELECTION_TEXT"
# The generator fills these mechanically, so the selection contract must NOT model them as inputs.
assert_not_contains "selection contract" '"taskWikiRefs"' "$SELECTION_TEXT"
assert_not_contains "selection contract" '"taskFingerprint"' "$SELECTION_TEXT"
assert_not_contains "selection contract" '"reread"' "$SELECTION_TEXT"

ROSTER="$TMP/feature.ticket-roster.json"
SEL="$TMP/feature.wiki-selection.json"
CTX="$TMP/feature.wiki-context.json"

# The host-produced ticket roster: the task identity + fingerprint source. Stands in for whatever
# the host publishes (grill local-markdown .scratch/<slug>/issues/*.md, or tracker issues).
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

# A wiki-researcher selection: one local hard section, one local soft section, one github_mcp hard
# section, plus the github_mcp shared wiki identity.
cat > "$SEL" <<'JSON'
{
  "status": "ok",
  "phase": "plan",
  "sharedWikiSource": {
    "kind": "github_mcp",
    "displayRoot": ".shared-adapter/wiki",
    "repoUrl": "https://github.com/acme/platform-wiki.git",
    "baseBranch": "master",
    "revision": { "ref": "master", "commitSha": "abcdef1234567890", "shortSha": "abcdef1" }
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
          "readDepth": "full",
          "relevance": "direct",
          "confidence": "high",
          "reason": "Field updates are in scope.",
          "relevanceTo": "form field updates",
          "hardConstraint": true,
          "constraints": {
            "implementation": ["Use updateByPath(path, value) for all field updates."],
            "test": ["Verify nested path updates preserve change tracking."],
            "review": ["Reject direct props.model mutation."],
            "general": []
          },
          "sourceAnchors": [
            {"heading": "Path-Based Update", "excerpt": "All field updates MUST use updateByPath(path, value)."}
          ]
        },
        {
          "sectionId": "deep-path",
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
          }
        }
      ]
    },
    {
      "root": "shared",
      "source": "github_mcp",
      "displayPath": ".shared-adapter/wiki/frontend/contracts.md",
      "wikiPath": "frontend/contracts.md",
      "revision": { "ref": "main", "commitSha": "abcdef1234567890", "shortSha": "abcdef1" },
      "documentContext": {
        "title": "Shared Frontend Contracts",
        "overview": "Portable shared contract rules.",
        "contextSource": "frontend/contracts.index.md"
      },
      "sections": [
        {
          "sectionId": "contract-review",
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
          }
        }
      ]
    }
  ],
  "caveats": [],
  "maintenanceWarnings": [
    "shared wiki maintenance: frontend/contracts.md is approaching large-page thresholds; future updates should prefer ownership cleanup or splitting. Selected section rereads remain section-scoped."
  ]
}
JSON

# Preserve a pristine copy: --scaffold now consumes (removes) the selection it reads on success, and the
# negative cases below build their malformed selections from this source.
SEL_SRC="$TMP/selection-src.json"
cp "$SEL" "$SEL_SRC"

# --- Pass 0: --keep-selection opts out of removal (tests/debugging/regenerate from an edited selection). ---
KEEP_CTX="$TMP/keep.wiki-context.json"
KEEP_SEL="$TMP/keep.wiki-selection.json"
cp "$SEL_SRC" "$KEEP_SEL"
python3 "$SCRIPT" "$KEEP_CTX" --scaffold "$KEEP_SEL" --feature-slug example-feature --ticket-source manual --strict --keep-selection >/dev/null
if [[ ! -f "$KEEP_SEL" ]]; then
  printf 'Expected --keep-selection to preserve the selection %s\n' "$KEEP_SEL" >&2
  exit 1
fi

# --- Pass 1: --scaffold builds a complete-shaped sidecar from the selection. ---
SCAFFOLD_OUT="$(python3 "$SCRIPT" "$CTX" --scaffold "$SEL" --feature-slug example-feature --ticket-source manual --strict)"
assert_contains "scaffold output" 'scaffolded wiki context with 2 page(s)' "$SCAFFOLD_OUT"
# The selection is a transient intermediate: scaffolding consumes and removes it on success, leaving only
# the plan and its generated .wiki-context.json.
assert_contains "scaffold output" 'removed consumed selection' "$SCAFFOLD_OUT"
if [[ -f "$SEL" ]]; then
  printf 'Expected --scaffold to remove the consumed selection %s\n' "$SEL" >&2
  exit 1
fi
# The freshly scaffolded skeleton must already pass structural validation (no dropped fields).
python3 "$SCRIPT" "$CTX" --validate-only --strict >/dev/null

python3 - "$CTX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['schemaVersion'] == 5 and d['kind'] == 'grill-adapter.wiki-context'
assert d['generatedBy'] == 'grill-adapter', d.get('generatedBy')
# taskRouting block is fully present and pre-confirmation.
tr = d['taskRouting']
assert tr['status'] == 'candidate_sections_only', tr['status']
assert tr['selectedSectionsFrozen'] is False
assert tr['ticketRosterFormat'] == 'grill-adapter-ticket-roster-v1'
assert tr['fingerprintAlgorithm'] == 'sha256:grill-adapter-task-text-v1'
# Shared wiki identity captured because a github_mcp page was selected.
assert d['sharedWiki']['repoUrl'] == 'https://github.com/acme/platform-wiki.git'
assert d['sharedWiki']['baseBranch'] == 'master'
assert d['maintenanceWarnings'] == ['shared wiki maintenance: frontend/contracts.md is approaching large-page thresholds; future updates should prefer ownership cleanup or splitting. Selected section rereads remain section-scoped.']
pages = d['wikiPages']
# Local hard section: reread auto-derived with localPath; destination defaulted task-bound, reason empty,
# tasks seeded empty for the author to fill once the roster exists.
s0 = pages[0]['sections'][0]
assert s0['hardConstraint'] is True
assert s0['reread']['localPath'] == 'frontend/hook-guidelines.md'
assert s0['reread']['includeDocumentContext'] is True
assert 'wikiPath' not in s0['reread']
assert s0['destination'] == {'kind': 'task-bound', 'reason': '', 'tasks': []}, s0['destination']
# Soft section: no reread, planning-only default, and no tasks list (only task-bound gets one).
s1 = pages[0]['sections'][1]
assert s1['hardConstraint'] is False
assert 'reread' not in s1
assert s1['destination']['kind'] == 'planning-only'
assert 'tasks' not in s1['destination'], s1['destination']
# R5: empty constraint buckets are dropped (s1 only had implementation) and section_name is no
# longer emitted (sectionId is the single canonical id). s0 likewise drops its empty general bucket.
assert set(s1['constraints']) == {'implementation'}, s1['constraints']
assert 'section_name' not in s1, 's1 still carries redundant section_name'
assert 'general' not in pages[0]['sections'][0]['constraints'], 's0 empty general bucket not dropped'
# github_mcp hard section: reread uses wikiPath, never localPath.
sc = pages[1]['sections'][0]
assert sc['reread']['wikiPath'] == 'frontend/contracts.md'
assert 'localPath' not in sc['reread']
# Task roster seeded empty for --scaffold-tasks; no legacy globalWikiRefs collection exists in v4.
assert d['taskWikiRefs'] == []
assert 'globalWikiRefs' not in d
print('scaffold structure ok')
PY

# --- Pass 2: --scaffold-tasks adds one taskWikiRefs entry per stable plan task. ---
TASKS_OUT="$(python3 "$SCRIPT" "$CTX" --scaffold-tasks --ticket-roster "$ROSTER" --strict)"
assert_contains "scaffold-tasks output" 'scaffolded 2 task(s): T1, T2' "$TASKS_OUT"
python3 - "$CTX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
refs = {r['taskId']: r for r in d['taskWikiRefs']}
assert set(refs) == {'T1', 'T2'}
assert refs['T1']['taskTitle'] == 'Implement path-based form updates'
assert refs['T2']['taskTitle'] == 'Add contract coverage'
# Roster only: no per-task wikiRefs (routing is on section.destination), no fingerprint yet (bind's job).
assert 'wikiRefs' not in refs['T1'] and 'wikiRefs' not in refs['T2']
assert 'taskFingerprint' not in refs['T1']
print('scaffold-tasks structure ok')
PY

# --- Author edits ONLY semantic routing on each section's destination. ---
python3 - "$CTX" <<'PY'
import json, sys
f = sys.argv[1]
d = json.load(open(f, encoding='utf-8'))
# path-based-update: keep the task-bound default; write the reason and bind it to T1.
s0 = d['wikiPages'][0]['sections'][0]['destination']
s0['reason'] = 'T1 changes field update behavior.'
s0['tasks'] = ['T1']
# deep-path: planning-only; reason only.
d['wikiPages'][0]['sections'][1]['destination']['reason'] = 'Shaped task design only; not injected.'
# contract-review: promote to global (reaches every task and reviewer); global carries no tasks list.
contract = d['wikiPages'][1]['sections'][0]['destination']
contract['kind'] = 'global'  # override the task-bound default
contract.pop('tasks', None)
contract['reason'] = 'Portable contract naming applies to every task and reviewer.'
d['taskRouting']['status'] = 'confirmed'
d['taskRouting']['selectedSectionsFrozen'] = True
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY

# --- Mechanical tail (existing): stamp fingerprints + gate execution readiness, then preflight. ---
BIND_OUT="$(python3 "$SCRIPT" "$CTX" --bind-fingerprints --strict --execution-ready --ticket-roster "$ROSTER")"
assert_contains "bind output" 'bound taskFingerprint for 2 task(s)' "$BIND_OUT"
python3 "$SCRIPT" "$CTX" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null
# The fully routed sidecar renders task-scoped constraints for execution.
T1_RENDER="$(python3 "$SCRIPT" "$CTX" --task-id T1 --role implementer --strict --execution-ready)"
assert_contains "T1 render" 'Use updateByPath(path, value)' "$T1_RENDER"
assert_contains "T1 render" 'Keep shared payload names portable' "$T1_RENDER"
assert_not_contains "T1 render" 'large-page thresholds' "$T1_RENDER"

# --- Re-running --scaffold-tasks is idempotent: roster keeps taskFingerprint; section routing untouched. ---
python3 "$SCRIPT" "$CTX" --scaffold-tasks --ticket-roster "$ROSTER" --strict >/dev/null
python3 - "$CTX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
t1 = next(r for r in d['taskWikiRefs'] if r['taskId'] == 'T1')
# Preserved fingerprint stays present (bind owns it; rescaffold must not strip it).
assert 'taskFingerprint' in t1, 'lost taskFingerprint on rescaffold'
# Section->task routing lives on destination.tasks and is untouched by --scaffold-tasks.
s0 = d['wikiPages'][0]['sections'][0]['destination']
assert s0['kind'] == 'task-bound' and s0['tasks'] == ['T1'], s0
print('idempotent rescaffold ok')
PY
# Still execution-ready after the idempotent rescaffold.
python3 "$SCRIPT" "$CTX" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null

# --- --scaffold-tasks drops (and reports) tasks no longer in the ticket roster. ---
DROP_CTX="$TMP/drop.wiki-context.json"
cp "$CTX" "$DROP_CTX"
DROP_ROSTER="$TMP/roster-drop.json"
python3 - <<'PY' "$ROSTER" "$DROP_ROSTER"
import json, sys
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding='utf-8'))
data['tickets'] = [t for t in data['tickets'] if t['taskId'] != 'T2']
open(dst, 'w', encoding='utf-8').write(json.dumps(data))
PY
DROP_OUT="$(python3 "$SCRIPT" "$DROP_CTX" --scaffold-tasks --ticket-roster "$DROP_ROSTER" --strict 2>&1)"
assert_contains "drop drift" 'dropped taskWikiRefs entry no longer in the ticket roster: T2' "$DROP_OUT"

# --- Negative: a malformed selection fails at the shallow input, not deep in the sidecar. ---
BAD_CAT_SEL="$TMP/bad-category.wiki-selection.json"
python3 - "$SEL_SRC" "$BAD_CAT_SEL" <<'PY'
import json, sys
src, dst = sys.argv[1:3]
d = json.load(open(src, encoding='utf-8'))
d['wikiPages'][0]['sections'][0]['constraints']['security'] = ['unsupported category']
open(dst, 'w', encoding='utf-8').write(json.dumps(d))
PY
if python3 "$SCRIPT" "$TMP/bad.json" --scaffold "$BAD_CAT_SEL" --strict >/tmp/wiki-scaffold-bad-category.out 2>&1; then
  printf 'Expected --scaffold to reject unsupported constraint category\n' >&2
  exit 1
fi
assert_contains "bad category" 'unsupported categories: security' "$(cat /tmp/wiki-scaffold-bad-category.out)"
# A failed scaffold must not delete the selection — it stays in place for repair.
if [[ ! -f "$BAD_CAT_SEL" ]]; then
  printf 'Expected a failed --scaffold to keep the selection %s for repair\n' "$BAD_CAT_SEL" >&2
  exit 1
fi

BAD_PATH_SEL="$TMP/bad-path.wiki-selection.json"
python3 - "$SEL_SRC" "$BAD_PATH_SEL" <<'PY'
import json, sys
src, dst = sys.argv[1:3]
d = json.load(open(src, encoding='utf-8'))
for key in ('displayPath', 'localPath', 'wikiPath', 'path'):
    d['wikiPages'][0].pop(key, None)
open(dst, 'w', encoding='utf-8').write(json.dumps(d))
PY
if python3 "$SCRIPT" "$TMP/bad2.json" --scaffold "$BAD_PATH_SEL" --strict >/tmp/wiki-scaffold-bad-path.out 2>&1; then
  printf 'Expected --scaffold to reject a page with no path field\n' >&2
  exit 1
fi
assert_contains "bad path" 'must include one of displayPath' "$(cat /tmp/wiki-scaffold-bad-path.out)"

# --- Negative: combining the two scaffold passes in one invocation is rejected. ---
if python3 "$SCRIPT" "$CTX" --scaffold "$SEL_SRC" --scaffold-tasks --ticket-roster "$ROSTER" >/tmp/wiki-scaffold-combo.out 2>&1; then
  printf 'Expected --scaffold + --scaffold-tasks together to fail\n' >&2
  exit 1
fi
assert_contains "combo guard" 'separate invocations' "$(cat /tmp/wiki-scaffold-combo.out)"

# --- --finalize: one-shot scaffold-tasks + bind in a single write, after the lone destination edit pass. ---
# Tier 1' planning path: fresh scaffold -> author edits destination once -> --finalize stamps + gates + writes once,
# so the planning agent's Read-tracked sidecar is re-surfaced once instead of after two separate rewrites.
FIN_SEL="$TMP/finalize.wiki-selection.json"
FIN_CTX="$TMP/finalize.wiki-context.json"
cp "$SEL_SRC" "$FIN_SEL"
python3 "$SCRIPT" "$FIN_CTX" --scaffold "$FIN_SEL" --feature-slug example-feature --ticket-source manual --strict >/dev/null
# Author edits ONLY semantic routing, in a single pass, exactly as the reworked planning patch directs.
python3 - "$FIN_CTX" <<'PY'
import json, sys
f = sys.argv[1]
d = json.load(open(f, encoding='utf-8'))
s0 = d['wikiPages'][0]['sections'][0]['destination']
s0['reason'] = 'T1 changes field update behavior.'
s0['tasks'] = ['T1']
d['wikiPages'][0]['sections'][1]['destination']['reason'] = 'Shaped task design only; not injected.'
contract = d['wikiPages'][1]['sections'][0]['destination']
contract['kind'] = 'global'
contract.pop('tasks', None)
contract['reason'] = 'Portable contract naming applies to every task and reviewer.'
d['taskRouting']['status'] = 'confirmed'
d['taskRouting']['selectedSectionsFrozen'] = True
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
# One call builds the roster, stamps fingerprints, gates execution readiness, and writes once.
FIN_OUT="$(python3 "$SCRIPT" "$FIN_CTX" --finalize --strict --ticket-roster "$ROSTER")"
assert_contains "finalize output" 'finalized 2 task(s) (2 updated): T1, T2' "$FIN_OUT"
# A clean finalize guarantees the execution-side preflight passes and execution-ready render works.
python3 "$SCRIPT" "$FIN_CTX" --fingerprint-preflight --strict --execution-ready --ticket-roster "$ROSTER" >/dev/null
FIN_RENDER="$(python3 "$SCRIPT" "$FIN_CTX" --task-id T1 --role implementer --strict --execution-ready)"
assert_contains "finalize render" 'Use updateByPath(path, value)' "$FIN_RENDER"
# Re-running --finalize is idempotent: fingerprints already current, still execution-ready.
FIN_OUT2="$(python3 "$SCRIPT" "$FIN_CTX" --finalize --strict --ticket-roster "$ROSTER")"
assert_contains "finalize idempotent" 'finalized 2 task(s) (already current): T1, T2' "$FIN_OUT2"

# --- Negative: --finalize requires --ticket-roster. ---
if python3 "$SCRIPT" "$FIN_CTX" --finalize --strict >/tmp/wiki-finalize-noplan.out 2>&1; then
  printf 'Expected --finalize without --ticket-roster to fail\n' >&2
  exit 1
fi
assert_contains "finalize needs plan" 'requires --ticket-roster' "$(cat /tmp/wiki-finalize-noplan.out)"

# --- Negative: --finalize must not be combined with the subcommands it already runs. ---
if python3 "$SCRIPT" "$FIN_CTX" --finalize --scaffold-tasks --ticket-roster "$ROSTER" >/tmp/wiki-finalize-combo.out 2>&1; then
  printf 'Expected --finalize + --scaffold-tasks together to fail\n' >&2
  exit 1
fi
assert_contains "finalize combo guard" 'already runs scaffold-tasks' "$(cat /tmp/wiki-finalize-combo.out)"

printf 'wiki-context-scaffold smoke test complete\n'
