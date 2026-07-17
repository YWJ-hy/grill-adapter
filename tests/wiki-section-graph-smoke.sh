#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the section-level knowledge graph: typed [[type: page#section]] edge
# parsing, .graph.json output, a plain (relationship-free) .index.md table, and dangling /
# unknown-type lint. Exercises the installed Superpowers target scripts.
# Usage: bash tests/wiki-section-graph-smoke.sh [adapter-target] [project-root]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPTS="${TARGET_INPUT}/scripts"

TMP_PROJECT="$(mktemp -d)"
trap 'rm -rf "${TMP_PROJECT}"' EXIT

W="${TMP_PROJECT}/.adapter/wiki"
mkdir -p "${W}/backend"

cat > "${W}/index.md" <<'MD'
# Project Wiki
- `backend/`
MD

cat > "${W}/backend/index.md" <<'MD'
# Backend
- `contract.md`
- `data.md`
MD

cat > "${W}/backend/contract.md" <<'MD'
# Contract
<!-- wiki-section:response-format -->
## Response
必须 follow [[depends-on: backend/data#tx-rules]] and see the whole page [[backend/data]].
本节取代旧契约 [[supersedes: backend/data#tx-rules]].
Broken section [[backend/data#nope]] and missing page [[backend/ghost#x]].
Unknown type [[depend-on: backend/data#tx-rules]].
Inline `[[not-an-edge#z]]` and a plain link [text](backend/data.md#tx-rules) are ignored.
Not a type because no space [[http://example.com]] either.
<!-- /wiki-section:response-format -->
MD

cat > "${W}/backend/data.md" <<'MD'
# Data
<!-- wiki-section:tx-rules -->
## Tx
rules here
<!-- /wiki-section:tx-rules -->
MD

# --- Build the graph (--all) ---
python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-root project --project-root "${TMP_PROJECT}" >/dev/null

GRAPH="${W}/.graph.json"
if [[ ! -f "${GRAPH}" ]]; then
  printf 'Expected .graph.json to be generated\n' >&2
  exit 1
fi

python3 - <<'PY' "${GRAPH}"
import json, sys
g = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert g["schema"] == "section-graph/3", f"unexpected schema: {g['schema']}"

src = "backend/contract.md#response-format"
edges = {(e["from"], e["to"], e["type"]) for e in g["edges"]}
assert (src, "backend/data.md#tx-rules", "depends-on") in edges, "missing typed depends-on edge"
assert (src, "backend/data.md#tx-rules", "supersedes") in edges, "missing typed supersedes edge"
assert (src, "backend/data.md", "see-also") in edges, "missing default see-also page edge"
# Inline-code, plain markdown, and spaceless-colon URLs must not become edges.
assert all("not-an-edge" not in e["to"] for e in g["edges"]), "inline-code link leaked"
assert all("example.com" not in e["to"] for e in g["edges"]), "URL leaked as edge"
assert len(g["edges"]) == 3, f"unexpected edge count: {g['edges']}"

bl = g["backlinks"]["backend/data.md#tx-rules"]
bl_types = {b["type"] for b in bl}
assert all(b["from"] == src for b in bl), "backlink from wrong source"
assert bl_types == {"depends-on", "supersedes"}, f"unexpected backlink types: {bl_types}"
assert g["backlinks"]["backend/data.md"] == [{"from": src, "type": "see-also"}], "missing page backlink"

reasons = [d["reason"] for d in g["dangling"]]
assert len(g["dangling"]) == 4, f"unexpected dangling count: {g['dangling']}"
assert any("section 'nope' not found" in r for r in reasons), "missing dangling-section reason"
assert any("page does not exist" in r for r in reasons), "missing dangling-page reason"
assert any("unknown edge type 'depend-on'" in r for r in reasons), "missing unknown-type reason"
# A spaceless colon ([[http://...]]) is an external see-also, NOT a type named 'http'.
assert any("external or unsupported" in r for r in reasons), "missing external-ref reason"
assert not any("unknown edge type 'http'" in r for r in reasons), "URL was misparsed as a type"
print("graph.json OK")
PY

# --- Generated artifacts use LF newlines (deterministic across platforms) ---
python3 - "${GRAPH}" "${W}/backend/contract.index.md" "${W}/backend/data.index.md" <<'PY'
import sys
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        data = handle.read()
    assert b"\r\n" not in data, f"{path} has CRLF; generated wiki artifacts must be LF"
print("LF line endings OK")
PY

# --- .index.md renders a plain section table; relationships live ONLY in .graph.json ---
contract_index="$(cat "${W}/backend/contract.index.md")"
case "${contract_index}" in
  *"| section | 描述 | 约束强度 |"*) : ;;
  *) printf 'Expected plain 3-column section table in contract.index.md\n' >&2; exit 1 ;;
esac
# The relation column was removed: no 关联 / 引用 / 被引用 column and no edge targets
# rendered into the index (those are queried from .graph.json, asserted above).
case "${contract_index}" in
  *关联*|*引用*|*被引用*|*"backend/data#tx-rules"*)
    printf 'Relationship rendering leaked into contract.index.md (should live only in .graph.json)\n' >&2; exit 1 ;;
  *) : ;;
esac

# --- Single-file mode also rebuilds the root graph (update-wiki uses this path) ---
rm -f "${GRAPH}"
python3 "${SCRIPTS}/wiki_generate_section_index.py" backend/contract.md --wiki-root project --project-root "${TMP_PROJECT}" >/dev/null
if [[ ! -f "${GRAPH}" ]]; then
  printf 'Expected single-file mode to rebuild .graph.json\n' >&2
  exit 1
fi
python3 - <<'PY' "${GRAPH}"
import json, sys
g = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert len(g["edges"]) == 3, "single-file rebuild lost edges"
assert len(g["dangling"]) == 4, "single-file rebuild lost dangling"
print("single-file rebuild OK")
PY

# --- Dangling and unknown-type links are reported as warnings by the validator ---
check_json="$(cd "${TMP_PROJECT}" && python3 "${SCRIPTS}/wiki_update_check.py" --wiki-root project --json)"
python3 - <<'PY' "${check_json}"
import json, sys
r = json.loads(sys.argv[1])
assert r["status"] == "warning", f"expected warning status, got {r['status']}"
root = r["roots"][0]
assert root.get("danglingSectionLinks") == 4, f"expected 4 dangling links, got {root.get('danglingSectionLinks')}"
dangling_warnings = [w for w in r["warnings"] if "dangling section link" in w]
assert len(dangling_warnings) == 4, f"expected 4 dangling warnings, got {dangling_warnings}"
assert any("unknown edge type" in w for w in dangling_warnings), "expected an unknown-type warning"
print("dangling/unknown-type lint OK")
PY

printf 'wiki-section-graph-smoke complete\n'
