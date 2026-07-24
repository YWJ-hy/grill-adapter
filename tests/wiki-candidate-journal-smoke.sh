#!/usr/bin/env bash
set -euo pipefail

# Exercises the public candidate-journal CLI contract used by workflow skills.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
JOURNAL_CLI="$ROOT/scripts/wiki_candidate_journal.py"
source "${SCRIPT_DIR}/_windows-compat.bash"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

T="$(portable_tmpdir)"; trap 'rm -rf "$T"' EXIT
JOURNAL="$T/.adapter/context/feature-a.wiki-candidates.jsonl"

append_candidate() {
  ARGS=(
    python3 "$JOURNAL_CLI" append
    --journal "$JOURNAL"
    --feature-slug feature-a
    --event-id "$1"
    --candidate-id "$2"
    --stage "$3"
    --candidate-type "$4"
    --kind "$5"
    --claim "$6"
    --why "$7"
    --source-ref "$8"
  )
  if [[ "$4" == "skill_card" ]]; then
    ARGS+=(
      --skill-provider claude-code-project
      --skill-name receipt-verifier
      --skill-version 1.0.0
      --skill-contract-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      --skill-role reviewer
      --skill-trigger "publish review"
      --skill-summary "Verify applied Note receipts before publication."
    )
  fi
  "${ARGS[@]}"
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
append_candidate evt-capture cand-capture review wiki_note contract \
  'Capture receipts retain the exact staged Note identity.' \
  'Publishing must group and verify only the Note writes accepted by Capture.' \
  'issue:#8' >/dev/null

for invalid_identity in \
  '--skill-name ../outside --skill-version 1.0.0' \
  '--skill-name receipt-verifier --skill-version latest' \
  '--skill-name receipt-verifier --skill-version 1.2'; do
  if python3 "$JOURNAL_CLI" append \
    --journal "$T/.adapter/context/invalid-skill.wiki-candidates.jsonl" \
    --feature-slug invalid-skill --event-id invalid-event --candidate-id invalid-card \
    --stage implementation --candidate-type skill_card --kind skill_registration \
    --claim 'Invalid skill registration.' --why 'The identity must fail closed.' \
    --source-ref 'test:invalid' --skill-provider claude-code-project \
    $invalid_identity \
    --skill-contract-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --skill-role reviewer --skill-trigger review --skill-summary 'Invalid identity.' \
    >/dev/null 2>&1; then
    fail "invalid Skill Card name/version was accepted: $invalid_identity"
  fi
done

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
assert d["eventCount"] == 3
assert d["counts"] == {"pending": 3, "superseded": 0, "kept": 0, "skipped": 0, "deferred": 0}
assert [item["candidateId"] for item in d["candidates"]] == ["cand-wiki", "cand-skill", "cand-capture"]
assert d["candidates"][1]["candidateType"] == "skill_card"
assert d["candidates"][1]["skillRegistration"] == {
    "provider": "claude-code-project",
    "name": "receipt-verifier",
    "version": "1.0.0",
    "contractHash": "sha256:" + "a" * 64,
    "roles": ["reviewer"],
    "triggers": ["publish review"],
    "summary": "Verify applied Note receipts before publication.",
    "discoveryState": "pending",
}
' || fail "fold did not preserve pending Wiki and Skill Card candidates"

# Capture records proposal identity before a recoverable pause, then replaces it with the
# verified post-write identity only after apply succeeds.
BEFORE_HASH="sha256:1111111111111111111111111111111111111111111111111111111111111111"
AFTER_HASH="sha256:2222222222222222222222222222222222222222222222222222222222222222"
BINDING_DIGEST="3333333333333333333333333333333333333333333333333333333333333333"
capture_outcome() {
  python3 "$JOURNAL_CLI" outcome \
    --journal "$JOURNAL" --feature-slug feature-a --event-id "$1" \
    --candidate-id cand-capture --status "$2" --reason "$3" \
    --write-state "$4" --operation update \
    --source-id project-wiki --repository-ref knowledge-repo \
    --binding-digest "$BINDING_DIGEST" \
    --wiki-id project/capture/receipts --path Projects/demo/capture-receipts.md \
    --before-hash "$BEFORE_HASH" --after-hash "$AFTER_HASH"
}
capture_outcome evt-capture-proposed deferred \
  'The policy-compliant proposal is waiting for explicit authorization.' proposed >/dev/null
FOLDED="$(python3 "$JOURNAL_CLI" fold --journal "$JOURNAL" --feature-slug feature-a)"
printf '%s' "$FOLDED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
item = next(item for item in d["candidates"] if item["candidateId"] == "cand-capture")
assert item["status"] == "deferred"
assert item["writeReceipt"] == {
    "provider": "obsidian",
    "state": "proposed",
    "operation": "update",
    "sourceId": "project-wiki",
    "repositoryRef": "knowledge-repo",
    "bindingDigest": "3333333333333333333333333333333333333333333333333333333333333333",
    "wikiId": "project/capture/receipts",
    "path": "Projects/demo/capture-receipts.md",
    "beforeHash": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    "afterHash": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
}
' || fail "fold did not preserve the deferred proposal receipt"

# A resumed Capture can replace a stale proposal with a newly validated proposal while
# remaining deferred. The latest proposal becomes the identity that a later apply must match.
BEFORE_HASH="sha256:4444444444444444444444444444444444444444444444444444444444444444"
AFTER_HASH="sha256:5555555555555555555555555555555555555555555555555555555555555555"
capture_outcome evt-capture-reproposed deferred \
  'Note drift required a fresh policy-compliant proposal before authorization.' proposed >/dev/null
FOLDED="$(python3 "$JOURNAL_CLI" fold --journal "$JOURNAL" --feature-slug feature-a)"
printf '%s' "$FOLDED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
item = next(item for item in d["candidates"] if item["candidateId"] == "cand-capture")
assert item["status"] == "deferred"
assert item["writeReceipt"]["state"] == "proposed"
assert item["writeReceipt"]["beforeHash"] == "sha256:4444444444444444444444444444444444444444444444444444444444444444"
assert item["writeReceipt"]["afterHash"] == "sha256:5555555555555555555555555555555555555555555555555555555555555555"
' || fail "fold did not retain the latest re-proposal receipt"

python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-capture-still-deferred \
  --candidate-id cand-capture --status deferred \
  --reason 'Authorization is still unavailable; retain the latest valid proposal.' >/dev/null
FOLDED="$(python3 "$JOURNAL_CLI" fold --journal "$JOURNAL" --feature-slug feature-a)"
printf '%s' "$FOLDED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
item = next(item for item in d["candidates"] if item["candidateId"] == "cand-capture")
assert item["status"] == "deferred"
assert item["writeReceipt"]["state"] == "proposed"
assert item["writeReceipt"]["afterHash"] == "sha256:5555555555555555555555555555555555555555555555555555555555555555"
' || fail "receipt-less re-deferral discarded the latest valid proposal"

PROPOSAL_BEFORE="$(sha256_file "$JOURNAL")"
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-capture-missing \
  --candidate-id cand-capture --status kept \
  --reason 'Applied without retaining the proposal identity.' >/dev/null 2>&1; then
  fail "proposed receipt transitioned to kept without an applied receipt"
fi
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-capture-mismatch \
  --candidate-id cand-capture --status kept --reason 'Applied a different Note.' \
  --write-state applied --operation update \
  --source-id project-wiki --repository-ref knowledge-repo \
  --binding-digest "$BINDING_DIGEST" \
  --wiki-id project/capture/other --path Projects/demo/other.md \
  --before-hash "$BEFORE_HASH" --after-hash "$AFTER_HASH" >/dev/null 2>&1; then
  fail "proposed receipt transitioned to a mismatched applied identity"
fi
PROPOSAL_AFTER="$(sha256_file "$JOURNAL")"
[[ "$PROPOSAL_BEFORE" == "$PROPOSAL_AFTER" ]] \
  || fail "rejected proposed-to-applied transition mutated the journal"
capture_outcome evt-capture-applied kept \
  'The write bridge returned the matching post-write identity.' applied >/dev/null

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
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-6-missing \
  --candidate-id cand-skill --status kept \
  --reason 'The pack exists but no reviewed Card was applied.' >/dev/null 2>&1; then
  fail "Skill Card candidate reached kept without an applied bound receipt"
fi
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-6-mismatch \
  --candidate-id cand-skill --status kept --reason 'Applied another Card.' \
  --write-state applied --operation create \
  --source-id project-wiki --repository-ref knowledge-repo \
  --binding-digest "$BINDING_DIGEST" --wiki-id project/skills/other \
  --path Projects/demo/Skills/other.md --after-hash "$AFTER_HASH" \
  --skill-provider claude-code-project --skill-name other --skill-version 1.0.0 \
  --skill-contract-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --skill-role reviewer --skill-trigger 'publish review' \
  --skill-summary 'Verify applied Note receipts before publication.' >/dev/null 2>&1; then
  fail "Skill Card candidate accepted a receipt for another registration"
fi
python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-6 \
  --candidate-id cand-skill --status kept \
  --reason 'The reviewed Card was applied with the staged pack identity.' \
  --write-state applied --operation create \
  --source-id project-wiki --repository-ref knowledge-repo \
  --binding-digest "$BINDING_DIGEST" \
  --wiki-id project/skills/receipt-verifier \
  --path Projects/demo/Skills/receipt-verifier.md \
  --after-hash "$AFTER_HASH" \
  --skill-provider claude-code-project \
  --skill-name receipt-verifier --skill-version 1.0.0 \
  --skill-contract-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --skill-role reviewer --skill-trigger 'publish review' \
  --skill-summary 'Verify applied Note receipts before publication.' >/dev/null

python3 "$JOURNAL_CLI" validate --journal "$JOURNAL" --feature-slug feature-a >/dev/null
FOLDED="$(python3 "$JOURNAL_CLI" fold --journal "$JOURNAL" --feature-slug feature-a)"
printf '%s' "$FOLDED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by_id = {item["candidateId"]: item for item in d["candidates"]}
assert by_id["cand-wiki"]["status"] == "superseded"
assert by_id["cand-wiki"]["supersededBy"] == "cand-replacement"
assert by_id["cand-skill"]["status"] == "kept"
assert by_id["cand-skill"]["writeReceipt"]["skillRegistration"] == by_id["cand-skill"]["skillRegistration"]
assert by_id["cand-replacement"]["status"] == "pending"
assert by_id["cand-capture"]["status"] == "kept"
assert by_id["cand-capture"]["writeReceipt"]["state"] == "applied"
assert by_id["cand-capture"]["writeReceipt"]["repositoryRef"] == "knowledge-repo"
assert by_id["cand-capture"]["writeReceipt"]["afterHash"].startswith("sha256:")
assert d["counts"]["pending"] == 1
assert d["counts"]["superseded"] == 1
assert d["counts"]["kept"] == 2
' || fail "fold did not apply supersede and outcome lifecycle events"

# Duplicate identities and illegal terminal transitions fail without changing the journal.
BEFORE="$(sha256_file "$JOURNAL")"
if append_candidate evt-7 cand-replacement review wiki_note decision x y z >/dev/null 2>&1; then
  fail "duplicate candidateId was accepted"
fi
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-7 \
  --candidate-id cand-skill --status skipped --reason 'illegal rewrite' >/dev/null 2>&1; then
  fail "terminal candidate outcome was rewritten"
fi
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-8 \
  --candidate-id cand-replacement --status kept --reason 'invalid proposal state' \
  --write-state proposed --operation update \
  --source-id project-wiki --repository-ref knowledge-repo \
  --binding-digest "$BINDING_DIGEST" \
  --wiki-id project/capture/receipts --path Projects/demo/capture-receipts.md \
  --before-hash "$BEFORE_HASH" --after-hash "$AFTER_HASH" >/dev/null 2>&1; then
  fail "kept outcome accepted a proposed-only write receipt"
fi
if python3 "$JOURNAL_CLI" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-9 \
  --candidate-id cand-replacement --status deferred --reason 'partial receipt' \
  --write-state proposed --operation update --source-id project-wiki >/dev/null 2>&1; then
  fail "partial Capture write receipt was accepted"
fi
AFTER="$(sha256_file "$JOURNAL")"
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

python3 "$JOURNAL_CLI" validate \
  --journal "$ROOT/contracts/wiki-candidate-journal-v1.example.jsonl" \
  --feature-slug receipt-publishing >/dev/null \
  || fail "candidate journal contract example is invalid"

printf 'wiki candidate journal smoke OK\n'
