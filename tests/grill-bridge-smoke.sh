#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/grill_context_to_candidates.py: the grill -> wiki authoring bridge that
# converts CONTEXT.md glossary + docs/adr increments into candidate journal events (§9).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
BRIDGE="$ROOT/scripts/grill_context_to_candidates.py"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/CONTEXT.md" <<'MD'
# Glossary
- **Idempotency Key** — a client token that dedupes retried writes.
- **Ledger Entry**: an append-only row.
MD
mkdir -p "$T/docs/adr"
cat > "$T/docs/adr/0001-outbox.md" <<'MD'
# 1. Use transactional outbox
## Context
Dual writes diverge on crash.
## Decision
Write events to an outbox in the same transaction.
## Consequences
At-least-once delivery.
MD

# --all mode: 2 glossary conventions + 1 ADR execution projection, all wrapped as
# journal events. The bridge carries authority identity, never a second decision body.
OUT="$(python3 "$BRIDGE" "$T" --feature-slug feature-a --all --stdout)"
CONV=$(printf '%s\n' "$OUT" | grep -c '"kind": "convention"' || true)
PROJECTION=$(printf '%s\n' "$OUT" | grep -c '"kind": "adr_execution_projection"' || true)
[[ "$CONV" == "2" ]] || fail "expected 2 glossary conventions, got $CONV"
[[ "$PROJECTION" == "1" ]] || fail "expected 1 ADR execution projection, got $PROJECTION"
printf '%s' "$OUT" | grep -q 'Idempotency Key' || fail "glossary term not captured"
printf '%s' "$OUT" | grep -q '"origin": "grill-context"' || fail "origin marker missing"
if printf '%s' "$OUT" | grep -Eq 'Dual writes diverge|Write events to an outbox|At-least-once delivery'; then
  fail "ADR projection candidate copied authoritative ADR decision content"
fi

# every line is valid JSON with the candidate schema
printf '%s\n' "$OUT" | python3 -c '
import hashlib, json, pathlib, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    for k in ("schemaVersion","eventType","eventId","featureSlug","candidateId","stage","candidateType","taskId","kind","claim","why","sourceRefs","carveOut"):
        assert k in d, f"missing candidate key {k}"
    assert d["schemaVersion"] == 1
    assert d["eventType"] == "candidate"
    assert d["featureSlug"] == "feature-a"
    assert d["stage"] == "capture"
    assert d["candidateType"] == "wiki_note"
    if d["kind"] == "adr_execution_projection":
        projection = d["adrProjection"]
        assert projection["authorityType"] == "project-adr"
        assert projection["projectionType"] == "execution-constraints"
        assert projection["sourcePath"] == "docs/adr/0001-outbox.md"
        assert projection["targetScope"] == "project"
        assert projection["sourceId"].startswith("project-adr:")
        expected = "sha256:" + hashlib.sha256(
            pathlib.Path("'"$T"'/docs/adr/0001-outbox.md").read_bytes()
        ).hexdigest()
        assert projection["sourceContentHash"] == expected
        assert d["candidateId"].endswith(projection["sourceId"].split(":")[1][:24])
' || fail "candidate events are not valid schema JSON"

# The ADR source identity is stable across revisions while its content identity changes.
FIRST_PROJECTION="$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
print(next(json.dumps(event, sort_keys=True) for event in map(json.loads, sys.stdin) if event["kind"] == "adr_execution_projection"))
')"
ADR_EVENT="$T/adr-projection-candidate.json"
printf '%s\n' "$FIRST_PROJECTION" > "$ADR_EVENT"
EMPTY_CONSTRAINTS="$T/empty-constraints.md"
: > "$EMPTY_CONSTRAINTS"
EMPTY_RESULT="$(python3 "$ROOT/scripts/wiki_adr_projection.py" \
  --candidate "$ADR_EVENT" --constraints "$EMPTY_CONSTRAINTS" \
  --wiki-id project/adr/outbox --title 'Transactional outbox')"
printf '%s\n' "$EMPTY_RESULT" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result == {
    "status": "skipped",
    "reason": "Authoritative ADR has no durable execution constraint; no projection created.",
}
' || fail "empty ADR execution constraints did not produce an explicit skip"
CONSTRAINTS="$T/constraints.md"
printf '%s\n' \
  '- Persist the domain change and its outbox event in the same transaction.' \
  '- Consumers must tolerate at-least-once delivery.' > "$CONSTRAINTS"
RENDERED="$(python3 "$ROOT/scripts/wiki_adr_projection.py" \
  --candidate "$ADR_EVENT" --constraints "$CONSTRAINTS" \
  --wiki-id project/adr/outbox --title 'Transactional outbox')"
printf '%s' "$RENDERED" | grep -q 'adr_source_id: project-adr:' \
  || fail "rendered ADR projection omitted its stable authority identity"
printf '%s' "$RENDERED" | grep -q 'Derived projection' \
  || fail "rendered ADR projection did not declare itself derived"
printf '%s' "$RENDERED" | grep -q 'Persist the domain change' \
  || fail "rendered ADR projection omitted reviewed execution constraints"
if printf '%s' "$RENDERED" | grep -q 'Dual writes diverge on crash'; then
  fail "rendered ADR projection copied authoritative Context prose"
fi

# A stripped generic Note receipt cannot complete an ADR projection candidate. The applied
# receipt must carry the exact authority identity returned by the write boundary.
ADR_JOURNAL="$T/.adapter/context/adr-receipt.wiki-candidates.jsonl"
mkdir -p "$(dirname "$ADR_JOURNAL")"
cp "$ADR_EVENT" "$ADR_JOURNAL"
ADR_CANDIDATE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidateId"])' "$ADR_EVENT")"
if python3 "$ROOT/scripts/wiki_candidate_journal.py" outcome \
  --journal "$ADR_JOURNAL" --feature-slug feature-a \
  --event-id stripped-receipt --candidate-id "$ADR_CANDIDATE_ID" \
  --status kept --reason 'Generic Shared write stripped the ADR markers.' \
  --write-state applied --operation create --source-id shared-wiki \
  --repository-ref shared-wiki --binding-digest "$(printf '3%.0s' {1..64})" \
  --wiki-id shared/outbox --path Shared/outbox.md \
  --after-hash "sha256:$(printf '4%.0s' {1..64})" >/dev/null 2>&1; then
  fail "ADR candidate accepted an applied receipt with stripped authority identity"
fi
python3 "$ROOT/scripts/wiki_candidate_journal.py" outcome \
  --journal "$ADR_JOURNAL" --feature-slug feature-a \
  --event-id bound-receipt --candidate-id "$ADR_CANDIDATE_ID" \
  --status kept --reason 'Project projection applied with matching authority identity.' \
  --write-state applied --operation create --source-id project-wiki \
  --repository-ref project-wiki --binding-digest "$(printf '3%.0s' {1..64})" \
  --wiki-id project/adr/outbox --path Projects/example/outbox.md \
  --after-hash "sha256:$(printf '4%.0s' {1..64})" \
  --adr-authority-type project-adr --adr-projection-type execution-constraints \
  --adr-source-id "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["adrProjection"]["sourceId"])' "$ADR_EVENT")" \
  --adr-source-path docs/adr/0001-outbox.md \
  --adr-source-content-hash "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["adrProjection"]["sourceContentHash"])' "$ADR_EVENT")" \
  --adr-target-scope project >/dev/null \
  || fail "ADR candidate rejected its matching applied authority receipt"

printf '\nAdditional rationale that must remain authoritative here.\n' >> "$T/docs/adr/0001-outbox.md"
SECOND_OUT="$(python3 "$BRIDGE" "$T" --feature-slug feature-a --all --stdout)"
printf '%s\n%s\n' "$FIRST_PROJECTION" "$SECOND_OUT" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
first = events[0]
second = next(event for event in events[1:] if event["kind"] == "adr_execution_projection")
assert first["candidateId"] == second["candidateId"]
assert first["adrProjection"]["sourceId"] == second["adrProjection"]["sourceId"]
assert first["adrProjection"]["sourceContentHash"] != second["adrProjection"]["sourceContentHash"]
' || fail "ADR source identity did not remain stable across a content revision"

# Ordinary non-ADR decision candidates keep the existing journal contract.
ORDINARY="$T/.adapter/context/ordinary-decision.wiki-candidates.jsonl"
python3 "$ROOT/scripts/wiki_candidate_journal.py" append \
  --journal "$ORDINARY" --feature-slug ordinary-decision \
  --event-id ordinary-event --candidate-id ordinary-candidate \
  --stage review --candidate-type wiki_note --kind decision \
  --claim 'Choose cursor pagination for the public API.' \
  --why 'The reviewed trade-off remains durable outside an ADR.' \
  --source-ref 'review:ordinary' >/dev/null \
  || fail "ordinary decision candidate regressed"
python3 "$ROOT/scripts/wiki_candidate_journal.py" validate \
  --journal "$ORDINARY" --feature-slug ordinary-decision >/dev/null \
  || fail "ordinary decision journal no longer validates"

# The Capture skill owns semantic extraction: no executable constraint is an explicit skip,
# projection ownership is project-only, and the rendered Note declares its authority identity.
grep -q 'Authoritative ADR has no durable execution constraint; no projection created.' \
  "$ROOT/skills/update-wiki/SKILL.md" \
  || fail "Capture does not explicitly skip ADRs without executable durable constraints"
grep -q 'Never neutralize this candidate into a Shared Source' \
  "$ROOT/skills/update-wiki/SKILL.md" \
  || fail "Capture does not keep ADR projections project-only"
for field in adr_source_id adr_source_path adr_source_content_hash; do
  grep -q "$field" "$ROOT/skills/update-wiki/references/content-templates.md" \
    || fail "ADR projection template is missing $field"
done

# Context-scoped ADR roots use the same normalized project-relative authority contract.
mkdir -p "$T/src/billing/docs/adr"
cp "$T/docs/adr/0001-outbox.md" "$T/src/billing/docs/adr/0002-billing.md"
NESTED_OUT="$(python3 "$BRIDGE" "$T" --feature-slug nested-adr \
  --adr-dir src/billing/docs/adr --all --stdout)"
printf '%s\n' "$NESTED_OUT" | python3 -c '
import json, sys
projection = next(
    event for event in map(json.loads, sys.stdin)
    if event["kind"] == "adr_execution_projection"
)
assert projection["adrProjection"]["sourcePath"] == "src/billing/docs/adr/0002-billing.md"
' || fail "context-scoped ADR source path did not validate"

# git-increment mode: only newly added glossary lines
( cd "$T" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
printf -- '- **Retry Budget** — max attempts before dead-letter.\n' >> "$T/CONTEXT.md"
OUT2="$(python3 "$BRIDGE" "$T" --feature-slug feature-a --stdout 2>/dev/null)"
N=$(printf '%s\n' "$OUT2" | grep -c 'Retry Budget' || true)
[[ "$N" == "1" ]] || fail "increment mode did not isolate the new term (got $N)"
printf '%s' "$OUT2" | grep -q 'Idempotency Key' && fail "increment mode leaked pre-existing terms"

# append mode writes one feature-scoped journal that validates through the shared helper.
python3 "$BRIDGE" "$T" --feature-slug feature-a --all >/dev/null 2>&1 || fail "append mode failed"
JOURNAL="$T/.adapter/context/feature-a.wiki-candidates.jsonl"
[[ -f "$JOURNAL" ]] || fail "append did not create the feature journal"
python3 "$ROOT/scripts/wiki_candidate_journal.py" validate \
  --journal "$JOURNAL" --feature-slug feature-a >/dev/null || fail "bridge journal did not validate"

# Replaying the same increment is an idempotent recovery no-op.
BEFORE="$(shasum -a 256 "$JOURNAL" | awk '{print $1}')"
python3 "$BRIDGE" "$T" --feature-slug feature-a --all >/dev/null 2>&1 \
  || fail "bridge could not resume after its candidates were already appended"
AFTER="$(shasum -a 256 "$JOURNAL" | awk '{print $1}')"
[[ "$BEFORE" == "$AFTER" ]] || fail "identical bridge replay mutated the journal"

# A stable bridge identity with different payload is a conflict, not an idempotent replay.
CONFLICT_JOURNAL="$T/.adapter/context/conflict.wiki-candidates.jsonl"
cp "$JOURNAL" "$CONFLICT_JOURNAL"
python3 - "$CONFLICT_JOURNAL" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
events[0]["claim"] += " conflicting edit"
path.write_text("".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events), encoding="utf-8")
PY
BEFORE="$(shasum -a 256 "$CONFLICT_JOURNAL" | awk '{print $1}')"
if python3 "$BRIDGE" "$T" --feature-slug feature-a --all --out "$CONFLICT_JOURNAL" >/dev/null 2>&1; then
  fail "bridge treated conflicting candidate content as an identical replay"
fi
AFTER="$(shasum -a 256 "$CONFLICT_JOURNAL" | awk '{print $1}')"
[[ "$BEFORE" == "$AFTER" ]] || fail "rejected bridge conflict mutated the journal"

printf 'grill bridge smoke OK\n'
