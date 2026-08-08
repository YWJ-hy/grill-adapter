#!/usr/bin/env bash
set -euo pipefail

# Public implementation-entry seam:
# stable single-task roster -> readiness receipt -> existing Carry/Bind validation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_windows-compat.bash"
TARGET_INPUT="${1:-${ROOT}}"
READINESS="${TARGET_INPUT}/scripts/wiki_readiness.py"
RENDER="${TARGET_INPUT}/scripts/wiki_context_render.py"
MATERIALIZE="${TARGET_INPUT}/scripts/wiki_materialize_task.py"
CONTRACT="${TARGET_INPUT}/contracts/wiki-readiness-v1.example.jsonc"
SNAPSHOT_CONTRACT="${TARGET_INPUT}/contracts/wiki-task-snapshot-v2.example.jsonc"
APPROVAL_CONTRACT="${TARGET_INPUT}/contracts/wiki-task-approval-v1.example.jsonc"
RESULT_CONTRACT="${TARGET_INPUT}/contracts/wiki-readiness-result-v1.example.jsonc"
SKILL="${TARGET_INPUT}/skills/wiki-readiness/SKILL.md"

for file in "$READINESS" "$RENDER" "$MATERIALIZE" "$CONTRACT" "$SNAPSHOT_CONTRACT" "$APPROVAL_CONTRACT" "$RESULT_CONTRACT" "$SKILL"; do
  if [[ ! -f "$file" ]]; then
    printf 'Missing readiness surface: %s\n' "$file" >&2
    exit 1
  fi
done

TMP="$(portable_tmpdir)"
trap 'rm -rf "$TMP"' EXIT
CONTEXT_ROOT="$TMP/project/.grill-adapter/context"
ISSUE_DIR="$CONTEXT_ROOT/issue-19"
MANUAL_DIR="$CONTEXT_ROOT/manual-change"
FORMAL_DIR="$CONTEXT_ROOT/formal-feature"
BATCH_DIR="$CONTEXT_ROOT/batch-feature"
ATOMIC_BATCH_DIR="$CONTEXT_ROOT/atomic-batch-feature"
mkdir -p "$ISSUE_DIR" "$MANUAL_DIR" "$FORMAL_DIR" "$BATCH_DIR" "$ATOMIC_BATCH_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }
deny() { if grep -Fq "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi; }

# Direct GitHub issue implementation uses the real issue id and exact body as the fingerprint input.
ISSUE_JSON="$ISSUE_DIR/issue.json"
ISSUE_ROSTER="$ISSUE_DIR/ticket-roster.json"
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
MANUAL_TEXT="$MANUAL_DIR/task-brief.md"
MANUAL_ROSTER="$MANUAL_DIR/ticket-roster.json"
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

# Configured-but-ambiguous Wiki settings are broken, and a high-level direct/manual run removes
# any transient Carry artifacts before recording that caveat.
BROKEN_DIR="$CONTEXT_ROOT/broken-run"
BROKEN_ROSTER="$BROKEN_DIR/ticket-roster.json"
mkdir -p "$BROKEN_DIR"
cp "$MANUAL_ROSTER" "$BROKEN_ROSTER"
python3 - "$BROKEN_ROSTER" <<'PY'
import json
import sys

path = sys.argv[1]
roster = json.load(open(path, encoding="utf-8"))
roster["featureSlug"] = "broken-run"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(roster, handle, indent=2)
    handle.write("\n")
PY
printf '%s\n' '{"partial":"context"}' > "$BROKEN_DIR/wiki-context.json"
printf '%s\n' '{"partial":"selection"}' > "$BROKEN_DIR/obsidian-wiki-selection.json"
printf '%s\n' 'partial snapshot' > "$BROKEN_DIR/manual.wiki-implement.md"
printf '%s\n' 'partial snapshot' > "$BROKEN_DIR/manual.wiki-review.md"
mkdir -p "$TMP/project/.grill-adapter"
printf '%s\n' '{"wiki":{"provider":"unknown-provider"}}' > "$TMP/project/.grill-adapter/settings.json"
BROKEN_RESULT="$TMP/broken-run-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug broken-run \
  --task-id manual >"$BROKEN_RESULT"
python3 - "$BROKEN_RESULT" "$BROKEN_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["status"] == "broken", result
for name in (
    "wiki-context.json",
    "obsidian-wiki-selection.json",
    "manual.wiki-implement.md",
    "manual.wiki-review.md",
):
    assert not (directory / name).exists(), (name, result)
receipt = json.loads((directory / "wiki-readiness.json").read_text(encoding="utf-8"))
assert receipt["tasks"][0]["status"] == "broken", receipt
PY

# A direct/manual high-level run with no configured provider is a clean disabled terminal state.
# It keeps the single-task identity but does not invent a sidecar or attempt late Carry.
rm -f "$TMP/project/.grill-adapter/settings.json"
DISABLED_RESULT="$TMP/disabled-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug manual-change \
  --task-id manual >"$DISABLED_RESULT"
python3 - "$DISABLED_RESULT" "$MANUAL_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["status"] == "disabled", result
assert result["contextDisposition"] == "none", result
assert not (directory / "wiki-context.json").exists(), result
assert not (directory / "manual.wiki-implement.md").exists(), result
assert not (directory / "manual.wiki-review.md").exists(), result
PY

# Build a finalized context through the existing public Carry seam.
SELECTION="$ISSUE_DIR/obsidian-wiki-selection.json"
CONTEXT="$ISSUE_DIR/wiki-context.json"
RECEIPT="$ISSUE_DIR/wiki-readiness.json"
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
FORMAL_ROSTER="$FORMAL_DIR/ticket-roster.json"
FORMAL_SELECTION="$FORMAL_DIR/obsidian-wiki-selection.json"
FORMAL_CONTEXT="$FORMAL_DIR/wiki-context.json"
FORMAL_RECEIPT="$FORMAL_DIR/wiki-readiness.json"
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
      "bindingDigest": "${FORMAL_BINDING}",
      "verifiedAt": "2020-01-01T00:00:00Z",
      "reviewAfter": "2999-01-01T00:00:00Z",
      "expiresAt": "3999-01-01T00:00:00Z"
    },
    {
      "sourceId": "project-runtime",
      "role": "project",
      "path": "Projects/example/Runtime/operational-context.md",
      "wikiId": "project/runtime/operational-context",
      "type": "guide",
      "constraintStrength": "soft",
      "summary": "Operational context remains visible without a full-text reread.",
      "contentHash": "sha256:cb31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
      "bindingDigest": "${FORMAL_BINDING}",
      "verifiedAt": "2020-01-01T00:00:00Z",
      "reviewAfter": "2999-01-01T00:00:00Z",
      "expiresAt": "3999-01-01T00:00:00Z"
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
for note in context["wikiNotes"]:
    note["destination"].update({
        "kind": "task-bound",
        "reason": "The formal ticket uses this Wiki context.",
        "tasks": ["01"],
    })
context["taskRouting"]["status"] = "confirmed"
context["taskRouting"]["selectedSectionsFrozen"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$FORMAL_CONTEXT" --finalize --strict --ticket-roster "$FORMAL_ROSTER" >/dev/null

FAKE_OBSIDIAN="$TMP/fake-obsidian.py"
cat > "$FAKE_OBSIDIAN" <<'PY'
#!/usr/bin/env python3
import json
import sys

request = json.load(sys.stdin)
wiki_id = "project/runtime/execution-boundary"
closure_id = "project/runtime/dependency-boundary"
if sys.argv[1] == "read-notes-by-wiki-ids":
    if request == {"wikiIds": [wiki_id]}:
        notes = [{
            "sourceId": "project-runtime",
            "role": "project",
            "path": "Projects/example/Runtime/execution-boundary.md",
            "wikiId": wiki_id,
            "type": "constraint",
            "constraintStrength": "hard",
            "summary": "Formal execution boundary must be materialized before implementation.",
            "contentHash": "sha256:ab31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
            "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798",
            "verifiedAt": "2020-01-01T00:00:00Z",
            "reviewAfter": "2999-01-01T00:00:00Z",
            "expiresAt": "3999-01-01T00:00:00Z",
            "content": "Formal execution boundary must be materialized before implementation.",
        }]
    elif request == {"wikiIds": [closure_id]}:
        notes = [{
            "sourceId": "project-runtime",
            "role": "project",
            "path": "Projects/example/Runtime/dependency-boundary.md",
            "wikiId": closure_id,
            "type": "constraint",
            "constraintStrength": "hard",
            "summary": "The direct dependency must remain current.",
            "contentHash": "sha256:bb31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
            "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798",
            "verifiedAt": "2020-01-01T00:00:00Z",
            "reviewAfter": "2021-01-01T00:00:00Z",
            "expiresAt": "2999-06-01T00:00:00Z",
            "content": "The direct dependency must remain current.",
        }]
    else:
        raise SystemExit(f"unexpected read request: {request}")
    print(json.dumps({
        "notes": notes,
        "snapshotHash": "sha256:6240d8cadfd2df3df96ee005f0349145191b5b219b922c3c93aab9c7f2bd2e6e",
    }))
elif sys.argv[1] == "graph-neighbors":
    assert request == {"wikiIds": [wiki_id]}
    print(json.dumps({"neighbors": {wiki_id: [{
        "type": "depends_on",
        "wikiId": closure_id,
        "path": "Projects/example/Runtime/dependency-boundary.md",
    }]}}))
else:
    raise SystemExit(f"unexpected command: {sys.argv[1]}")
PY
chmod +x "$FAKE_OBSIDIAN"
FAKE_OBSIDIAN_CMD="python3 $FAKE_OBSIDIAN"

# Direct late Carry accepts only a finalized, user-routed single-task context. It stages the role
# pair and receipt together, so a failed materialization leaves no partial late-task artifacts.
LATE_DIR="$CONTEXT_ROOT/direct-late"
LATE_ROSTER="$LATE_DIR/ticket-roster.json"
LATE_CONTEXT="$LATE_DIR/wiki-context.json"
mkdir -p "$LATE_DIR"
cp "$FORMAL_CONTEXT" "$LATE_CONTEXT"
cat > "$LATE_ROSTER" <<'JSON'
{
  "featureSlug": "direct-late",
  "ticketSource": "github-issues",
  "tickets": [
    {
      "taskId": "43",
      "taskTitle": "Direct late Carry",
      "text": "The direct issue body is fingerprinted verbatim."
    }
  ]
}
JSON
python3 - "$LATE_CONTEXT" "$LATE_ROSTER" <<'PY'
import json
import sys

context_path, roster_path = sys.argv[1:]
context = json.load(open(context_path, encoding="utf-8"))
roster = json.load(open(roster_path, encoding="utf-8"))
context["featureSlug"] = roster["featureSlug"]
context["ticketSource"] = roster["ticketSource"]
for collection in ("wikiNotes", "requiredSkills"):
    for note in context.get(collection, []):
        destination = note["destination"]
        if destination.get("kind") == "task-bound":
            destination["tasks"] = ["43"]
for ref in context["taskWikiRefs"]:
    ref["taskId"] = "43"
    ref["taskTitle"] = "Direct late Carry"
    ref.pop("taskFingerprint", None)
with open(context_path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$LATE_CONTEXT" --bind-fingerprints --execution-ready --strict --ticket-roster "$LATE_ROSTER" >/dev/null
LATE_RESULT="$TMP/late-carry-result.json"
python3 "$READINESS" late-carry \
  --project-root "$TMP/project" \
  --feature-slug direct-late \
  --task-id 43 \
  --context "$LATE_CONTEXT" \
  --roster "$LATE_ROSTER" \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" >"$LATE_RESULT"
python3 - "$LATE_RESULT" "$LATE_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["status"] == "ready", result
assert result["taskId"] == "43", result
assert (directory / "43.wiki-implement.md").is_file(), result
assert (directory / "43.wiki-review.md").is_file(), result
assert (directory / "43.wiki-approval.json").is_file(), result
assert (directory / "wiki-readiness.json").is_file(), result
assert not (directory / "obsidian-wiki-selection.json").exists(), result
PY

rm -f "$LATE_DIR/43.wiki-implement.md" "$LATE_DIR/43.wiki-review.md" \
  "$LATE_DIR/43.wiki-approval.json" "$LATE_DIR/wiki-readiness.json"
cp "$FORMAL_CONTEXT" "$LATE_CONTEXT"
python3 - "$LATE_CONTEXT" "$LATE_ROSTER" <<'PY'
import json
import sys

context_path, roster_path = sys.argv[1:]
context = json.load(open(context_path, encoding="utf-8"))
roster = json.load(open(roster_path, encoding="utf-8"))
context["featureSlug"] = roster["featureSlug"]
context["ticketSource"] = roster["ticketSource"]
for collection in ("wikiNotes", "requiredSkills"):
    for note in context.get(collection, []):
        destination = note["destination"]
        if destination.get("kind") == "task-bound":
            destination["tasks"] = ["43"]
for ref in context["taskWikiRefs"]:
    ref["taskId"] = "43"
    ref["taskTitle"] = "Direct late Carry"
    ref.pop("taskFingerprint", None)
with open(context_path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$LATE_CONTEXT" --bind-fingerprints --execution-ready --strict --ticket-roster "$LATE_ROSTER" >/dev/null
LATE_FAILURE="$TMP/late-carry-failure.json"
python3 "$READINESS" late-carry \
  --project-root "$TMP/project" \
  --feature-slug direct-late \
  --task-id 43 \
  --context "$LATE_CONTEXT" \
  --roster "$LATE_ROSTER" \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" >"$LATE_FAILURE"
python3 - "$LATE_FAILURE" "$LATE_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["status"] == "broken", result
assert not (directory / "wiki-context.json").exists(), result
assert not (directory / "43.wiki-implement.md").exists(), result
assert not (directory / "43.wiki-review.md").exists(), result
assert not (directory / "43.wiki-approval.json").exists(), result
receipt = json.loads((directory / "wiki-readiness.json").read_text(encoding="utf-8"))
assert receipt["tasks"][0]["status"] == "broken", receipt
PY

# The high-level formal readiness entry resolves the canonical roster/context/receipt paths from
# the project root, feature slug, and one stable task id. Its result is structured so the host does
# not need to sequence fingerprint preflight, compatibility freeze, Bind, and receipt validation.
HIGH_LEVEL_RESULT="$TMP/formal-readiness-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id 01 \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" \
  --reason "High-level formal readiness entry." >"$HIGH_LEVEL_RESULT"
python3 - "$HIGH_LEVEL_RESULT" "$FORMAL_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["schemaVersion"] == 1, result
assert result["kind"] == "grill-adapter.wiki-readiness-result", result
assert result["status"] == "ready", result
assert result["taskId"] == "01", result
assert result["featureSlug"] == "formal-feature", result
assert result["rosterFile"] == "ticket-roster.json", result
assert result["receiptFile"] == "wiki-readiness.json", result
assert result["implementer"]["file"] == "01.wiki-implement.md", result
assert result["reviewer"]["file"] == "01.wiki-review.md", result
assert result["implementer"]["digest"].startswith("sha256:"), result
assert result["reviewer"]["digest"].startswith("sha256:"), result
assert (directory / result["implementer"]["file"]).is_file(), result
assert (directory / result["reviewer"]["file"]).is_file(), result
assert not any(key in result for key in ("content", "noteBody", "selection")), result
PY

# A legacy ready receipt with an already-approved pair is upgraded with both role digests without
# contacting the current Wiki runtime.
python3 - "$FORMAL_RECEIPT" <<'PY'
import json
import sys

path = sys.argv[1]
receipt = json.load(open(path, encoding="utf-8"))
for field in ("implementWikiFile", "implementWikiDigest", "reviewWikiFile", "reviewWikiDigest"):
    receipt["tasks"][0].pop(field, None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2)
    handle.write("\n")
PY
LEGACY_UPGRADE_RESULT="$TMP/legacy-upgrade-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id 01 \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" >"$LEGACY_UPGRADE_RESULT"
python3 - "$LEGACY_UPGRADE_RESULT" "$FORMAL_RECEIPT" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
receipt = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert result["status"] == "ready", result
task = receipt["tasks"][0]
for field in ("implementWikiFile", "implementWikiDigest", "reviewWikiFile", "reviewWikiDigest"):
    assert field in task, (field, task)
PY

# An existing ready receipt with one missing approved artifact takes the compatibility freeze path
# and restores the complete pair plus approval manifest before returning ready.
rm -f "$FORMAL_DIR/01.wiki-review.md" "$FORMAL_DIR/01.wiki-approval.json"
MISSING_PAIR_RESULT="$TMP/missing-approved-pair-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id 01 \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" >"$MISSING_PAIR_RESULT"
python3 - "$MISSING_PAIR_RESULT" "$FORMAL_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["status"] == "ready", result
for filename in ("01.wiki-implement.md", "01.wiki-review.md", "01.wiki-approval.json"):
    assert (directory / filename).is_file(), filename
PY

# The same canonical seam reuses a non-ready receipt without touching context or snapshots.
python3 "$READINESS" record \
  --receipt "$MANUAL_DIR/wiki-readiness.json" \
  --roster "$MANUAL_ROSTER" \
  --task-id manual \
  --status disabled \
  --reason "Wiki provider is disabled for this project." >/dev/null
DISABLED_RESULT="$TMP/disabled-readiness-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug manual-change \
  --task-id manual \
  --reason "Reuse disabled readiness." >"$DISABLED_RESULT"
python3 - "$DISABLED_RESULT" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert result["status"] == "disabled", result
assert "contextFile" not in result, result
assert "implementer" not in result and "reviewer" not in result, result
PY

# Review uses the same canonical identity and derives a separate handoff without overwriting the
# approved reviewer snapshot.
REVIEW_RESULT="$TMP/formal-review-result.json"
python3 "$READINESS" review \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id 01 \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" >"$REVIEW_RESULT"
python3 - "$REVIEW_RESULT" "$FORMAL_DIR" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
assert result["status"] == "ready", result
assert result["handoff"]["file"] == "01.wiki-review-handoff.md", result
assert (directory / result["handoff"]["file"]).is_file(), result
PY

# Traversal-shaped task IDs fail before task-specific paths are constructed.
INVALID_TASK_RESULT="$TMP/invalid-task-result.json"
python3 "$READINESS" run \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id ../escape >"$INVALID_TASK_RESULT"
python3 - "$INVALID_TASK_RESULT" "$FORMAL_DIR/../escape.wiki-review-handoff.md" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert result["status"] == "broken", result
assert "path separators" in result["reason"], result
assert not pathlib.Path(sys.argv[2]).exists(), sys.argv[2]
PY
INVALID_REVIEW_RESULT="$TMP/invalid-review-task-result.json"
python3 "$READINESS" review \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id ../escape >"$INVALID_REVIEW_RESULT"
python3 - "$INVALID_REVIEW_RESULT" "$FORMAL_DIR/../escape.wiki-review-handoff.md" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert result["status"] == "broken", result
assert "path separators" in result["reason"], result
assert not pathlib.Path(sys.argv[2]).exists(), sys.argv[2]
PY

# A malformed implementation receipt still yields a caveat-only reviewer handoff rather than a
# command failure or stale reviewer context.
cp "$FORMAL_RECEIPT" "$TMP/formal-receipt.before-malformed-review.json"
printf '{ malformed receipt\n' >"$FORMAL_RECEIPT"
MALFORMED_REVIEW_RESULT="$TMP/malformed-review-result.json"
python3 "$READINESS" review \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id 01 >"$MALFORMED_REVIEW_RESULT"
python3 - "$MALFORMED_REVIEW_RESULT" "$FORMAL_DIR/01.wiki-review-handoff.md" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
handoff = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert result["status"] == "broken", result
assert "Non-blocking caveat" in handoff, handoff
assert "No verified Wiki reviewer context" in handoff, handoff
PY
mv "$TMP/formal-receipt.before-malformed-review.json" "$FORMAL_RECEIPT"

# A valid artifact pair from another feature cannot be rebound through the requested feature slug.
cp "$FORMAL_RECEIPT" "$TMP/formal-receipt.before-feature-drift.json"
python3 - "$FORMAL_RECEIPT" <<'PY'
import json
import sys

path = sys.argv[1]
receipt = json.load(open(path, encoding="utf-8"))
receipt["featureSlug"] = "other-feature"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2)
    handle.write("\n")
PY
FEATURE_DRIFT_REVIEW_RESULT="$TMP/feature-drift-review-result.json"
python3 "$READINESS" review \
  --project-root "$TMP/project" \
  --feature-slug formal-feature \
  --task-id 01 >"$FEATURE_DRIFT_REVIEW_RESULT"
python3 - "$FEATURE_DRIFT_REVIEW_RESULT" "$FORMAL_DIR/01.wiki-review-handoff.md" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
handoff = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert result["status"] == "broken", result
assert "selected feature" in result["reason"], result
assert "Non-blocking caveat" in handoff, handoff
PY
mv "$TMP/formal-receipt.before-feature-drift.json" "$FORMAL_RECEIPT"

EXPIRED_DIR="$TMP/expired-formal"
mkdir -p "$EXPIRED_DIR"
EXPIRED_CONTEXT="$EXPIRED_DIR/wiki-context.json"
EXPIRED_ROSTER="$EXPIRED_DIR/ticket-roster.json"
cp "$FORMAL_CONTEXT" "$EXPIRED_CONTEXT"
cp "$FORMAL_ROSTER" "$EXPIRED_ROSTER"
python3 - "$EXPIRED_CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["reviewAfter"] = "2021-01-01T00:00:00Z"
context["wikiNotes"][0]["expiresAt"] = "2021-06-01T00:00:00Z"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
if python3 "$READINESS" freeze \
  --context "$EXPIRED_CONTEXT" \
  --roster "$EXPIRED_ROSTER" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" >"$TMP/expired-freeze.out" 2>&1; then
  fail "expired Note must not enter frozen role contracts"
fi
need "$TMP/expired-freeze.out" "expired"

write_runtime_selection() {
  cat > "$1" <<JSON
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
      "bindingDigest": "${FORMAL_BINDING}",
      "verifiedAt": "2020-01-01T00:00:00Z",
      "reviewAfter": "2999-01-01T00:00:00Z",
      "expiresAt": "3999-01-01T00:00:00Z"
    }
  ],
  "requiredSkills": [],
  "caveats": [],
  "maintenanceWarnings": []
}
JSON
}

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
python3 "$READINESS" bind \
  --receipt "$FORMAL_RECEIPT" \
  --roster "$FORMAL_ROSTER" \
  --context "$FORMAL_CONTEXT" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" \
  --reason "Implementer constraints materialized successfully." >"$TMP/formal-bind.out"
need "$TMP/formal-bind.out" "Formal execution boundary must be materialized"
IMPLEMENT_SNAPSHOT="$FORMAL_DIR/01.wiki-implement.md"
REVIEW_SNAPSHOT="$FORMAL_DIR/01.wiki-review.md"
need "$IMPLEMENT_SNAPSHOT" 'Role: `implementer`'
need "$REVIEW_SNAPSHOT" 'Role: `reviewer`'
need "$REVIEW_SNAPSHOT" "Reviewer Handoff"
need "$REVIEW_SNAPSHOT" "same read-only context"
deny "$IMPLEMENT_SNAPSHOT" "Knowledge Freshness Warnings"
deny "$REVIEW_SNAPSHOT" "Knowledge Freshness Warnings"
need "$IMPLEMENT_SNAPSHOT" '"freshnessEntries"'
need "$IMPLEMENT_SNAPSHOT" '"wikiId": "project/runtime/dependency-boundary"'
need "$IMPLEMENT_SNAPSHOT" '"wikiId": "project/runtime/operational-context"'
need "$IMPLEMENT_SNAPSHOT" "Wiki Note project/runtime/dependency-boundary is review-due since 2021-01-01T00:00:00Z."
# Explicit planning approval refreshes both role files together. A subsequent Bind consumes the
# frozen files and no longer depends on the current Obsidian CLI.
python3 "$READINESS" freeze \
  --context "$FORMAL_CONTEXT" \
  --roster "$FORMAL_ROSTER" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" >/dev/null
need "$IMPLEMENT_SNAPSHOT" '"snapshotOrigin": "planning-approved"'

LEGACY_SNAPSHOT="$TMP/legacy-without-freshness.wiki-implement.md"
if python3 - "$READINESS" "$IMPLEMENT_SNAPSHOT" "$LEGACY_SNAPSHOT" "$FORMAL_CONTEXT" <<'PY' >"$TMP/legacy-snapshot.out" 2>&1
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1]).resolve().parent
sys.path.insert(0, str(scripts))
from wiki_task_snapshot import SNAPSHOT_END, SNAPSHOT_MARKER, validate_snapshot

source = Path(sys.argv[2]).read_text(encoding="utf-8")
prefix = SNAPSHOT_MARKER + "\n"
marker = "\n" + SNAPSHOT_END + "\n"
end = source.index(marker, len(prefix))
metadata = json.loads(source[len(prefix):end])
metadata.pop("freshnessEntries")
legacy = prefix + json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + marker + source[end + len(marker):]
legacy_path = Path(sys.argv[3])
legacy_path.write_text(legacy, encoding="utf-8")
validate_snapshot(
    legacy_path,
    context_path=Path(sys.argv[4]),
    feature_slug="formal-feature",
    ticket_source="grill-local-scratch",
    task_id="01",
    task_title="Preserve formal routing",
    task_fingerprint=metadata["taskFingerprint"],
    role="implementer",
)
PY
then
  fail "schema-v2 snapshot without freshnessEntries was accepted"
fi
need "$TMP/legacy-snapshot.out" "freshnessEntries are missing"

# One approved planning pass can freeze every roster task without exposing a per-ticket command
# loop. Each task still receives its own role snapshots and approval manifest.
BATCH_ROSTER="$BATCH_DIR/ticket-roster.json"
BATCH_SELECTION="$BATCH_DIR/obsidian-wiki-selection.json"
BATCH_CONTEXT="$BATCH_DIR/wiki-context.json"
cat > "$BATCH_ROSTER" <<'JSON'
{
  "featureSlug": "batch-feature",
  "ticketSource": "grill-local-scratch",
  "tickets": [
    {"taskId": "01", "taskTitle": "First routed task", "text": "# 01\n\nUse the shared execution boundary."},
    {"taskId": "02", "taskTitle": "Second routed task", "text": "# 02\n\nUse the shared execution boundary too."}
  ]
}
JSON
write_runtime_selection "$BATCH_SELECTION"
python3 "$RENDER" "$BATCH_CONTEXT" --scaffold "$BATCH_SELECTION" \
  --feature-slug batch-feature --ticket-source grill-local-scratch --strict >/dev/null
python3 - "$BATCH_CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["destination"].update({
    "reason": "Both planned tasks use this boundary.",
    "tasks": ["01", "02"],
})
context["taskRouting"]["status"] = "confirmed"
context["taskRouting"]["selectedSectionsFrozen"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$BATCH_CONTEXT" --finalize --strict --ticket-roster "$BATCH_ROSTER" >/dev/null
BATCH_OUT="$(python3 "$READINESS" freeze \
  --context "$BATCH_CONTEXT" \
  --roster "$BATCH_ROSTER" \
  --all \
  --project-root "$TMP/project" \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD")"
printf '%s' "$BATCH_OUT" | grep -q '2 task(s)' || fail "batch freeze did not report both roster tasks"
for task_id in 01 02; do
  need "$BATCH_DIR/${task_id}.wiki-implement.md" '"snapshotOrigin": "planning-approved"'
  need "$BATCH_DIR/${task_id}.wiki-review.md" '"snapshotOrigin": "planning-approved"'
  need "$BATCH_DIR/${task_id}.wiki-approval.json" '"implementWikiDigest"'
done

# A later task's materialization failure must leave no earlier task approved. The batch engine
# prepares every role snapshot before it writes any Markdown or approval manifest.
ATOMIC_ROSTER="$ATOMIC_BATCH_DIR/ticket-roster.json"
ATOMIC_SELECTION="$ATOMIC_BATCH_DIR/obsidian-wiki-selection.json"
ATOMIC_CONTEXT="$ATOMIC_BATCH_DIR/wiki-context.json"
cat > "$ATOMIC_ROSTER" <<'JSON'
{
  "featureSlug": "atomic-batch-feature",
  "ticketSource": "grill-local-scratch",
  "tickets": [
    {"taskId": "01", "taskTitle": "Working task", "text": "# 01\n\nRead the working Note."},
    {"taskId": "02", "taskTitle": "Failing task", "text": "# 02\n\nRead the unavailable Note."}
  ]
}
JSON
write_runtime_selection "$ATOMIC_SELECTION"
python3 - "$ATOMIC_SELECTION" <<'PY'
import json
import sys

path = sys.argv[1]
selection = json.load(open(path, encoding="utf-8"))
selection["wikiNotes"].append({
    "sourceId": "project-runtime",
    "role": "project",
    "path": "Projects/example/Runtime/unavailable-boundary.md",
    "wikiId": "project/runtime/unavailable-boundary",
    "type": "constraint",
    "constraintStrength": "hard",
    "summary": "This Note is intentionally unavailable in the fake runtime.",
    "contentHash": "sha256:cd31c6c9848e035118b3dc7a8c9926d5862f5802e0a567c70873b0e082ae943b",
    "bindingDigest": "d44631c6c041e294a6823d3986d7195e517e84038cfad4f2f78ee71d4a1e8798"
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(selection, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$ATOMIC_CONTEXT" --scaffold "$ATOMIC_SELECTION" \
  --feature-slug atomic-batch-feature --ticket-source grill-local-scratch --strict >/dev/null
python3 - "$ATOMIC_CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["destination"].update({"reason": "First task only.", "tasks": ["01"]})
context["wikiNotes"][1]["destination"].update({"reason": "Second task only.", "tasks": ["02"]})
context["taskRouting"]["status"] = "confirmed"
context["taskRouting"]["selectedSectionsFrozen"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$RENDER" "$ATOMIC_CONTEXT" --finalize --strict --ticket-roster "$ATOMIC_ROSTER" >/dev/null
if python3 "$READINESS" freeze \
  --context "$ATOMIC_CONTEXT" \
  --roster "$ATOMIC_ROSTER" \
  --all \
  --project-root "$TMP/project" \
  --obsidian-wiki-cmd "$FAKE_OBSIDIAN_CMD" >"$TMP/atomic-batch.out" 2>&1; then
  fail "batch freeze accepted an unavailable later task"
fi
[[ ! -e "$ATOMIC_BATCH_DIR/01.wiki-implement.md" ]] || fail "batch freeze approved an earlier task after a later failure"
[[ ! -e "$ATOMIC_BATCH_DIR/01.wiki-approval.json" ]] || fail "batch freeze wrote an earlier approval after a later failure"

python3 "$READINESS" bind \
  --receipt "$FORMAL_RECEIPT" \
  --roster "$FORMAL_ROSTER" \
  --context "$FORMAL_CONTEXT" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" \
  --reason "Approved role snapshots are the task contract." >"$TMP/frozen-bind.out"
need "$TMP/frozen-bind.out" "Formal execution boundary must be materialized"
python3 "$READINESS" validate --receipt "$FORMAL_RECEIPT" --task-id 01 >/dev/null
REVIEW_HASH_BEFORE="$(sha256_file "$REVIEW_SNAPSHOT")"
if python3 "$READINESS" review-handoff \
  --receipt "$FORMAL_RECEIPT" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --handoff "$REVIEW_SNAPSHOT" >"$TMP/review-overwrite.out" 2>&1; then
  fail "review handoff accepted the approved reviewer snapshot as its output path"
fi
need "$TMP/review-overwrite.out" "must not overwrite"
[[ "$(sha256_file "$REVIEW_SNAPSHOT")" == "$REVIEW_HASH_BEFORE" ]] || fail "rejected handoff path mutated reviewer snapshot"
REVIEW_HANDOFF="$FORMAL_DIR/01.wiki-review-handoff.md"
python3 "$READINESS" review-handoff \
  --receipt "$FORMAL_RECEIPT" \
  --task-id 01 \
  --project-root "$TMP/project" \
  --handoff "$REVIEW_HANDOFF" \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" >"$TMP/frozen-review-handoff.out"
need "$TMP/frozen-review-handoff.out" "wrote ready reviewer handoff"
need "$REVIEW_HANDOFF" "Formal execution boundary must be materialized"
[[ "$(sha256_file "$REVIEW_SNAPSHOT")" == "$REVIEW_HASH_BEFORE" ]] || fail "review handoff mutated the approved reviewer snapshot"

# Runtime freshness is derived again from the approved snapshot metadata without mutating its body.
python3 - "$READINESS" "$FORMAL_RECEIPT" "$FORMAL_ROSTER" "$FORMAL_CONTEXT" "$TMP/project" <<'PY' >"$TMP/future-bind.out"
import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("wiki_readiness", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
spec.loader.exec_module(module)
print(module.bind_readiness(
    Path(sys.argv[2]),
    Path(sys.argv[3]),
    Path(sys.argv[4]),
    "01",
    Path(sys.argv[5]),
    "Future-clock Bind revalidated snapshot freshness.",
    now=datetime(2999, 2, 1, tzinfo=timezone.utc),
))
PY
need "$TMP/future-bind.out" "Wiki Note project/runtime/execution-boundary is review-due since 2999-01-01T00:00:00Z."
need "$TMP/future-bind.out" "Wiki Note project/runtime/operational-context is review-due since 2999-01-01T00:00:00Z."
need "$TMP/future-bind.out" "Wiki Note project/runtime/dependency-boundary is review-due since 2021-01-01T00:00:00Z."

FUTURE_REVIEW_HANDOFF="$FORMAL_DIR/01.future.wiki-review-handoff.md"
python3 - "$READINESS" "$FORMAL_RECEIPT" "$TMP/project" "$FUTURE_REVIEW_HANDOFF" <<'PY'
import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("wiki_readiness", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
spec.loader.exec_module(module)
print(module.review_handoff(
    receipt_path=Path(sys.argv[2]),
    task_id="01",
    project_root=Path(sys.argv[3]),
    handoff_path=Path(sys.argv[4]),
    obsidian_wiki_cmd=None,
    now=datetime(2999, 2, 1, tzinfo=timezone.utc),
))
PY
need "$FUTURE_REVIEW_HANDOFF" "Wiki Note project/runtime/execution-boundary is review-due since 2999-01-01T00:00:00Z."
need "$FUTURE_REVIEW_HANDOFF" "Wiki Note project/runtime/operational-context is review-due since 2999-01-01T00:00:00Z."
need "$FUTURE_REVIEW_HANDOFF" "Wiki Note project/runtime/dependency-boundary is review-due since 2021-01-01T00:00:00Z."

if python3 - "$READINESS" "$FORMAL_RECEIPT" "$FORMAL_ROSTER" "$FORMAL_CONTEXT" "$TMP/project" <<'PY' >"$TMP/expired-closure-bind.out" 2>&1
import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("wiki_readiness", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
spec.loader.exec_module(module)
module.bind_readiness(
    Path(sys.argv[2]),
    Path(sys.argv[3]),
    Path(sys.argv[4]),
    "01",
    Path(sys.argv[5]),
    "Expired closure must fail.",
    now=datetime(3000, 1, 1, tzinfo=timezone.utc),
)
PY
then
  fail "Bind accepted a depends_on Note that expired after freeze"
fi
need "$TMP/expired-closure-bind.out" "project/runtime/dependency-boundary is expired"
python3 - "$FORMAL_RECEIPT" "$CONTEXT_HASH_BEFORE" "$ROSTER_HASH_BEFORE" "$FORMAL_CONTEXT" "$FORMAL_ROSTER" "$IMPLEMENT_SNAPSHOT" "$REVIEW_SNAPSHOT" <<'PY'
import hashlib
import json
import sys

receipt_path, context_before, roster_before, context_path, roster_path, implement_path, review_path = sys.argv[1:]
receipt = json.load(open(receipt_path, encoding="utf-8"))
assert receipt["kind"] == "grill-adapter.wiki-readiness"
assert receipt["featureSlug"] == "formal-feature"
assert receipt["ticketSource"] == "grill-local-scratch"
assert receipt["rosterFile"] == "ticket-roster.json"
assert len(receipt["tasks"]) == 1
task = receipt["tasks"][0]
assert task["taskId"] == "01"
assert task["status"] == "ready"
assert task["contextDisposition"] == "materialized"
assert task["contextFile"] == "wiki-context.json"
assert task["implementWikiFile"] == "01.wiki-implement.md"
assert task["reviewWikiFile"] == "01.wiki-review.md"
assert task["implementWikiDigest"] == "sha256:" + hashlib.sha256(open(implement_path, "rb").read()).hexdigest()
assert task["reviewWikiDigest"] == "sha256:" + hashlib.sha256(open(review_path, "rb").read()).hexdigest()
assert len(task["taskFingerprint"]) == 64
assert hashlib.sha256(open(context_path, "rb").read()).hexdigest() == context_before
assert hashlib.sha256(open(roster_path, "rb").read()).hexdigest() == roster_before
PY

# Runtime consumption reuses the approved role files and does not contact the current Source.
python3 "$MATERIALIZE" "$FORMAL_CONTEXT" --task-id 01 --role implementer \
  --project-root "$TMP/project" --strict --execution-ready \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" >"$TMP/frozen-implement.out"
need "$TMP/frozen-implement.out" "Formal execution boundary must be materialized"
python3 "$MATERIALIZE" "$FORMAL_CONTEXT" --task-id 01 --role reviewer \
  --project-root "$TMP/project" --strict --execution-ready \
  --obsidian-wiki-cmd "definitely-missing-obsidian-command" >"$TMP/frozen-review.out"
need "$TMP/frozen-review.out" "Reviewer Handoff"

# Editing either user-visible task contract invalidates the readiness receipt.
cp "$IMPLEMENT_SNAPSHOT" "$TMP/implement.before-edit.md"
printf '\nEdited after approval.\n' >> "$IMPLEMENT_SNAPSHOT"
if python3 "$READINESS" validate --receipt "$FORMAL_RECEIPT" --task-id 01 >"$TMP/snapshot-drift.out" 2>&1; then
  fail "edited implementer snapshot must invalidate readiness"
fi
need "$TMP/snapshot-drift.out" "snapshot"
mv "$TMP/implement.before-edit.md" "$IMPLEMENT_SNAPSHOT"
python3 "$READINESS" validate --receipt "$FORMAL_RECEIPT" --task-id 01 >/dev/null

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
  state_receipt="$MANUAL_DIR/${status}.wiki-readiness.json"
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
  --receipt "$MANUAL_DIR/invalid-broken.wiki-readiness.json" \
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
need "$SNAPSHOT_CONTRACT" "bodyDigest"
need "$SNAPSHOT_CONTRACT" "taskFingerprint"
need "$SNAPSHOT_CONTRACT" "role"
need "$SNAPSHOT_CONTRACT" "freshnessEntries"
need "$APPROVAL_CONTRACT" "implementWikiDigest"
need "$APPROVAL_CONTRACT" "reviewWikiDigest"
need "$RESULT_CONTRACT" "grill-adapter.wiki-readiness-result"
need "$RESULT_CONTRACT" '"implementer"'
need "$RESULT_CONTRACT" '"reviewer"'
need "$RESULT_CONTRACT" '"status": "ready"'
need "$SKILL" "before the first code edit"
need "$SKILL" "wiki_readiness.py run"
need "$SKILL" "late-carry"
need "$SKILL" "wiki_readiness.py review"
need "$SKILL" "wiki-review-handoff.md"
need "$SKILL" "gh issue view"
need "$SKILL" "manual"
need "$SKILL" "Do not patch"

printf 'wiki readiness smoke OK\n'
