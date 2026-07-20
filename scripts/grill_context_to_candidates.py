#!/usr/bin/env python3
"""grill -> wiki authoring bridge.

grill writes its knowledge as a flat glossary in `CONTEXT.md` and decision records
under `docs/adr/`. Those are grill's tier-1 knowledge; the wiki is tier-2 (sectioned,
typed, cross-repo). This bridge does NOT do the semantic upgrade — it only converts the
*increment* in CONTEXT.md / ADRs into candidate events appended to a feature-scoped
`.wiki-candidates.jsonl` journal. `update-wiki` then consumes those events like any other
candidate input:
it applies the durable gate, sectionizes, sets `type:`, adds `[[page#section]]` edges,
dedups, neutralizes, and authorizes. `update-wiki` only ever sees candidate events and never
learns about CONTEXT.md, so it stays grill-agnostic (blueprint §9).

Do NOT route grill knowledge through `import-wiki` — that is a flat structural copy and
would land a graph-less flat page. Bulk one-time backfill goes import-wiki -> migrate-wiki;
day-to-day increments go through this bridge -> update-wiki.

Each candidate is wrapped in the schema-v1 event contract owned by
`wiki_candidate_journal.py`. Stable candidate IDs make identical replay an idempotent no-op
while conflicting content fails closed, and a batch is validated before any event is appended.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

from wiki_candidate_journal import append_events, new_event


# --- glossary parsing -------------------------------------------------------

# grill CONTEXT.md glossary entries, tolerant of the common markdown shapes:
#   - **Term** — definition
#   - **Term**: definition
#   * **Term** - definition
_BULLET_TERM = re.compile(r"^\s*[-*]\s+\*\*(?P<term>[^*]+?)\*\*\s*[—:\-]\s*(?P<defn>.+?)\s*$")
# Heading-style term: `### Term`
_HEADING_TERM = re.compile(r"^#{2,6}\s+(?P<term>.+?)\s*$")


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def parse_glossary(lines: list[str], source_ref: str) -> list[dict]:
    """Turn glossary-looking lines into convention candidates.

    Bullet entries carry their own definition on the line. Heading entries take the first
    following non-empty, non-heading line as the definition.
    """
    candidates: list[dict] = []
    seen: set[str] = set()
    n = len(lines)
    for i, raw in enumerate(lines):
        m = _BULLET_TERM.match(raw)
        if m:
            term = _clean(m.group("term"))
            defn = _clean(m.group("defn"))
        else:
            h = _HEADING_TERM.match(raw)
            if not h:
                continue
            term = _clean(h.group("term"))
            defn = ""
            for j in range(i + 1, min(i + 6, n)):
                nxt = lines[j].strip()
                if not nxt or nxt.startswith("#"):
                    if nxt.startswith("#"):
                        break
                    continue
                defn = _clean(nxt)
                break
        if not term or not defn:
            continue
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "taskId": None,
            "kind": "convention",
            "claim": f"{term}: {defn}"[:400],
            "why": "Captured from the grill CONTEXT.md glossary; verify it is a durable, project-wide term before persisting.",
            "sourceRefs": [source_ref],
            "carveOut": "",
            "origin": "grill-context",
        })
    return candidates


# --- ADR parsing ------------------------------------------------------------

_MD_HEADING = re.compile(r"^#{1,6}\s+(?P<title>.+?)\s*$")


def _section(text: str, *names: str) -> str:
    """Return the body of the first matching `## <name>` section (case-insensitive)."""
    lines = text.splitlines()
    lowered = {name.lower() for name in names}
    out: list[str] = []
    capturing = False
    for line in lines:
        h = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if h:
            if capturing:
                break
            title = h.group(1).strip().lower().lstrip("0123456789. )")
            if any(title.startswith(n) for n in lowered):
                capturing = True
            continue
        if capturing and line.strip():
            out.append(line.strip())
    return _clean(" ".join(out))


def parse_adr(text: str, source_ref: str) -> dict | None:
    title = ""
    for line in text.splitlines():
        h = _MD_HEADING.match(line)
        if h:
            title = _clean(h.group("title"))
            break
    if not title:
        title = Path(source_ref).stem.replace("-", " ").replace("_", " ").strip()
    decision = _section(text, "decision")
    context = _section(text, "context")
    consequences = _section(text, "consequences", "conséquences")
    claim = title if not decision else f"{title} — {decision}"
    why_parts = [p for p in (context, consequences) if p]
    why = " / ".join(why_parts) if why_parts else "Architecture decision record captured from grill docs/adr."
    if not claim.strip():
        return None
    return {
        "taskId": None,
        "kind": "decision",
        "claim": claim[:400],
        "why": why[:600],
        "sourceRefs": [source_ref],
        "carveOut": "",
        "origin": "grill-context",
    }


# --- git-backed increment discovery ----------------------------------------

def _git(repo_root: Path, *args: str) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        return proc.returncode, proc.stdout
    except FileNotFoundError:
        return 127, ""


def _added_lines(repo_root: Path, rel: str, since: str | None) -> list[str] | None:
    """Return added (+) lines of `rel` relative to `since` (or working tree vs HEAD).

    None means "no diff basis available" (not a git repo, or path untracked with no ref)."""
    diff_args = ["diff", "--no-color", "-U0"]
    if since:
        diff_args.append(since)
    diff_args += ["--", rel]
    code, out = _git(repo_root, *diff_args)
    if code != 0:
        return None
    added: list[str] = []
    for line in out.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            added.append(line[1:])
    return added


def _changed_adr_files(repo_root: Path, adr_dir: str, since: str | None) -> list[str]:
    args = ["diff", "--name-status", "--no-color"]
    if since:
        args.append(since)
    args += ["--", adr_dir]
    code, out = _git(repo_root, *args)
    if code != 0:
        return []
    files: list[str] = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0][:1] in {"A", "M"}:
            files.append(parts[-1])
    return files


# --- main -------------------------------------------------------------------

def collect(repo_root: Path, context_rel: str, adr_dir: str, since: str | None,
            all_content: bool) -> list[dict]:
    candidates: list[dict] = []

    context_path = repo_root / context_rel
    if context_path.is_file():
        if all_content:
            lines = context_path.read_text(encoding="utf-8", errors="replace").splitlines()
        else:
            added = _added_lines(repo_root, context_rel, since)
            lines = added if added is not None else []
        candidates.extend(parse_glossary(lines, context_rel))

    adr_root = repo_root / adr_dir
    if adr_root.is_dir():
        if all_content:
            adr_files = sorted(
                p.relative_to(repo_root).as_posix()
                for p in adr_root.rglob("*.md")
            )
        else:
            adr_files = _changed_adr_files(repo_root, adr_dir, since)
        for rel in adr_files:
            p = repo_root / rel
            if not p.is_file():
                continue
            cand = parse_adr(p.read_text(encoding="utf-8", errors="replace"), rel)
            if cand:
                candidates.append(cand)

    return candidates


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (OSError, ValueError):
            pass


def _candidate_id(candidate: dict) -> str:
    identity = json.dumps(
        {
            "kind": candidate["kind"],
            "claim": candidate["claim"],
            "sourceRefs": candidate["sourceRefs"],
            "origin": candidate["origin"],
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return "grill-" + hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]


def _candidate_event(candidate: dict, feature_slug: str) -> dict:
    return new_event(
        "candidate",
        feature_slug,
        candidateId=_candidate_id(candidate),
        stage="capture",
        candidateType="wiki_note",
        kind=candidate["kind"],
        claim=candidate["claim"],
        why=candidate["why"],
        sourceRefs=candidate["sourceRefs"],
        taskId=candidate["taskId"],
        carveOut=bool(candidate["carveOut"]),
        origin=candidate["origin"],
    )


def main() -> int:
    _configure_stdio()
    parser = argparse.ArgumentParser(
        description="Convert grill CONTEXT.md / docs/adr increments into candidate journal events.")
    parser.add_argument("repo_root", help="Repo root containing CONTEXT.md and docs/adr/")
    parser.add_argument("--feature-slug", required=True, help="Feature identity shared by the workflow journal")
    parser.add_argument("--context", default="CONTEXT.md", help="Path to the grill glossary, relative to repo root")
    parser.add_argument("--adr-dir", default="docs/adr", help="ADR directory, relative to repo root")
    parser.add_argument("--since", default=None, help="Git ref to diff against (default: working tree vs HEAD)")
    parser.add_argument("--all", action="store_true", help="Convert the entire current CONTEXT.md + all ADRs, ignoring git diff (backfill/testing)")
    parser.add_argument("--out", default=None, help="Journal path (default: <repo-root>/.adapter/context/<feature-slug>.wiki-candidates.jsonl)")
    parser.add_argument("--stdout", action="store_true", help="Write events to stdout instead of appending to a journal")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).expanduser().resolve()
    if not repo_root.is_dir():
        raise SystemExit(f"Not a directory: {repo_root}")

    candidates = collect(repo_root, args.context, args.adr_dir, args.since, args.all)
    events = [_candidate_event(candidate, args.feature_slug) for candidate in candidates]

    lines = "".join(json.dumps(event, ensure_ascii=False) + "\n" for event in events)
    if args.stdout:
        sys.stdout.write(lines)
    else:
        out_path = (
            Path(args.out).expanduser().resolve()
            if args.out
            else repo_root / ".adapter" / "context" / f"{args.feature_slug}.wiki-candidates.jsonl"
        )
        appended, skipped = append_events(
            out_path,
            events,
            args.feature_slug,
            allow_identical_candidates=True,
        )
        print(
            f"Appended {appended} candidate event(s) to {out_path}; "
            f"skipped {skipped} identical event(s)",
            file=sys.stderr,
        )

    if not candidates:
        print("No CONTEXT.md/ADR increment found to convert (this is fine — nothing durable to hand off).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
