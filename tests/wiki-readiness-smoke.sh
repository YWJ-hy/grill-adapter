#!/usr/bin/env bash
set -euo pipefail

# Public implementation-entry seam:
# stable single-task roster -> readiness receipt -> existing Carry/Bind validation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
READINESS="${TARGET_INPUT}/scripts/wiki_readiness.py"
RENDER="${TARGET_INPUT}/scripts/wiki_context_render.py"
CONTRACT="${TARGET_INPUT}/contracts/wiki-readiness-v1.example.jsonc"
SKILL="${TARGET_INPUT}/skills/wiki-readiness/SKILL.md"

for file in "$READINESS" "$RENDER" "$CONTRACT" "$SKILL"; do
  if [[ ! -f "$file" ]]; then
    printf 'Missing readiness surface: %s\n' "$file" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CTX_DIR="$TMP/project/.adapter/context"
mkdir -p "$CTX_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

# Direct GitHub issue implementation uses the real issue id and exact body as the fingerprint input.
ISSUE_JSON="$TMP/issue.json"
ISSUE_ROSTER="$CTX_DIR/issue-19.ticket-roster.json"
cat > "$ISSUE_JSON" <<'JSON'
{
  "number": 19,
  "title": "Unify implementation readiness",
  "body": "First line.\n\nSecond line remains verbatim.\n"
}
JSON
python3 "$READINESS" prepare-issue \
  --feature-slug issue-19 \
  --issue-json "$ISSUE_JSON" \
  --roster "$ISSUE_ROSTER" >/dev/null
python3 - "$ISSUE_ROSTER" <<'PY'
import json
import sys

roster = json.load(open(sys.argv[1], encoding="utf-8"))
assert roster["featureSlug"] == "issue-19"
assert roster["ticketSource"] == "github-issues"
assert roster["tickets"] == [{
    "taskId": "19",
    "taskTitle": "Unify implementation readiness",
    "text": "First line.\n\nSecond line remains verbatim.\n",
}]
PY

# A confirmed conversational request becomes one manual task; the full brief is authoritative.
MANUAL_TEXT="$TMP/manual-brief.md"
MANUAL_ROSTER="$CTX_DIR/manual-change.ticket-roster.json"
printf '%s\n' 'Implement the confirmed request exactly as discussed.' > "$MANUAL_TEXT"
python3 "$READINESS" prepare-manual \
  --feature-slug manual-change \
  --task-title "Confirmed manual request" \
  --task-text-file "$MANUAL_TEXT" \
  --roster "$MANUAL_ROSTER" >/dev/null
python3 - "$MANUAL_ROSTER" <<'PY'
import json
import sys

roster = json.load(open(sys.argv[1], encoding="utf-8"))
assert roster["ticketSource"] == "manual"
assert roster["tickets"] == [{
    "taskId": "manual",
    "taskTitle": "Confirmed manual request",
    "text": "Implement the confirmed request exactly as discussed.\n",
}]
PY

# Build a finalized context through the existing public Carry seam.
SELECTION="$TMP/issue-19.obsidian-wiki-selection.json"
CONTEXT="$CTX_DIR/issue-19.wiki-context.json"
RECEIPT="$CTX_DIR/issue-19.wiki-readiness.json"
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
      "summary": "Runtime writes preserve the transaction boundary.",
      "contentHash": "sha256:ab31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
      "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798"
    }
  ],
  "requiredSkills": [],
  "caveats": [],
  "maintenanceWarnings": []
}
JSON
python3 "$RENDER" "$CONTEXT" --scaffold "$SELECTION" \
  --feature-slug issue-19 --ticket-source github-issues --strict >/dev/null
python3 - "$CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["destination"].update({
    "reason": "The direct issue changes this runtime boundary.",
    "tasks": ["19"],
})
context["taskRouting"]["status"] = "confirmed"
context["taskRouting"]["selectedSectionsFrozen"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$CONTEXT" --finalize --strict --ticket-roster "$ISSUE_ROSTER" >/dev/null

# A caller cannot claim ready through the generic recorder, and a failed Bind emits no partial
# rendered/metadata output or receipt.
if python3 "$READINESS" record \
  --receipt "$RECEIPT" \
  --roster "$ISSUE_ROSTER" \
  --task-id 19 \
  --status ready \
  --context "$CONTEXT" \
  --reason "No materialization actually ran." >"$TMP/false-ready.out" 2>&1; then
  fail "record must not allow a caller to claim ready without materialization"
fi
need "$TMP/false-ready.out" "bind"
if python3 "$READINESS" bind \
  --receipt "$RECEIPT" \
  --roster "$ISSUE_ROSTER" \
  --context "$CONTEXT" \
  --task-id 19 \
  --project-root "$TMP/project" \
  --reason "Must fail without the configured Obsidian runtime." \
  >"$TMP/failed-bind.stdout" 2>"$TMP/failed-bind.stderr"; then
  fail "unconfigured Obsidian materialization must fail"
fi
[[ ! -s "$TMP/failed-bind.stdout" ]] || fail "failed Bind exposed partial rendered context"
[[ ! -f "$RECEIPT" ]] || fail "failed Bind wrote a ready receipt"
need "$TMP/failed-bind.stderr" "materialization"

# Reuse an already-finalized formal-ticket context through the Obsidian materializer.
FORMAL_ROSTER="$CTX_DIR/formal-feature.ticket-roster.json"
FORMAL_SELECTION="$TMP/formal-feature.obsidian-wiki-selection.json"
FORMAL_CONTEXT="$CTX_DIR/formal-feature.wiki-context.json"
FORMAL_RECEIPT="$CTX_DIR/formal-feature.wiki-readiness.json"
FORMAL_SNAPSHOT="sha256:6240d8cadfd2df3df96ee005f0349145191b5b219b922c3c93aab9c7f2bd2e6e"
FORMAL_BINDING="d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798"
FORMAL_CONTENT="sha256:ab31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b"
cat > "$FORMAL_ROSTER" <<'JSON'
{
  "featureSlug": "formal-feature",
  "ticketSource": "grill-local-scratch",
  "tickets": [
    {
      "taskId": "01",
      "taskTitle": "Preserve formal routing",
      "text": "# 01 - Preserve formal routing\n\nKeep the finalized task identity unchanged."
    }
  ]
}
JSON
cat > "$FORMAL_SELECTION" <<JSON
{
  "status": "ok",
  "phase": "plan",
  "snapshotHash": "${FORMAL_SNAPSHOT}",
  "wikiBindings": [
    {
      "sourceId": "project-runtime",
      "role": "project",
      "bindingDigest": "${FORMAL_BINDING}"
    }
  ],
  "wikiNotes": [
    {
      "sourceId": "project-runtime",
      "role": "project",
      "path": "Projects/example/Runtime/execution-boundary.md",
      "wikiId": "project/runtime/execution-boundary",
      "type": "constraint",
      "constraintStrength": "hard",
      "summary": "Formal execution boundary must be materialized before implementation.",
      "contentHash": "${FORMAL_CONTENT}",
      "bindingDigest": "${FORMAL_BINDING}"
    }
  ],
  "requiredSkills": [],
  "caveats": [],
  "maintenanceWarnings": []
}
JSON
python3 "$RENDER" "$FORMAL_CONTEXT" --scaffold "$FORMAL_SELECTION" \
  --feature-slug formal-feature --ticket-source grill-local-scratch --strict >/dev/null
python3 - "$FORMAL_CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["destination"].update({
    "reason": "The formal ticket implements this boundary.",
    "tasks": ["01"],
})
context["taskRouting"]["status"] = "confirmed"
context["taskRouting"]["selectedSectionsFrozen"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$FORMAL_CONTEXT" --finalize --strict --ticket-roster "$FORMAL_ROSTER" >/dev/null

FAKE_OBSIDIAN="$TMP/fake-obsidian"
cat > "$FAKE_OBSIDIAN" <<'PY'
#!/usr/bin/env python3
import json
import sys

request = json.load(sys.stdin)
wiki_id = "project/runtime/execution-boundary"
if sys.argv[1] == "read-notes-by-wiki-ids":
    assert request == {"wikiIds": [wiki_id]}
    print(json.dumps({
        "notes": [{
            "sourceId": "project-runtime",
            "role": "project",
            "path": "Projects/example/Runtime/execution-boundary.md",
            "wikiId": wiki_id,
            "type": "constraint",
            "constraintStrength": "hard",
            "summary": "Formal execution boundary must be materialized before implementation.",
            "contentHash": "sha256:ab31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
            "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798",
            "content": "Formal execution boundary must be materialized before implementation.",
        }],
        "snapshotHash": "sha256:6240d8cadfd2df3df96ee005f0349145191b5b219b922c3c93aab9c7f2bd2e6e",
    }))
elif sys.argv[1] == "graph-neighbors":
    assert request == {"wikiIds": [wiki_id]}
    print(json.dumps({"neighbors": {wiki_id: []}}))
else:
    raise SystemExit(f"unexpected command: {sys.argv[1]}")
PY
chmod +x "$FAKE_OBSIDIAN"

CONTEXT_HASH_BEFORE="$(python3 - "$FORMAL_CONTEXT" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
ROSTER_HASH_BEFORE="$(python3 - "$FORMAL_ROSTER" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
OBSIDIAN_WIKI_MCP_CMD="$FAKE_OBSIDIAN" python3 "$READINESS" bind \
  --receipt "$FORMAL_RECEIPT" \
  --roster "$FORMAL_ROSTER" \
  --context "$FORMAL_CONTEXT" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --reason "Implementer constraints materialized successfully." >"$TMP/formal-bind.out"
need "$TMP/formal-bind.out" "Formal execution boundary must be materialized"
python3 "$READINESS" validate --receipt "$FORMAL_RECEIPT" --task-id 01 >/dev/null
python3 - "$FORMAL_RECEIPT" "$CONTEXT_HASH_BEFORE" "$ROSTER_HASH_BEFORE" "$FORMAL_CONTEXT" "$FORMAL_ROSTER" <<'PY'
import hashlib
import json
import sys

receipt_path, context_before, roster_before, context_path, roster_path = sys.argv[1:]
receipt = json.load(open(receipt_path, encoding="utf-8"))
assert receipt["kind"] == "grill-adapter.wiki-readiness"
assert receipt["featureSlug"] == "formal-feature"
assert receipt["ticketSource"] == "grill-local-scratch"
assert receipt["rosterFile"] == "formal-feature.ticket-roster.json"
assert len(receipt["tasks"]) == 1
task = receipt["tasks"][0]
assert task["taskId"] == "01"
assert task["status"] == "ready"
assert task["contextDisposition"] == "materialized"
assert task["contextFile"] == "formal-feature.wiki-context.json"
assert len(task["taskFingerprint"]) == 64
assert hashlib.sha256(open(context_path, "rb").read()).hexdigest() == context_before
assert hashlib.sha256(open(roster_path, "rb").read()).hexdigest() == roster_before
PY

# Formal-ticket drift invalidates the reusable readiness result.
python3 - "$FORMAL_ROSTER" <<'PY'
import json
import sys

path = sys.argv[1]
roster = json.load(open(path, encoding="utf-8"))
roster["tickets"][0]["text"] += "\nChanged after readiness.\n"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(roster, handle, indent=2)
    handle.write("\n")
PY
if python3 "$READINESS" validate --receipt "$FORMAL_RECEIPT" --task-id 01 >"$TMP/drift.out" 2>&1; then
  fail "fingerprint drift must invalidate readiness"
fi
need "$TMP/drift.out" "fingerprint"

# Fail-open outcomes keep the stable task identity but never point at partial or stale context.
for status in no-relevant disabled broken; do
  state_receipt="$CTX_DIR/manual-change.${status}.wiki-readiness.json"
  python3 "$READINESS" record \
    --receipt "$state_receipt" \
    --roster "$MANUAL_ROSTER" \
    --task-id manual \
    --status "$status" \
    --reason "No verified Wiki context is available." >/dev/null
  python3 "$READINESS" validate --receipt "$state_receipt" --task-id manual >/dev/null
  python3 - "$state_receipt" "$status" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
task = receipt["tasks"][0]
assert task["status"] == sys.argv[2]
assert task["contextDisposition"] in {"none", "discarded"}
assert "contextFile" not in task
assert "content" not in json.dumps(receipt).lower()
PY
done

if python3 "$READINESS" record \
  --receipt "$CTX_DIR/invalid-broken.wiki-readiness.json" \
  --roster "$MANUAL_ROSTER" \
  --task-id manual \
  --status broken \
  --context "$CONTEXT" \
  --reason "Must discard invalid context." >"$TMP/broken-context.out" 2>&1; then
  fail "broken readiness must not retain a context file"
fi
need "$TMP/broken-context.out" "must not"

# Shipped instructions make the fail-open host policy explicit without weakening Wiki validation.
for file in "$CONTRACT" "$SKILL"; do
  need "$file" "no-relevant"
  need "$file" "disabled"
  need "$file" "broken"
  need "$file" "fingerprint"
  need "$file" "continue"
done
need "$SKILL" "before the first code edit"
need "$SKILL" "gh issue view"
need "$SKILL" "manual"
need "$SKILL" "Do not patch"

printf 'wiki readiness smoke OK\n'
