#!/usr/bin/env bash
set -euo pipefail

# Smoke test for axis-B typed nodes: page-level `type:` frontmatter flows into
# .graph.json pageTypes and the .index.md Type line; an unknown type is linted.
# Exercises the installed Superpowers target scripts.
# Usage: bash tests/wiki-page-type-smoke.sh [adapter-target]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPTS="${TARGET_INPUT}/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
git -C "${TMP}" init -q

W="${TMP}/.adapter/wiki"
mkdir -p "${W}"
printf '# W\n- `constraints.md`\n- `glossary.md`\n- `adr.md`\n- `legacy.md`\n' > "${W}/index.md"
# constraint: no frontmatter (default)
printf '# Rules\n<!-- wiki-section:r -->\nMUST do x\n<!-- /wiki-section:r -->\n' > "${W}/constraints.md"
printf -- '---\ntype: domain\n---\n# Glossary\n<!-- wiki-section:g -->\nA tenant is ...\n<!-- /wiki-section:g -->\n' > "${W}/glossary.md"
printf -- '---\ntype: decision\n---\n# ADR\n<!-- wiki-section:d -->\nWe chose cursors.\n<!-- /wiki-section:d -->\n' > "${W}/adr.md"
printf -- '---\ntype: bogus\n---\n# Legacy\n<!-- wiki-section:l -->\nold\n<!-- /wiki-section:l -->\n' > "${W}/legacy.md"

python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-root project --project-root "${TMP}" >/dev/null

python3 - <<'PY' "${W}/.graph.json"
import json, sys
g = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert g["schema"] == "section-graph/3", f"unexpected schema: {g['schema']}"
pt = g["pageTypes"]
assert pt.get("constraints.md") == "constraint", pt
assert pt.get("glossary.md") == "domain", pt
assert pt.get("adr.md") == "decision", pt
assert pt.get("legacy.md") == "bogus", pt
print("pageTypes OK")
PY

# .index.md carries the Type line; the default-constraint page also shows it.
case "$(cat "${W}/adr.index.md")" in
  *"> Type: decision"*) : ;;
  *) printf 'Expected "> Type: decision" in adr.index.md\n' >&2; exit 1 ;;
esac
case "$(cat "${W}/constraints.index.md")" in
  *"> Type: constraint"*) : ;;
  *) printf 'Expected "> Type: constraint" in constraints.index.md\n' >&2; exit 1 ;;
esac

# The Type metadata line must not pollute the page documentContext overview.
python3 - <<'PY' "${TARGET_INPUT}" "${W}/glossary.index.md"
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts")
from wiki_section import extract_document_context_from_index
ctx = extract_document_context_from_index(open(sys.argv[2], encoding="utf-8").read())
assert not (ctx.get("overview") or "").startswith("Type:"), ctx
print("documentContext clean OK")
PY

# Unknown page type is a lint warning (not a dangling-link warning).
check_json="$(cd "${TMP}" && python3 "${SCRIPTS}/wiki_update_check.py" --wiki-root project --json)"
python3 - <<'PY' "${check_json}"
import json, sys
r = json.loads(sys.argv[1])
type_warnings = [w for w in r["warnings"] if "Unknown page type" in w]
assert len(type_warnings) == 1, f"expected 1 unknown-page-type warning, got {type_warnings}"
assert "legacy.md" in type_warnings[0] and "bogus" in type_warnings[0], type_warnings
print("unknown-page-type lint OK")
PY

printf 'wiki-page-type-smoke complete\n'
