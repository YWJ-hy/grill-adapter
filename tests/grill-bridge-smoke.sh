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

# --all mode: 2 glossary conventions + 1 ADR decision, all wrapped as journal events.
OUT="$(python3 "$BRIDGE" "$T" --feature-slug feature-a --all --stdout)"
CONV=$(printf '%s\n' "$OUT" | grep -c '"kind": "convention"' || true)
DEC=$(printf '%s\n' "$OUT" | grep -c '"kind": "decision"' || true)
[[ "$CONV" == "2" ]] || fail "expected 2 glossary conventions, got $CONV"
[[ "$DEC" == "1" ]] || fail "expected 1 ADR decision, got $DEC"
printf '%s' "$OUT" | grep -q 'Idempotency Key' || fail "glossary term not captured"
printf '%s' "$OUT" | grep -q 'transactional outbox' || fail "ADR decision not captured"
printf '%s' "$OUT" | grep -q '"origin": "grill-context"' || fail "origin marker missing"

# every line is valid JSON with the candidate schema
printf '%s\n' "$OUT" | python3 -c '
import json, sys
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
' || fail "candidate events are not valid schema JSON"

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
