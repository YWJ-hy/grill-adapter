#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDER="${ROOT}/scripts/wiki_context_render.py"
READINESS="${ROOT}/scripts/wiki_readiness.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="${TMP}/project"
CONTEXT_DIR="${PROJECT}/.adapter/context"
mkdir -p "${PROJECT}/docs/adr" "${CONTEXT_DIR}"

cat > "${PROJECT}/docs/adr/0001-runtime.md" <<'MD'
# Runtime boundary

Future writes must preserve the runtime boundary.
MD

python3 - "${PROJECT}" "${CONTEXT_DIR}/selection.json" <<'PY'
import hashlib
import json
import pathlib
import sys

project, output = map(pathlib.Path, sys.argv[1:])
source_path = "docs/adr/0001-runtime.md"
source_id = "project-adr:" + hashlib.sha256(source_path.encode()).hexdigest()
content = (project / source_path).read_text()
content_hash = "sha256:" + hashlib.sha256(content.replace("\r\n", "\n").encode()).hexdigest()
selection = {
    "status": "ok",
    "phase": "plan",
    "snapshotHash": "sha256:" + "1" * 64,
    "wikiBindings": [{"sourceId": "project", "role": "project", "bindingDigest": "2" * 64}],
    "wikiNotes": [{
        "sourceId": "project",
        "role": "project",
        "path": "Notes/runtime.md",
        "wikiId": "runtime",
        "type": "constraint",
        "constraintStrength": "hard",
        "summary": "Runtime boundary",
        "contentHash": "sha256:" + "3" * 64,
        "bindingDigest": "2" * 64,
        "adrSourceId": source_id,
        "adrSourcePath": source_path,
        "adrSourceContentHash": content_hash,
    }],
    "requiredSkills": [],
}
output.write_text(json.dumps(selection), encoding="utf-8")
PY

CONTEXT="${CONTEXT_DIR}/feature.wiki-context.json"
python3 "${RENDER}" "${CONTEXT}" --scaffold "${CONTEXT_DIR}/selection.json" \
  --feature-slug feature --ticket-source manual --project-root "${PROJECT}" --strict --keep-selection >/dev/null

python3 - "${CONTEXT}" <<'PY'
import json
import sys
context = json.load(open(sys.argv[1], encoding="utf-8"))
note = context["wikiNotes"][0]
assert note["adrSourceId"].startswith("project-adr:")
assert note["adrSourcePath"] == "docs/adr/0001-runtime.md"
assert note["adrSourceContentHash"].startswith("sha256:")
assert "content" not in note
note["destination"] = {"kind": "task-bound", "reason": "runtime", "tasks": ["T1"]}
context["taskRouting"]["status"] = "confirmed"
context["taskRouting"]["selectedSectionsFrozen"] = True
json.dump(context, open(sys.argv[1], "w", encoding="utf-8"))
PY

ROSTER="${CONTEXT_DIR}/feature.ticket-roster.json"
cat > "${ROSTER}" <<'JSON'
{"featureSlug":"feature","ticketSource":"manual","tickets":[{"taskId":"T1","taskTitle":"Runtime","text":"Preserve runtime boundary."}]}
JSON
python3 "${RENDER}" "${CONTEXT}" --finalize --ticket-roster "${ROSTER}" \
  --project-root "${PROJECT}" --strict >/dev/null

BAD_ID_CONTEXT="${CONTEXT_DIR}/bad-id.wiki-context.json"
cp "${CONTEXT}" "${BAD_ID_CONTEXT}"
python3 - "${BAD_ID_CONTEXT}" <<'PY'
import json
import sys
path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["adrSourceId"] = "project-adr:" + "f" * 64
json.dump(context, open(path, "w", encoding="utf-8"))
PY
if python3 "${RENDER}" "${BAD_ID_CONTEXT}" --validate-only --project-root "${PROJECT}" --strict >/tmp/adr-id.out 2>&1; then
  echo "Expected an incorrect ADR source ID to fail validation" >&2
  exit 1
fi
grep -q "adrSourceId does not match adrSourcePath" /tmp/adr-id.out

python3 - "${ROOT}" "${PROJECT}" "${CONTEXT}" <<'PY'
import json
import pathlib
import sys

root, project, context_path = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root / "scripts"))
import wiki_materialize_task as materializer

context = json.loads(context_path.read_text(encoding="utf-8"))
expected = context["wikiNotes"][0]
actual = {
    **{key: expected[key] for key in (
        "sourceId", "role", "path", "wikiId", "type", "summary",
        "bindingDigest", "contentHash", "adrSourceId", "adrSourcePath",
        "adrSourceContentHash",
    )},
    "constraintStrength": "hard",
    "content": "AUTHORITATIVE ADR PROJECTION",
}

def fake_cli(_cmd, _project_root, request, subcommand):
    if subcommand == "read-notes-by-wiki-ids":
        return {"snapshotHash": "sha256:" + "4" * 64, "notes": [actual for _ in request["wikiIds"]]}
    return {"neighbors": {wiki_id: [] for wiki_id in request["wikiIds"]}}

materializer._invoke_obsidian_cli = fake_cli
result = materializer._materialize(context, "T1", "implementer", project, "unused")
assert result[0]["content"] == "AUTHORITATIVE ADR PROJECTION"
(project / "docs/adr/0001-runtime.md").write_text("# Runtime boundary\n\nChanged authority.\n", encoding="utf-8")
try:
    materializer._materialize(context, "T1", "implementer", project, "unused")
except materializer.MaterializeError as exc:
    assert "ADR projection authority validation failed" in str(exc)
else:
    raise AssertionError("expected Bind to reject ADR drift")
PY

printf '\nChanged ADR must fail Carry validation\n' >> "${PROJECT}/docs/adr/0001-runtime.md"
RECEIPT="${CONTEXT_DIR}/feature.wiki-readiness.json"
if python3 "${READINESS}" bind --receipt "${RECEIPT}" --roster "${ROSTER}" \
  --context "${CONTEXT}" --task-id T1 --project-root "${PROJECT}" \
  --reason "ADR authority must be checked before implementation." >/tmp/adr-bind.out 2>&1; then
  echo "Expected implementer Bind to fail on ADR authority drift" >&2
  exit 1
fi
grep -q "ADR authority validation failed\|ADR source content drift" /tmp/adr-bind.out

if python3 "${RENDER}" "${CONTEXT}" --validate-only --execution-ready --ticket-roster "${ROSTER}" \
  --project-root "${PROJECT}" --strict >/tmp/adr-drift.out 2>&1; then
  echo "Expected modified ADR to fail Carry validation" >&2
  exit 1
fi
grep -q "ADR source content drift" /tmp/adr-drift.out

rm "${PROJECT}/docs/adr/0001-runtime.md"
if python3 "${RENDER}" "${CONTEXT}" --validate-only --execution-ready --ticket-roster "${ROSTER}" \
  --project-root "${PROJECT}" --strict >/tmp/adr-missing.out 2>&1; then
  echo "Expected deleted ADR to fail Carry validation" >&2
  exit 1
fi
grep -q "ADR source file is missing" /tmp/adr-missing.out

python3 - "${CONTEXT}" <<'PY'
import json
import sys
path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
context["wikiNotes"][0]["adrSourcePath"] = "../outside/docs/adr/0001-runtime.md"
json.dump(context, open(path, "w", encoding="utf-8"))
PY
if python3 "${RENDER}" "${CONTEXT}" --validate-only --project-root "${PROJECT}" --strict >/tmp/adr-path.out 2>&1; then
  echo "Expected an escaping ADR path to fail validation" >&2
  exit 1
fi
grep -q "ADR source path" /tmp/adr-path.out

python3 "${READINESS}" record --receipt "${RECEIPT}" --roster "${ROSTER}" \
  --task-id T1 --status broken --reason "ADR authority drift; continue without Wiki." >/dev/null
HANDOFF="${CONTEXT_DIR}/feature.wiki-review.md"
python3 "${READINESS}" review-handoff --receipt "${RECEIPT}" --task-id T1 \
  --project-root "${PROJECT}" --handoff "${HANDOFF}" >/dev/null
grep -q "Status: broken" "${HANDOFF}"
grep -q "non-blocking caveat" "${HANDOFF}"

printf 'ADR projection identity smoke passed\n'
