#!/usr/bin/env bash
set -euo pipefail

# Exercises the schema-v6 public Bind seam: per-ticket/reviewer materialization must reread only
# routed hard Notes and role-required Skill Cards through the Obsidian MCP CLI, then add exactly
# one de-duplicated depends_on hop. The fake CLI makes filesystem fallback impossible to hide.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
MATERIALIZE="$ROOT/scripts/wiki_materialize_task.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
CONTEXT="$PROJECT/.adapter/context/feature.wiki-context.json"
mkdir -p "$(dirname "$CONTEXT")"

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_C="c68ff5c9cb55e1ef292eb6f5e7cfdcee5ea67a999f0381a3a3f44bb9e7165ced"
SHA_D="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

cat > "$CONTEXT" <<JSON
{
  "schemaVersion": 6,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "featureSlug": "feature",
  "ticketSource": "manual",
  "snapshotHash": "sha256:${SHA_A}",
  "wikiBindings": [
    {"sourceId":"project","role":"project","bindingDigest":"${SHA_B}"}
  ],
  "taskRouting": {"status":"confirmed","ticketRosterFormat":"grill-adapter-ticket-roster-v1","fingerprintAlgorithm":"sha256:grill-adapter-task-text-v1","selectedSectionsFrozen":true,"refreshPolicy":"refresh-taskWikiRefs-and-fingerprints-only"},
  "taskWikiRefs": [{"taskId":"T1","taskTitle":"Implement boundary","taskFingerprint":"${SHA_C}"}],
  "wikiNotes": [
    {"sourceId":"project","role":"project","path":"Notes/runtime.md","wikiId":"runtime","type":"constraint","constraintStrength":"hard","summary":"Runtime boundary.","contentHash":"sha256:${SHA_A}","bindingDigest":"${SHA_B}","destination":{"kind":"task-bound","reason":"T1 owns it.","tasks":["T1"]}},
    {"sourceId":"project","role":"project","path":"Notes/soft.md","wikiId":"soft","type":"guide","constraintStrength":"soft","summary":"Must not reread.","contentHash":"sha256:${SHA_D}","bindingDigest":"${SHA_B}","destination":{"kind":"global","reason":"Soft context."}}
  ],
  "requiredSkills": [
    {"sourceId":"project","role":"project","path":"Skills/review.md","wikiId":"review-skill","type":"guide","summary":"Review contract.","contentHash":"sha256:${SHA_D}","bindingDigest":"${SHA_B}","skillProvider":"claude-code-project","skillName":"review-runtime","skillVersion":"1.0.0","skillContractHash":"sha256:${SHA_A}","skillTriggers":["runtime review"],"discoveryState":"discoverable","requiredFor":["reviewer"],"destination":{"kind":"task-bound","reason":"T1 review.","tasks":["T1"]}}
  ],
  "caveats": [], "maintenanceWarnings": []
}
JSON

FAKE="$TMP/fake-obsidian-mcp.py"
cat > "$FAKE" <<'PY'
import json, os, sys

SHA_A = 'a' * 64
SHA_B = 'b' * 64
SHA_D = 'd' * 64
notes = {
  'Notes/runtime.md': {'sourceId': 'project', 'role': 'project', 'path': 'Notes/runtime.md', 'wikiId': 'runtime', 'type': 'constraint', 'constraintStrength': 'hard', 'summary': 'Runtime boundary.', 'contentHash': 'sha256:' + SHA_A, 'bindingDigest': SHA_B, 'content': 'AUTHORITATIVE RUNTIME NOTE'},
  'Notes/transaction.md': {'sourceId': 'project', 'role': 'project', 'path': 'Notes/transaction.md', 'wikiId': 'transaction', 'type': 'constraint', 'constraintStrength': 'hard', 'summary': 'Transaction dependency.', 'contentHash': 'sha256:' + SHA_D, 'bindingDigest': SHA_B, 'content': 'AUTHORITATIVE DEPENDENCY NOTE'},
  'Skills/review.md': {'sourceId': 'project', 'role': 'project', 'path': 'Skills/review.md', 'wikiId': 'review-skill', 'type': 'guide', 'summary': 'Review contract.', 'skillRoles': ['reviewer'], 'skillProvider': 'claude-code-project', 'skillName': 'review-runtime', 'skillVersion': '1.0.0', 'skillContractHash': 'sha256:' + SHA_A, 'skillTriggers': ['runtime review'], 'discoveryState': 'discoverable', 'contentHash': 'sha256:' + SHA_D, 'bindingDigest': SHA_B, 'content': 'AUTHORITATIVE REVIEW SKILL'},
}
request = json.load(sys.stdin)
subcommand = sys.argv[1]
if subcommand in ('read-notes', 'read-notes-by-wiki-ids'):
  paths = request.get('paths')
  if paths is None:
    requested_ids = request['wikiIds']
    paths = [path for path, note in notes.items() if note['wikiId'] in requested_ids]
  if os.environ.get('FAKE_DRIFT_PATH') in paths:
    notes[os.environ['FAKE_DRIFT_PATH']] = {**notes[os.environ['FAKE_DRIFT_PATH']], 'contentHash': 'sha256:' + 'e' * 64}
  result_notes = [notes[path] for path in paths]
  if os.environ.get('FAKE_SOFT_CLOSURE'):
    result_notes = [{**note, 'constraintStrength': 'soft'} if note['wikiId'] == 'transaction' else note for note in result_notes]
  if os.environ.get('FAKE_PATH_DRIFT'):
    result_notes = [{**note, 'path': 'Notes/moved-runtime.md'} if note['wikiId'] == 'runtime' else note for note in result_notes]
  if os.environ.get('FAKE_ROLE_DRIFT'):
    result_notes = [{**note, 'skillRoles': ['implementer', 'reviewer']} if note['wikiId'] == 'review-skill' else note for note in result_notes]
  if os.environ.get('FAKE_SKILL_CONTRACT_DRIFT'):
    result_notes = [{**note, 'skillContractHash': 'sha256:' + 'f' * 64} if note['wikiId'] == 'review-skill' else note for note in result_notes]
  print(json.dumps({'notes': result_notes, 'snapshotHash': 'sha256:' + SHA_A}))
elif subcommand == 'graph-neighbors':
  graph = {'runtime': [{'type': 'depends_on', 'wikiId': 'transaction', 'path': 'Notes/transaction.md'}], 'review-skill': []}
  print(json.dumps({'neighbors': {wiki_id: graph.get(wiki_id, []) for wiki_id in request['wikiIds']}}))
else:
  raise SystemExit('unexpected subcommand: ' + subcommand)
PY

if command -v cygpath >/dev/null 2>&1; then FAKE_ARG="$(cygpath -m "$FAKE")"; else FAKE_ARG="$FAKE"; fi
FAKE_CMD="python3 $FAKE_ARG"

run_bind() {
  python3 "$MATERIALIZE" "$CONTEXT" --task-id T1 --role "$1" --project-root "$PROJECT" --strict --execution-ready --obsidian-wiki-cmd "$FAKE_CMD"
}

# Schema-v6 Bind is per ticket: global routing must not bypass --task-id.
if python3 "$MATERIALIZE" "$CONTEXT" --role implementer --project-root "$PROJECT" --strict --execution-ready --obsidian-wiki-cmd "$FAKE_CMD" >/dev/null 2>"$TMP/task.err"; then
  printf 'schema-v6 materialization without --task-id must fail\n' >&2
  exit 1
fi
grep -Fq 'requires --task-id' "$TMP/task.err" || { cat "$TMP/task.err" >&2; exit 1; }

# Implementer receives only the hard routed Note plus its direct dependency.
OUT="$(run_bind implementer)"
grep -Fq 'AUTHORITATIVE RUNTIME NOTE' <<<"$OUT" || { printf 'implementer did not receive routed hard Note\n' >&2; exit 1; }
grep -Fq 'AUTHORITATIVE DEPENDENCY NOTE' <<<"$OUT" || { printf 'implementer did not receive depends_on closure\n' >&2; exit 1; }
grep -Fq 'depends-on closure of `runtime`' <<<"$OUT" || { printf 'closure provenance missing\n' >&2; exit 1; }
OUT="$(FAKE_SOFT_CLOSURE=1 run_bind implementer)"
grep -Fq 'AUTHORITATIVE DEPENDENCY NOTE' <<<"$OUT" || { printf 'implementer did not receive soft direct depends_on Note\n' >&2; exit 1; }
if grep -Fq 'AUTHORITATIVE REVIEW SKILL' <<<"$OUT" || grep -Fq 'Must not reread' <<<"$OUT"; then
  printf 'implementer received a role-excluded or soft Note\n' >&2
  exit 1
fi

# Reviewer receives the reviewer-required Skill Card and its role claim is checked against runtime metadata.
OUT="$(run_bind reviewer)"
grep -Fq 'AUTHORITATIVE REVIEW SKILL' <<<"$OUT" || { printf 'reviewer did not receive required Skill Card\n' >&2; exit 1; }
grep -Fq 'MUST invoke project skill `review-runtime`' <<<"$OUT" || { printf 'reviewer was not told to invoke the executable skill pack\n' >&2; exit 1; }

# Any bound direct Note/Skill content drift stops materialization.
if FAKE_DRIFT_PATH='Skills/review.md' run_bind reviewer >/dev/null 2>"$TMP/drift.err"; then
  printf 'drifted required Skill Card must stop reviewer materialization\n' >&2
  exit 1
fi
grep -Fq 'content drift' "$TMP/drift.err" || { cat "$TMP/drift.err" >&2; exit 1; }

# The carried path is part of the binding identity even though the MCP resolves by stable wiki ID.
if FAKE_PATH_DRIFT=1 run_bind implementer >/dev/null 2>"$TMP/path.err"; then
  printf 'moved bound Note must stop materialization\n' >&2
  exit 1
fi
grep -Fq 'path drift' "$TMP/path.err" || { cat "$TMP/path.err" >&2; exit 1; }

# Required Skill Card role widening is policy drift, not an execution-time permission grant.
if FAKE_ROLE_DRIFT=1 run_bind reviewer >/dev/null 2>"$TMP/role.err"; then
  printf 'role-drifted required Skill Card must stop reviewer materialization\n' >&2
  exit 1
fi
grep -Fq 'role policy drift' "$TMP/role.err" || { cat "$TMP/role.err" >&2; exit 1; }

if FAKE_SKILL_CONTRACT_DRIFT=1 run_bind reviewer >/dev/null 2>"$TMP/skill-contract.err"; then
  printf 'contract-drifted required Skill Card must stop reviewer materialization\n' >&2
  exit 1
fi
grep -Fq 'skillContractHash drift' "$TMP/skill-contract.err" || { cat "$TMP/skill-contract.err" >&2; exit 1; }

printf 'obsidian wiki Bind smoke passed\n'
