#!/usr/bin/env bash
set -euo pipefail

# A researcher may surface a candidate that the planner verifies as unrelated. The planner
# must be able to preserve that audit trail without routing the Note into execution context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
RENDER="${ROOT}/scripts/wiki_context_render.py"
MATERIALIZE="${ROOT}/scripts/wiki_materialize_task.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
CTX_DIR="$PROJECT/.grill-adapter/context"
mkdir -p "$CTX_DIR"
CONTEXT="$CTX_DIR/feature.wiki-context.json"
ROSTER="$CTX_DIR/feature.ticket-roster.json"
SELECTION="$TMP/feature.selection.json"

SHA_A="$(printf 'a%.0s' {1..64})"
SHA_B="$(printf 'b%.0s' {1..64})"
SHA_C="$(printf 'c%.0s' {1..64})"

cat >"$SELECTION" <<JSON
{
  "status": "ok",
  "phase": "plan",
  "snapshotHash": "sha256:${SHA_A}",
  "wikiBindings": [
    {"sourceId":"project","role":"project","bindingDigest":"${SHA_B}"}
  ],
  "wikiNotes": [
    {
      "sourceId":"project",
      "role":"project",
      "path":"Notes/applicable.md",
      "wikiId":"applicable",
      "type":"constraint",
      "constraintStrength":"hard",
      "summary":"The implementation must preserve the requested boundary.",
      "contentHash":"sha256:${SHA_A}",
      "bindingDigest":"${SHA_B}"
    },
    {
      "sourceId":"project",
      "role":"project",
      "path":"Notes/unrelated.md",
      "wikiId":"unrelated",
      "type":"constraint",
      "constraintStrength":"hard",
      "summary":"This Note applies to a different feature.",
      "contentHash":"sha256:${SHA_C}",
      "bindingDigest":"${SHA_B}"
    }
  ],
  "requiredSkills": [],
  "caveats": [],
  "maintenanceWarnings": []
}
JSON

cat >"$ROSTER" <<'JSON'
{
  "featureSlug": "feature",
  "ticketSource": "manual",
  "tickets": [
    {
      "taskId": "T1",
      "taskTitle": "Implement requested boundary",
      "text": "Implement the requested boundary."
    }
  ]
}
JSON

python3 "$RENDER" "$CONTEXT" --scaffold "$SELECTION" \
  --feature-slug feature --ticket-source manual --strict >/dev/null

python3 - "$CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["wikiNotes"][0]["destination"] = {
    "kind": "task-bound",
    "reason": "Directly applies to T1.",
    "tasks": ["T1"],
}
data["wikiNotes"][1]["destination"] = {
    "kind": "not-applicable",
    "reason": "Planner verified that this Note targets another feature.",
}
data["taskRouting"]["status"] = "confirmed"
data["taskRouting"]["selectedSectionsFrozen"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY

python3 "$RENDER" "$CONTEXT" --finalize --strict --ticket-roster "$ROSTER" >/dev/null
OUT="$(python3 "$RENDER" "$CONTEXT" --task-id T1 --role implementer --reread-list --strict --execution-ready)"
grep -Fq '"wikiId": "applicable"' <<<"$OUT"
if grep -Fq '"wikiId": "unrelated"' <<<"$OUT"; then
  printf 'unrelated Note leaked into task reread list\n' >&2
  exit 1
fi

FAKE="$TMP/fake-obsidian.py"
cat >"$FAKE" <<'PY'
import json
import sys

request = json.load(sys.stdin)
if sys.argv[1] == "read-notes-by-wiki-ids":
    assert request == {"wikiIds": ["applicable"]}
    print(json.dumps({
        "snapshotHash": "sha256:" + "a" * 64,
        "notes": [{
            "sourceId": "project",
            "role": "project",
            "path": "Notes/applicable.md",
            "wikiId": "applicable",
            "type": "constraint",
            "constraintStrength": "hard",
            "summary": "The implementation must preserve the requested boundary.",
            "contentHash": "sha256:" + "a" * 64,
            "bindingDigest": "b" * 64,
            "content": "APPLICABLE NOTE",
        }],
    }))
elif sys.argv[1] == "graph-neighbors":
    assert request == {"wikiIds": ["applicable"]}
    print(json.dumps({"neighbors": {"applicable": []}}))
else:
    raise SystemExit(f"unexpected command: {sys.argv[1]}")
PY

if command -v cygpath >/dev/null 2>&1; then
  FAKE_ARG="$(cygpath -m "$FAKE")"
else
  FAKE_ARG="$FAKE"
fi
MCP_CMD="python3 ${FAKE_ARG}"
MATERIALIZED="$(python3 "$MATERIALIZE" "$CONTEXT" --task-id T1 --role implementer \
  --project-root "$PROJECT" --strict --execution-ready --obsidian-wiki-cmd "$MCP_CMD")"
grep -Fq 'APPLICABLE NOTE' <<<"$MATERIALIZED"
if grep -Fq 'unrelated' <<<"$MATERIALIZED"; then
  printf 'unrelated Note leaked into materialized execution context\n' >&2
  exit 1
fi

printf 'wiki routing exclusion smoke passed\n'
