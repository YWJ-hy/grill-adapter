#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
agent = (root / "agents" / "wiki-researcher.md").read_text(encoding="utf-8")
skill = (root / "skills" / "wiki-research" / "SKILL.md").read_text(encoding="utf-8")

for required in (
    "obsidian_wiki_catalog",
    "Before any keyword search",
    "sourceId` and Source-relative `pathPrefix",
    "Always set a hard `limit`",
    "page.nextCursor",
    "deliberately omit Note body and `contentHash`",
    "stable-path ordered",
    "at most eight candidates",
    "one second candidate batch",
    "full Note/Card bodies",
    "Treat direct neighbors as new candidates",
    "single `snapshotHash`",
    "selectionRationales",
    "array** (never an object/map)",
    "status: \"ok\"` or `\"partial\"`",
    "Never emit `content`, body excerpts, quotations",
):
    assert required in agent, required

for required in (
    "Do not call any `obsidian_wiki_*` tool, including `obsidian_wiki_catalog`",
    "A main-agent search is never a substitute",
    "Carry validates but deliberately drops `selectionRationales`",
    "Never scan whole Wiki trees",
):
    assert required in skill, required
PY

printf 'wiki researcher contract smoke OK\n'
