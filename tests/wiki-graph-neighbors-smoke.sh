#!/usr/bin/env bash
set -euo pipefail

# Smoke test for bounded 1-hop neighbor query (wiki_graph_neighbors.py): the query that
# replaces "AI reads the whole .graph.json". Asserts output is bounded to requested
# nodes, carries out/in edges with type + an indexed flag, and degrades gracefully when
# the graph file is absent. Exercises the installed Superpowers target scripts.
# Usage: bash tests/wiki-graph-neighbors-smoke.sh [superpowers-target]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPTS="${TARGET_INPUT}/scripts"

TMP_PROJECT="$(mktemp -d)"
trap 'rm -rf "${TMP_PROJECT}"' EXIT

W="${TMP_PROJECT}/.superpowers/wiki"
mkdir -p "${W}"

cat > "${W}/index.md" <<'MD'
# Project Wiki
- `a.md`
- `b.md`
MD

# a.md is indexed; it depends on b (indexed) and see-also's c (NOT linked from index,
# so c gets no companion index → must come back indexed:false).
cat > "${W}/a.md" <<'MD'
# A
<!-- wiki-section:s1 -->
## S1
必须 follow [[depends-on: b.md#s2]] and also [[c.md#s3]].
<!-- /wiki-section:s1 -->
MD

cat > "${W}/b.md" <<'MD'
# B
<!-- wiki-section:s2 -->
## S2
body
<!-- /wiki-section:s2 -->
MD

cat > "${W}/c.md" <<'MD'
# C
<!-- wiki-section:s3 -->
## S3
body
<!-- /wiki-section:s3 -->
MD

python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-root project --project-root "${TMP_PROJECT}" >/dev/null

# --- Bounded query: out/in slices, edge type, indexed flag ---
out_json="$(python3 "${SCRIPTS}/wiki_graph_neighbors.py" --node "a.md#s1" --node "b.md#s2" --wiki-root project --project-root "${TMP_PROJECT}")"
python3 - <<'PY' "${out_json}"
import json, sys
r = json.loads(sys.argv[1])
n = r["neighbors"]
# Bounded: ONLY the requested nodes appear.
assert set(n) == {"a.md#s1", "b.md#s2"}, f"query not bounded to requested nodes: {set(n)}"

out = {(e["to"], e["type"], e["indexed"]) for e in n["a.md#s1"]["out"]}
assert ("b.md#s2", "depends-on", True) in out, f"missing indexed depends-on neighbor: {out}"
assert ("c.md#s3", "see-also", False) in out, f"unindexed neighbor not flagged indexed:false: {out}"
assert n["a.md#s1"]["in"] == [], f"unexpected backlinks into a#s1: {n['a.md#s1']['in']}"

inb = {(e["from"], e["type"], e["indexed"]) for e in n["b.md#s2"]["in"]}
assert ("a.md#s1", "depends-on", True) in inb, f"missing indexed backlink into b#s2: {inb}"
print("bounded neighbor query OK")
PY

# --- Display-prefixed / .md-less node ids resolve to the same slice (read-path parity) ---
# The wiki-researcher and materializer often hold a page as a display-root-prefixed path
# (.superpowers/wiki/...) or the .md-less form shown in [[page#section]] link text. These
# must resolve like the canonical id instead of silently returning empty edges.
variant_json="$(python3 "${SCRIPTS}/wiki_graph_neighbors.py" \
  --node ".superpowers/wiki/a.md#s1" \
  --node "a#s1" \
  --wiki-root project --project-root "${TMP_PROJECT}")"
python3 - <<'PY' "${variant_json}"
import json, sys
n = json.loads(sys.argv[1])["neighbors"]
# Keyed by the caller's original node strings, not the normalized form.
assert set(n) == {".superpowers/wiki/a.md#s1", "a#s1"}, f"variant keys not preserved: {set(n)}"
for node in (".superpowers/wiki/a.md#s1", "a#s1"):
    out = {(e["to"], e["type"], e["indexed"]) for e in n[node]["out"]}
    assert ("b.md#s2", "depends-on", True) in out, f"{node}: depends-on edge not resolved: {out}"
    assert ("c.md#s3", "see-also", False) in out, f"{node}: see-also edge not resolved: {out}"
print("prefixed / .md-less node resolution OK")
PY

# --- Unknown node yields an empty slice, still bounded ---
unknown_json="$(python3 "${SCRIPTS}/wiki_graph_neighbors.py" --node "missing.md#nope" --wiki-root project --project-root "${TMP_PROJECT}")"
python3 - <<'PY' "${unknown_json}"
import json, sys
r = json.loads(sys.argv[1])
assert r["neighbors"] == {"missing.md#nope": {"out": [], "in": []}}, f"unexpected unknown-node result: {r['neighbors']}"
print("unknown-node slice OK")
PY

# --- Missing .graph.json degrades to empty neighbors + caveat (non-fatal) ---
rm -f "${W}/.graph.json"
degrade_json="$(python3 "${SCRIPTS}/wiki_graph_neighbors.py" --node "a.md#s1" --wiki-root project --project-root "${TMP_PROJECT}")"
python3 - <<'PY' "${degrade_json}"
import json, sys
r = json.loads(sys.argv[1])
assert r["neighbors"] == {"a.md#s1": {"out": [], "in": []}}, f"expected empty neighbors on missing graph: {r['neighbors']}"
assert any(".graph.json not found" in c for c in r.get("caveats", [])), f"missing degrade caveat: {r.get('caveats')}"
print("missing-graph degradation OK")
PY

printf 'wiki-graph-neighbors-smoke complete\n'
