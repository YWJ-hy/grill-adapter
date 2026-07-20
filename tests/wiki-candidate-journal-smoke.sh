#!/usr/bin/env bash
set -euo pipefail

# Exercises the public candidate-journal CLI contract used by workflow skills.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
JOURNAL_CLI="$ROOT/scripts/wiki_candidate_journal.py"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
JOURNAL="$T/.adapter/context/feature-a.wiki-candidates.jsonl"

append_candidate() {
  python3 "$JOURNAL_CLI" append \
    --journal "$JOURNAL" \
    --feature-slug feature-a \
    --event-id "$1" \
    --candidate-id "$2" \
    --stage "$3" \
    --candidate-type "$4" \
    --kind "$5" \
    --claim "$6" \
    --why "$7" \
    --source-ref "$8"
}

# One feature journal accepts Wiki and Skill Card candidates from different workflow stages.
append_candidate evt-1 cand-wiki specification wiki_note contract \
  'Receipts retain the selected Note hashes.' \
  'Capture needs final evidence without losing the planning decision.' \
  'issue:#6' >/dev/null
append_candidate evt-2 cand-skill implementation skill_card skill_registration \
  'Use the receipt verifier during publish review.' \
  'The procedure is executable and role-specific.' \
  'src/publish.py' >/dev/null

# Public CLI output stays UTF-8 even when the inherited stdio encoding is ASCII.
UTF8_JOURNAL="$T/.adapter/context/utf8-feature.wiki-candidates.jsonl"
PYTHONIOENCODING=ascii python3 "$JOURNAL_CLI" append \
  --journal "$UTF8_JOURNAL" --feature-slug utf8-feature \
  --event-id utf8-event --candidate-id utf8-candidate --stage review \
  --candidate-type wiki_note --kind contract \
  --claim '候选日志保留生命周期证据。' --why '跨运行时输出必须稳定。' \
  --source-ref 'issue:#6' >/dev/null || fail "CLI failed after appending non-ASCII content"
UTF8_FOLD="$(PYTHONIOENCODING=ascii python3 "$JOURNAL_CLI" fold --journal "$UTF8_JOURNAL")"
printf '%s' "$UTF8_FOLD" | grep -q '候选日志' || fail "CLI did not emit UTF-8 journal content"

# Concurrent writers serialize through the journal lock without losing events.
CONCURRENT_JOURNAL="$T/.adapter/context/concurrent.wiki-candidates.jsonl"
PIDS=()
for i in $(seq 1 12); do
  python3 "$JOURNAL_CLI" append \
    --journal "$CONCURRENT_JOURNAL" --feature-slug concurrent \
    --event-id "parallel-event-$i" --candidate-id "parallel-candidate-$i" \
    --stage implementation --candidate-type wiki_note --kind gotcha \
    --claim "parallel claim $i" --why "parallel evidence $i" \
    --source-ref "task:$i" >/dev/null &
  PIDS+=("$!")
done
for pid in "${PIDS[@]}"; do
  wait "$pid" || fail "concurrent append failed"
done
CONCURRENT_FOLD="$(python3 "$JOURNAL_CLI" fold --journal "$CONCURRENT_JOURNAL")"
printf '%s' "$CONCURRENT_FOLD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["eventCount"] == 12
assert d["counts"]["pending"] == 12
' || fail "concurrent append lost or corrupted events"

FOLDED="$(python3 "$JOURNAL_CLI" fold --journal "$JOURNAL" --feature-slug feature-a)"
printf '%s' "$FOLDED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schemaVersion"] == 1
assert d["featureSlug"] == "feature-a"
assert d["eventCount"] == 2
assert d["counts"] == {"pending": 2, "superseded": 0, "kept": 0, "skipped": 0, "deferred": 0}
assert [item["candidateId"] for item in d["candidates"]] == ["cand-wiki", "cand-skill"]
assert d["candidates"][1]["candidateType"] == "skill_card"
' || fail "fold did not preserve pending Wiki and Skill Card candidates"

# Supersession is explicit and points to a previously appended replacement.
append_candidate evt-3 cand-replacement review wiki_note decision \
  'Receipts retain hashes and the effective binding digest.' \
  'Review found the binding identity is part of the durable contract.' \
  'review:#6' >/dev/null
python3 "$JOURNAL_CLI" supersede \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-4 \
  --candidate-id cand-wiki --by-candidate-id cand-replacement \
  --reason 'Review produced the final wording.' >/dev/null
python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-5 \
  --candidate-id cand-skill --status deferred \
  --reason 'The target pack does not exist yet.' >/dev/null
python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-6 \
  --candidate-id cand-skill --status kept \
  --reason 'The pack was scaffolded and is ready for Capture.' >/dev/null

python3 "$JOURNAL_CLI" validate --journal "$JOURNAL" --feature-slug feature-a >/dev/null
FOLDED="$(python3 "$JOURNAL_CLI" fold --journal "$JOURNAL" --feature-slug feature-a)"
printf '%s' "$FOLDED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by_id = {item["candidateId"]: item for item in d["candidates"]}
assert by_id["cand-wiki"]["status"] == "superseded"
assert by_id["cand-wiki"]["supersededBy"] == "cand-replacement"
assert by_id["cand-skill"]["status"] == "kept"
assert by_id["cand-replacement"]["status"] == "pending"
assert d["counts"]["pending"] == 1
assert d["counts"]["superseded"] == 1
assert d["counts"]["kept"] == 1
' || fail "fold did not apply supersede and outcome lifecycle events"

# Duplicate identities and illegal terminal transitions fail without changing the journal.
BEFORE="$(shasum -a 256 "$JOURNAL" | awk '{print $1}')"
if append_candidate evt-7 cand-replacement review wiki_note decision x y z >/dev/null 2>&1; then
  fail "duplicate candidateId was accepted"
fi
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-7 \
  --candidate-id cand-skill --status skipped --reason 'illegal rewrite' >/dev/null 2>&1; then
  fail "terminal candidate outcome was rewritten"
fi
AFTER="$(shasum -a 256 "$JOURNAL" | awk '{print $1}')"
[[ "$BEFORE" == "$AFTER" ]] || fail "rejected append mutated the journal"

# A valid final JSON object without its newline is treated as a truncated append.
TRUNCATED="$T/truncated.wiki-candidates.jsonl"
printf '%s' '{"schemaVersion":1,"eventId":"evt-x"}' > "$TRUNCATED"
if python3 "$JOURNAL_CLI" validate --journal "$TRUNCATED" >/dev/null 2>&1; then
  fail "truncated journal was accepted"
fi

# Explicitly validating a missing or empty journal must not look like a successful no-op.
if python3 "$JOURNAL_CLI" validate --journal "$T/missing.wiki-candidates.jsonl" >/dev/null 2>&1; then
  fail "missing journal was accepted"
fi
EMPTY="$T/empty.wiki-candidates.jsonl"
: > "$EMPTY"
if python3 "$JOURNAL_CLI" validate --journal "$EMPTY" >/dev/null 2>&1; then
  fail "empty journal was accepted"
fi

# Corrupt input fails before Capture and cannot be appended over.
CORRUPT="$T/corrupt.wiki-candidates.jsonl"
printf '%s\n' '{not-json}' > "$CORRUPT"
if python3 "$JOURNAL_CLI" fold --journal "$CORRUPT" >/dev/null 2>&1; then
  fail "corrupt journal was folded"
fi
if python3 "$JOURNAL_CLI" append \
  --journal "$CORRUPT" --feature-slug feature-a --candidate-id nope \
  --stage review --candidate-type wiki_note --kind gotcha \
  --claim x --why y --source-ref z >/dev/null 2>&1; then
  fail "append accepted a corrupt journal"
fi
[[ "$(wc -l < "$CORRUPT" | tr -d ' ')" == "1" ]] || fail "corrupt journal was mutated"

# Candidate type and kind cannot disagree about Note versus Skill Card routing.
TYPE_JOURNAL="$T/.adapter/context/type-check.wiki-candidates.jsonl"
if python3 "$JOURNAL_CLI" append \
  --journal "$TYPE_JOURNAL" --feature-slug type-check \
  --stage review --candidate-type skill_card --kind decision \
  --claim x --why y --source-ref z >/dev/null 2>&1; then
  fail "skill_card accepted a non-registration kind"
fi
if python3 "$JOURNAL_CLI" append \
  --journal "$TYPE_JOURNAL" --feature-slug type-check \
  --stage review --candidate-type wiki_note --kind skill_registration \
  --claim x --why y --source-ref z >/dev/null 2>&1; then
  fail "wiki_note accepted skill_registration kind"
fi

printf 'wiki candidate journal smoke OK\n'
