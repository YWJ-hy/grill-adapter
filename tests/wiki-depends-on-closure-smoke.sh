#!/usr/bin/env bash
set -euo pipefail

# Smoke test for P3b depends-on selection-time closure: a hard-constraint section's
# depends-on target is pulled into the reread list (1-hop, bounded) and is readable
# end-to-end; a see-also edge is NOT closed. Exercises installed target scripts.
# Usage: bash tests/wiki-depends-on-closure-smoke.sh [superpowers-target]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPTS="${TARGET_INPUT}/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
git -C "${TMP}" init -q

W="${TMP}/.superpowers/wiki"
mkdir -p "${W}/backend"
printf '# W\n- `backend/`\n' > "${W}/index.md"
printf '# B\n- `contract.md`\n- `data.md`\n' > "${W}/backend/index.md"
printf '# D\n<!-- wiki-section:tx-rules -->\n## Tx\nMUST_BE_CURSOR_RULE\n<!-- /wiki-section:tx-rules -->\n' > "${W}/backend/data.md"

write_contract() {  # $1 = edge type prefix ("depends-on: " or "")
  printf '# C\n<!-- wiki-section:resp -->\n## R\n必须遵循 [[%sbackend/data#tx-rules]]\n<!-- /wiki-section:resp -->\n' "$1" > "${W}/backend/contract.md"
}

write_sidecar() {
  cat > "${TMP}/side.wiki-context.json" <<'JSON'
{
  "schemaVersion": 4,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "planPath": "docs/superpowers/plans/example.md",
  "taskRouting": {"status": "confirmed", "selectedSectionsFrozen": true},
  "wikiPages": [
    {
      "root": "project",
      "source": "local",
      "displayPath": ".superpowers/wiki/backend/contract.md",
      "localPath": "backend/contract.md",
      "documentContext": {"title": "Contract", "overview": "Response rules."},
      "sections": [
        {
          "sectionId": "resp",
          "relevance": "direct",
          "reason": "in scope",
          "hardConstraint": true,
          "destination": {"kind": "global", "reason": "applies to all tasks"},
          "constraints": {"implementation": ["follow rules"], "test": [], "review": [], "general": []},
          "reread": {"root": "project", "source": "local", "localPath": "backend/contract.md", "sectionId": "resp", "includeDocumentContext": true}
        }
      ],
      "caveats": []
    }
  ],
  "taskWikiRefs": [],
  "caveats": []
}
JSON
}

# --- Positive: depends-on closes 1-hop ---
write_contract "depends-on: "
write_sidecar
python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-root project --project-root "${TMP}" >/dev/null
rr="$(cd "${TMP}" && python3 "${SCRIPTS}/wiki_context_render.py" side.wiki-context.json --reread-list)"
python3 - <<'PY' "${rr}"
import json, sys
lines = [json.loads(l) for l in sys.argv[1].splitlines() if l.strip()]
assert len(lines) == 2, f"expected direct + closure reread, got {len(lines)}: {lines}"
direct = [e for e in lines if e.get("closureType") is None]
closure = [e for e in lines if e.get("closureType") == "depends-on"]
assert len(direct) == 1 and direct[0]["sectionId"] == "resp", direct
assert len(closure) == 1, closure
assert closure[0]["localPath"] == "backend/data.md" and closure[0]["sectionId"] == "tx-rules", closure
assert closure[0]["closedVia"] == "backend/contract.md#resp", closure
print("closure entry OK")
PY

# End-to-end: the closure target section text is actually readable via the batch reader.
out="$(cd "${TMP}" && printf '%s\n' "${rr}" | python3 "${SCRIPTS}/wiki_read_section.py" --batch-jsonl --project-root "${TMP}" --include-document-context)"
case "${out}" in
  *MUST_BE_CURSOR_RULE*) printf '  ✓ closure target section text injected\n' ;;
  *) printf 'FAIL: closure target section not read end-to-end\n' >&2; exit 1 ;;
esac

# --- Negative: a see-also edge is NOT closed ---
write_contract ""   # bare [[ ]] = see-also
write_sidecar
python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-root project --project-root "${TMP}" >/dev/null
rr2="$(cd "${TMP}" && python3 "${SCRIPTS}/wiki_context_render.py" side.wiki-context.json --reread-list)"
python3 - <<'PY' "${rr2}"
import json, sys
lines = [json.loads(l) for l in sys.argv[1].splitlines() if l.strip()]
assert len(lines) == 1, f"see-also must NOT be closed; got {len(lines)} entries: {lines}"
assert all(e.get("closureType") is None for e in lines), lines
print("see-also not closed OK")
PY

# --- Shared-local: a locally checked-out shared wiki closes depends-on the same way ---
# Same depends-on shape under .shared-superpowers/wiki with a shared-root local hard section;
# the closure entry must carry root "shared" so the materializer reads it from the shared root.
SW="${TMP}/.shared-superpowers/wiki"
mkdir -p "${SW}/backend"
printf '# W\n- `backend/`\n' > "${SW}/index.md"
printf '# B\n- `contract.md`\n- `data.md`\n' > "${SW}/backend/index.md"
printf '# D\n<!-- wiki-section:tx-rules -->\n## Tx\nSHARED_CURSOR_RULE\n<!-- /wiki-section:tx-rules -->\n' > "${SW}/backend/data.md"
printf '# C\n<!-- wiki-section:resp -->\n## R\n必须遵循 [[depends-on: backend/data#tx-rules]]\n<!-- /wiki-section:resp -->\n' > "${SW}/backend/contract.md"
cat > "${TMP}/shared.wiki-context.json" <<'JSON'
{
  "schemaVersion": 4,
  "kind": "grill-adapter.wiki-context",
  "generatedBy": "grill-adapter",
  "taskRouting": {"status": "confirmed", "selectedSectionsFrozen": true},
  "wikiPages": [
    {
      "root": "shared",
      "source": "local",
      "displayPath": ".shared-superpowers/wiki/backend/contract.md",
      "localPath": "backend/contract.md",
      "documentContext": {"title": "Contract", "overview": "Response rules."},
      "sections": [
        {
          "sectionId": "resp",
          "relevance": "direct",
          "reason": "in scope",
          "hardConstraint": true,
          "destination": {"kind": "global", "reason": "applies to all tasks"},
          "constraints": {"implementation": ["follow rules"], "test": [], "review": [], "general": []},
          "reread": {"root": "shared", "source": "local", "localPath": "backend/contract.md", "sectionId": "resp", "includeDocumentContext": true}
        }
      ],
      "caveats": []
    }
  ],
  "taskWikiRefs": [],
  "caveats": []
}
JSON
python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-root shared --project-root "${TMP}" >/dev/null
rr3="$(cd "${TMP}" && python3 "${SCRIPTS}/wiki_context_render.py" shared.wiki-context.json --reread-list)"
python3 - <<'PY' "${rr3}"
import json, sys
lines = [json.loads(l) for l in sys.argv[1].splitlines() if l.strip()]
assert len(lines) == 2, f"expected direct + shared closure reread, got {len(lines)}: {lines}"
closure = [e for e in lines if e.get("closureType") == "depends-on"]
assert len(closure) == 1, closure
assert closure[0]["root"] == "shared", closure
assert closure[0]["localPath"] == "backend/data.md" and closure[0]["sectionId"] == "tx-rules", closure
assert closure[0]["closedVia"] == "backend/contract.md#resp", closure
print("shared-local closure entry OK")
PY

printf 'wiki-depends-on-closure-smoke complete\n'
