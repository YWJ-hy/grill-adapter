#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/grill_context_to_candidates.py: the grill -> wiki authoring bridge that
# converts CONTEXT.md glossary + docs/adr increments into update-wiki candidate rows (§9).

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

# --all mode: 2 glossary conventions + 1 ADR decision
OUT="$(python3 "$BRIDGE" "$T" --all --stdout)"
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
    for k in ("taskId","kind","claim","why","sourceRefs","carveOut"):
        assert k in d, f"missing candidate key {k}"
' || fail "candidate rows are not valid schema JSON"

# git-increment mode: only newly added glossary lines
( cd "$T" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
printf -- '- **Retry Budget** — max attempts before dead-letter.\n' >> "$T/CONTEXT.md"
OUT2="$(python3 "$BRIDGE" "$T" --stdout 2>/dev/null)"
N=$(printf '%s\n' "$OUT2" | grep -c 'Retry Budget' || true)
[[ "$N" == "1" ]] || fail "increment mode did not isolate the new term (got $N)"
printf '%s' "$OUT2" | grep -q 'Idempotency Key' && fail "increment mode leaked pre-existing terms"

# append mode writes to the sidecar
python3 "$BRIDGE" "$T" --all >/dev/null 2>&1 || fail "append mode failed"
[[ -f "$T/.wiki-candidates.jsonl" ]] || fail "append did not create .wiki-candidates.jsonl"

printf 'grill bridge smoke OK\n'
