#!/usr/bin/env bash
set -euo pipefail

# Smoke for section-summary handling and the migrate-helper backfill loop:
#  - an authored summary="…" is rendered verbatim in the index (no 140-char cap)
#  - a section without a summary falls back to a mechanical excerpt capped at 140 chars
#  - wiki_migrate_helper --missing-summaries / --with-body / --set-summaries round-trip
# Exercises the installed Superpowers target scripts (repo-root wiki layout via --wiki-dir).
# Usage: bash tests/wiki-summary-backfill-smoke.sh [superpowers-target]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPTS="${TARGET_INPUT}/scripts"

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT

# Build the wiki fixture via python so Unicode is exact regardless of shell.
PYTHONIOENCODING=utf-8 python3 - "${W}" <<'PY'
import sys
from pathlib import Path
d = Path(sys.argv[1])
(d / "index.md").write_text("# Wiki\n- `a.md`\n", encoding="utf-8")
long_sum = "长" * 160          # authored summary well over 140 chars
long_body = "文" * 200          # body over 140 chars, for the mechanical-fallback section
(d / "a.md").write_text(
    "# A\n"
    '<!-- wiki-section:has-short summary="短总结" -->\n## H1\nshort body\n<!-- /wiki-section:has-short -->\n'
    f'<!-- wiki-section:has-long summary="{long_sum}" -->\n## H2\nshort body\n<!-- /wiki-section:has-long -->\n'
    f"<!-- wiki-section:no-sum -->\n## H3\n{long_body}\n<!-- /wiki-section:no-sum -->\n",
    encoding="utf-8",
)
PY

cell () { # cell <index-file> <section-id> -> the description cell text
  PYTHONIOENCODING=utf-8 python3 - "$1" "$2" <<'PY'
import sys
sid = sys.argv[2]
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.split("|")
    if len(parts) >= 4 and parts[1].strip() == sid:
        print(parts[2].strip())
        break
PY
}

# --- 1. Before backfill: mechanical fallback for no-sum is capped at 140 ---
PYTHONIOENCODING=utf-8 python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-dir "${W}" >/dev/null
NO_SUM_DESC="$(cell "${W}/a.index.md" no-sum)"
NO_SUM_LEN="$(printf '%s' "${NO_SUM_DESC}" | PYTHONIOENCODING=utf-8 python3 -c "import sys;print(len(sys.stdin.read()))")"
case "${NO_SUM_DESC}" in
  *…) : ;;
  *) printf 'Expected mechanical fallback to be truncated with … : %s\n' "${NO_SUM_DESC}" >&2; exit 1 ;;
esac
if [[ "${NO_SUM_LEN}" -gt 141 ]]; then
  printf 'Mechanical fallback exceeded 140(+…): len=%s\n' "${NO_SUM_LEN}" >&2; exit 1
fi
printf 'mechanical fallback capped at 140 OK (len=%s)\n' "${NO_SUM_LEN}"

# --- 2. Authored summaries render verbatim; the >140 one is NOT truncated ---
[[ "$(cell "${W}/a.index.md" has-short)" == "短总结" ]] || { printf 'short authored summary not verbatim\n' >&2; exit 1; }
HAS_LONG_DESC="$(cell "${W}/a.index.md" has-long)"
HAS_LONG_LEN="$(printf '%s' "${HAS_LONG_DESC}" | PYTHONIOENCODING=utf-8 python3 -c "import sys;print(len(sys.stdin.read()))")"
case "${HAS_LONG_DESC}" in
  *…) printf 'Authored >140 summary was truncated (should be verbatim)\n' >&2; exit 1 ;;
esac
[[ "${HAS_LONG_LEN}" -eq 160 ]] || { printf 'Authored >140 summary not verbatim: len=%s\n' "${HAS_LONG_LEN}" >&2; exit 1; }
printf 'authored summary verbatim, no 140 cap OK (len=%s)\n' "${HAS_LONG_LEN}"

# --- 3. --missing-summaries --with-body lists only no-sum, with its body ---
MISSING_JSON="$(PYTHONIOENCODING=utf-8 python3 "${SCRIPTS}/wiki_migrate_helper.py" --missing-summaries "${W}" --wiki-dir "${W}" --with-body --json)"
PYTHONIOENCODING=utf-8 python3 - "${MISSING_JSON}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
ids = {d["sectionId"] for d in data}
assert ids == {"no-sum"}, f"missing-summaries should list only no-sum, got {ids}"
assert data[0]["body"].strip(), "missing-summaries --with-body should include the section body"
print("missing-summaries --with-body OK")
PY

# --- 4. --set-summaries writes the summary; missing set becomes empty ---
printf '{"path":"a.md","sectionId":"no-sum","summary":"补写的主题总结"}\n' \
  | PYTHONIOENCODING=utf-8 python3 "${SCRIPTS}/wiki_migrate_helper.py" --set-summaries "${W}" --wiki-dir "${W}" >/dev/null
STILL_MISSING="$(PYTHONIOENCODING=utf-8 python3 "${SCRIPTS}/wiki_migrate_helper.py" --missing-summaries "${W}" --wiki-dir "${W}" --json)"
[[ "$(printf '%s' "${STILL_MISSING}" | tr -d '[:space:]')" == "[]" ]] || { printf 'Expected no missing summaries after set: %s\n' "${STILL_MISSING}" >&2; exit 1; }

# --- 5. Regenerate: no-sum now shows the authored summary, not the mechanical excerpt ---
PYTHONIOENCODING=utf-8 python3 "${SCRIPTS}/wiki_generate_section_index.py" --all --wiki-dir "${W}" >/dev/null
[[ "$(cell "${W}/a.index.md" no-sum)" == "补写的主题总结" ]] || { printf 'set-summaries not reflected in index\n' >&2; exit 1; }
printf 'set-summaries round-trip OK\n'

printf 'wiki-summary-backfill-smoke complete\n'
