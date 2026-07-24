#!/usr/bin/env bash
set -euo pipefail

# Exercises the public review handoff seam: reuse implementation readiness, materialize once for
# the reviewer role, and give both independent review axes the same all-or-nothing file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
READINESS="$ROOT/scripts/wiki_readiness.py"
RENDER="$ROOT/scripts/wiki_context_render.py"
JOURNAL_CLI="$ROOT/scripts/wiki_candidate_journal.py"
SKILL="$ROOT/skills/wiki-readiness/SKILL.md"
HOST_TEST="$ROOT/tests/host-conventions-smoke.sh"
source "${SCRIPT_DIR}/_windows-compat.bash"

TMP="$(portable_tmpdir)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
CTX_DIR="$PROJECT/.adapter/context"
mkdir -p "$CTX_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }
deny() { ! grep -Fq "$2" "$1" || fail "$1 must not contain: $2"; }

SHA_A="$(printf 'a%.0s' {1..64})"
SHA_B="$(printf 'b%.0s' {1..64})"
SHA_C="$(printf 'c%.0s' {1..64})"
SHA_D="$(printf 'd%.0s' {1..64})"

ROSTER="$CTX_DIR/reviewer.ticket-roster.json"
CONTEXT="$CTX_DIR/reviewer.wiki-context.json"
RECEIPT="$CTX_DIR/reviewer.wiki-readiness.json"
HANDOFF="$CTX_DIR/reviewer.wiki-review.md"
CALL_LOG="$TMP/obsidian-calls.log"

cat > "$ROSTER" <<'JSON'
{
  "featureSlug": "reviewer",
  "ticketSource": "github-issues",
  "tickets": [
    {
      "taskId": "21",
      "taskTitle": "Inject reviewer Wiki context",
      "text": "Review the current implementation against the routed constraints."
    }
  ]
}
JSON

cat > "$CONTEXT" <<JSON
{
  "schemaVersion": 6,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "featureSlug": "reviewer",
  "ticketSource": "github-issues",
  "snapshotHash": "sha256:${SHA_A}",
  "wikiBindings": [
    {"sourceId":"project","role":"project","bindingDigest":"${SHA_B}"}
  ],
  "taskRouting": {
    "status": "confirmed",
    "ticketRosterFormat": "grill-adapter-ticket-roster-v1",
    "fingerprintAlgorithm": "sha256:grill-adapter-task-text-v1",
    "selectedSectionsFrozen": true,
    "refreshPolicy": "refresh-taskWikiRefs-and-fingerprints-only"
  },
  "taskWikiRefs": [],
  "wikiNotes": [
    {
      "sourceId":"project",
      "role":"project",
      "path":"Notes/review-boundary.md",
      "wikiId":"review-boundary",
      "type":"constraint",
      "constraintStrength":"hard",
      "summary":"Review the transaction boundary.",
      "contentHash":"sha256:${SHA_A}",
      "bindingDigest":"${SHA_B}",
      "destination":{"kind":"task-bound","reason":"Issue 21 changes review.","tasks":["21"]}
    },
    {
      "sourceId":"project",
      "role":"project",
      "path":"Notes/review-background.md",
      "wikiId":"review-background",
      "type":"guide",
      "constraintStrength":"soft",
      "summary":"UNVERIFIED SOFT SUMMARY MUST NOT REACH REVIEWERS",
      "contentHash":"sha256:${SHA_C}",
      "bindingDigest":"${SHA_B}",
      "destination":{"kind":"task-bound","reason":"Background only.","tasks":["21"]}
    }
  ],
  "requiredSkills": [
    {
      "sourceId":"project",
      "role":"project",
      "path":"Skills/review-runtime.md",
      "wikiId":"review-runtime-card",
      "type":"guide",
      "summary":"Run the verified review procedure.",
      "contentHash":"sha256:${SHA_D}",
      "bindingDigest":"${SHA_B}",
      "skillProvider":"claude-code-project",
      "skillName":"review-runtime",
      "skillVersion":"1.0.0",
      "skillContractHash":"sha256:${SHA_C}",
      "skillTriggers":["runtime review"],
      "discoveryState":"discoverable",
      "requiredFor":["reviewer"],
      "destination":{"kind":"task-bound","reason":"Issue 21 requires reviewer checks.","tasks":["21"]}
    },
    {
      "sourceId":"project",
      "role":"project",
      "path":"Skills/implementation-only.md",
      "wikiId":"implementation-only-card",
      "type":"guide",
      "summary":"Must stay out of review.",
      "contentHash":"sha256:${SHA_C}",
      "bindingDigest":"${SHA_B}",
      "skillProvider":"claude-code-project",
      "skillName":"implementation-only",
      "skillVersion":"1.0.0",
      "skillContractHash":"sha256:${SHA_C}",
      "skillTriggers":["implementation"],
      "discoveryState":"discoverable",
      "requiredFor":["implementer"],
      "destination":{"kind":"task-bound","reason":"Implementation only.","tasks":["21"]}
    }
  ],
  "caveats": [],
  "maintenanceWarnings": []
}
JSON

python3 "$RENDER" "$CONTEXT" --finalize --strict --ticket-roster "$ROSTER" >/dev/null
python3 - "$CONTEXT" "$ROSTER" "$RECEIPT" <<'PY'
import json
import sys

context_path, roster_path, receipt_path = sys.argv[1:]
context = json.load(open(context_path, encoding="utf-8"))
roster = json.load(open(roster_path, encoding="utf-8"))
task_ref = context["taskWikiRefs"][0]
receipt = {
    "schemaVersion": 1,
    "kind": "grill-adapter.wiki-readiness",
    "generatedBy": "grill-adapter",
    "featureSlug": "reviewer",
    "ticketSource": "github-issues",
    "rosterFile": "reviewer.ticket-roster.json",
    "tasks": [{
        "taskId": "21",
        "taskTitle": roster["tickets"][0]["taskTitle"],
        "taskFingerprint": task_ref["taskFingerprint"],
        "status": "ready",
        "contextDisposition": "materialized",
        "reason": "Implementer constraints materialized successfully.",
        "contextFile": "reviewer.wiki-context.json",
    }],
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2)
    handle.write("\n")
PY

FAKE="$TMP/fake-obsidian.py"
cat > "$FAKE" <<'PY'
import json
import os
import sys

with open(os.environ["FAKE_CALL_LOG"], "a", encoding="utf-8") as log:
    log.write(sys.argv[1] + "\n")
if os.environ.get("FAKE_FAIL"):
    print("PARTIAL UNVERIFIED WIKI CONTENT")
    raise SystemExit(7)

sha_a = "a" * 64
sha_b = "b" * 64
sha_c = "c" * 64
sha_d = "d" * 64
notes = {
    "review-boundary": {
        "sourceId": "project",
        "role": "project",
        "path": "Notes/review-boundary.md",
        "wikiId": "review-boundary",
        "type": "constraint",
        "constraintStrength": "hard",
        "summary": "Review the transaction boundary.",
        "contentHash": "sha256:" + sha_a,
        "bindingDigest": sha_b,
        "content": "AUTHORITATIVE REVIEW BOUNDARY",
    },
    "review-runtime-card": {
        "sourceId": "project",
        "role": "project",
        "path": "Skills/review-runtime.md",
        "wikiId": "review-runtime-card",
        "type": "guide",
        "summary": "Run the verified review procedure.",
        "contentHash": "sha256:" + sha_d,
        "bindingDigest": sha_b,
        "skillRoles": ["reviewer"],
        "skillProvider": "claude-code-project",
        "skillName": "review-runtime",
        "skillVersion": "1.0.0",
        "skillContractHash": "sha256:" + sha_c,
        "skillTriggers": ["runtime review"],
        "discoveryState": "discoverable",
        "content": "AUTHORITATIVE REVIEW SKILL CARD",
    },
}
request = json.load(sys.stdin)
if sys.argv[1] == "read-notes-by-wiki-ids":
    print(json.dumps({
        "notes": [notes[wiki_id] for wiki_id in request["wikiIds"]],
        "snapshotHash": "sha256:" + sha_a,
    }))
elif sys.argv[1] == "graph-neighbors":
    print(json.dumps({"neighbors": {wiki_id: [] for wiki_id in request["wikiIds"]}}))
else:
    raise SystemExit("unexpected command")
PY
FAKE_CMD="python3 $FAKE"

# A healthy implementation receipt produces one reviewer-role handoff. Both review axes read this
# exact file; the handoff does not merge their responsibilities.
FAKE_CALL_LOG="$CALL_LOG" python3 "$READINESS" review-handoff \
  --receipt "$RECEIPT" \
  --task-id 21 \
  --project-root "$PROJECT" \
  --handoff "$HANDOFF" \
  --obsidian-wiki-cmd "$FAKE_CMD"
need "$HANDOFF" "Status: ready"
need "$HANDOFF" "AUTHORITATIVE REVIEW BOUNDARY"
need "$HANDOFF" "AUTHORITATIVE REVIEW SKILL CARD"
need "$HANDOFF" 'MUST invoke project skill `review-runtime`'
need "$HANDOFF" "Standards"
need "$HANDOFF" "Spec"
need "$HANDOFF" "same read-only context"
deny "$HANDOFF" "implementation-only-card"
deny "$HANDOFF" "UNVERIFIED SOFT SUMMARY"

# Two isolated consumers read the same handoff path and retain independent output shapes. The
# handoff remains byte-identical, then the normal post-review Capture lifecycle reconciles a
# review-stage candidate without touching Wiki content.
HANDOFF_BEFORE="$(sha256_file "$HANDOFF")"
STANDARDS_RESULT="$TMP/standards-review.json"
SPEC_RESULT="$TMP/spec-review.json"
consume_review_axis() {
  python3 - "$HANDOFF" "$1" "$2" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

handoff_path = Path(sys.argv[1])
axis = sys.argv[2]
output_path = Path(sys.argv[3])
text = handoff_path.read_text(encoding="utf-8")
assert "AUTHORITATIVE REVIEW BOUNDARY" in text
assert "MUST invoke project skill `review-runtime`" in text
output_path.write_text(
    json.dumps(
        {
            "axis": axis,
            "handoffPath": str(handoff_path),
            "handoffSha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "findings": [],
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}
consume_review_axis Standards "$STANDARDS_RESULT" &
STANDARDS_PID=$!
consume_review_axis Spec "$SPEC_RESULT" &
SPEC_PID=$!
wait "$STANDARDS_PID"
wait "$SPEC_PID"
python3 - "$STANDARDS_RESULT" "$SPEC_RESULT" <<'PY'
import json
import sys

standards = json.load(open(sys.argv[1], encoding="utf-8"))
spec = json.load(open(sys.argv[2], encoding="utf-8"))
assert standards["axis"] == "Standards"
assert spec["axis"] == "Spec"
assert standards["handoffPath"] == spec["handoffPath"]
assert standards["handoffSha256"] == spec["handoffSha256"]
assert standards["findings"] == []
assert spec["findings"] == []
PY
HANDOFF_AFTER="$(sha256_file "$HANDOFF")"
[[ "$HANDOFF_BEFORE" == "$HANDOFF_AFTER" ]] || fail "review consumers mutated the shared handoff"

CAPTURE_JOURNAL="$CTX_DIR/reviewer.wiki-candidates.jsonl"
python3 "$JOURNAL_CLI" append \
  --journal "$CAPTURE_JOURNAL" \
  --feature-slug reviewer \
  --event-id review-complete \
  --candidate-id reviewer-handoff-contract \
  --stage review \
  --candidate-type wiki_note \
  --kind convention \
  --claim "Both review axes consume one verified read-only handoff." \
  --why "Capture evaluates durable knowledge only after Standards and Spec finish." \
  --source-ref "issue:#21" >/dev/null
python3 "$JOURNAL_CLI" outcome \
  --journal "$CAPTURE_JOURNAL" \
  --feature-slug reviewer \
  --event-id capture-reviewed \
  --candidate-id reviewer-handoff-contract \
  --status skipped \
  --reason "The host conventions already capture this reviewed behavior." >/dev/null
python3 "$JOURNAL_CLI" fold \
  --journal "$CAPTURE_JOURNAL" \
  --feature-slug reviewer |
  python3 -c '
import json
import sys

folded = json.load(sys.stdin)
assert folded["eventCount"] == 2
assert folded["counts"]["pending"] == 0
assert folded["counts"]["skipped"] == 1
'

# Independent review with no task/receipt is fail-open and performs no Wiki read.
UNKNOWN="$CTX_DIR/unknown.wiki-review.md"
CALLS_BEFORE="$(wc -l < "$CALL_LOG")"
FAKE_CALL_LOG="$CALL_LOG" python3 "$READINESS" review-handoff \
  --project-root "$PROJECT" \
  --handoff "$UNKNOWN" \
  --obsidian-wiki-cmd "$FAKE_CMD"
need "$UNKNOWN" "Status: unknown"
need "$UNKNOWN" "No verified Wiki reviewer context"
[[ "$(wc -l < "$CALL_LOG")" == "$CALLS_BEFORE" ]] || fail "unknown review must not access Wiki"

# Existing non-ready readiness states are reused as no-context review results. Review never performs
# late research or calls the materializer for these states.
for status in no-relevant disabled broken; do
  state_receipt="$CTX_DIR/reviewer.${status}.wiki-readiness.json"
  state_handoff="$CTX_DIR/reviewer.${status}.wiki-review.md"
  python3 "$READINESS" record \
    --receipt "$state_receipt" \
    --roster "$ROSTER" \
    --task-id 21 \
    --status "$status" \
    --reason "No verified Wiki context is available." >/dev/null
  calls_before="$(wc -l < "$CALL_LOG")"
  FAKE_CALL_LOG="$CALL_LOG" python3 "$READINESS" review-handoff \
    --receipt "$state_receipt" \
    --task-id 21 \
    --project-root "$PROJECT" \
    --handoff "$state_handoff" \
    --obsidian-wiki-cmd "$FAKE_CMD"
  need "$state_handoff" "Status: $status"
  need "$state_handoff" "No verified Wiki reviewer context"
  deny "$state_handoff" "AUTHORITATIVE"
  [[ "$(wc -l < "$CALL_LOG")" == "$calls_before" ]] || fail "$status review must not access Wiki"
done

# A receipt outside the current project's context directory cannot become reviewer input even when
# its internal references are self-consistent.
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
cp "$ROSTER" "$OUTSIDE/reviewer.ticket-roster.json"
cp "$CONTEXT" "$OUTSIDE/reviewer.wiki-context.json"
cp "$RECEIPT" "$OUTSIDE/reviewer.wiki-readiness.json"
CALLS_BEFORE="$(wc -l < "$CALL_LOG")"
FAKE_CALL_LOG="$CALL_LOG" python3 "$READINESS" review-handoff \
  --receipt "$OUTSIDE/reviewer.wiki-readiness.json" \
  --task-id 21 \
  --project-root "$PROJECT" \
  --handoff "$CTX_DIR/outside.wiki-review.md" \
  --obsidian-wiki-cmd "$FAKE_CMD"
need "$CTX_DIR/outside.wiki-review.md" "Status: broken"
deny "$CTX_DIR/outside.wiki-review.md" "AUTHORITATIVE"
[[ "$(wc -l < "$CALL_LOG")" == "$CALLS_BEFORE" ]] || fail "out-of-project receipt must not access Wiki"

# Ticket fingerprint drift invalidates reviewer reuse before any Wiki read.
cp "$ROSTER" "$TMP/roster.before-drift.json"
python3 - "$ROSTER" <<'PY'
import json
import sys

path = sys.argv[1]
roster = json.load(open(path, encoding="utf-8"))
roster["tickets"][0]["text"] += "\nChanged after implementation readiness."
with open(path, "w", encoding="utf-8") as handle:
    json.dump(roster, handle, indent=2)
    handle.write("\n")
PY
CALLS_BEFORE="$(wc -l < "$CALL_LOG")"
FAKE_CALL_LOG="$CALL_LOG" python3 "$READINESS" review-handoff \
  --receipt "$RECEIPT" \
  --task-id 21 \
  --project-root "$PROJECT" \
  --handoff "$CTX_DIR/drift.wiki-review.md" \
  --obsidian-wiki-cmd "$FAKE_CMD"
need "$CTX_DIR/drift.wiki-review.md" "Status: broken"
deny "$CTX_DIR/drift.wiki-review.md" "AUTHORITATIVE"
[[ "$(wc -l < "$CALL_LOG")" == "$CALLS_BEFORE" ]] || fail "fingerprint drift must stop before Wiki access"
mv "$TMP/roster.before-drift.json" "$ROSTER"

# Any reviewer materialization failure replaces an old handoff with a caveat-only result, returns
# success so code-review continues, and never leaks partial subprocess stdout.
printf 'STALE VERIFIED WIKI CONTENT\n' > "$HANDOFF"
FAKE_CALL_LOG="$CALL_LOG" FAKE_FAIL=1 python3 "$READINESS" review-handoff \
  --receipt "$RECEIPT" \
  --task-id 21 \
  --project-root "$PROJECT" \
  --handoff "$HANDOFF" \
  --obsidian-wiki-cmd "$FAKE_CMD"
need "$HANDOFF" "Status: materialize-failed"
need "$HANDOFF" "non-blocking caveat"
deny "$HANDOFF" "STALE VERIFIED WIKI CONTENT"
deny "$HANDOFF" "PARTIAL UNVERIFIED WIKI CONTENT"
deny "$HANDOFF" "AUTHORITATIVE"

# The skill and installed host conventions keep review context before subagents, preserve the two
# axes, prohibit late research, and retain normal post-review Capture.
need "$SKILL" "review-handoff"
need "$SKILL" "before"
need "$SKILL" "Standards"
need "$SKILL" "Spec"
need "$SKILL" "late research"
bash "$HOST_TEST" "$ROOT"

printf 'wiki review context smoke passed\n'
