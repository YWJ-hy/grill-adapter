#!/usr/bin/env python3
"""Render an ADR execution-projection Note from a validated bridge candidate."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from wiki_candidate_journal import JournalError, validate_event_shape


SKIP_REASON = "Authoritative ADR has no durable execution constraint; no projection created."


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (OSError, ValueError):
            pass


def _single_line(value: str, field: str) -> str:
    text = value.strip()
    if not text or "\n" in text or "\r" in text:
        raise JournalError(f"{field} must be one non-empty line")
    return text


def render_projection(event: dict, constraints: str, wiki_id: str, title: str) -> str | None:
    validate_event_shape(event)
    if event.get("eventType") != "candidate" or event.get("kind") != "adr_execution_projection":
        raise JournalError("candidate event must be an adr_execution_projection")
    projection = event["adrProjection"]
    constraint_body = constraints.strip()
    if not constraint_body:
        return None
    normalized_constraints = "\n".join(
        line.rstrip() for line in constraint_body.splitlines()
    )
    return (
        "---\n"
        "wiki_schema: grill-adapter.obsidian-note/v1\n"
        f"wiki_id: {_single_line(wiki_id, 'wikiId')}\n"
        "type: constraint\n"
        "status: active\n"
        "agent_visible: true\n"
        f"summary: {_single_line(title, 'title')} execution constraints projected from the authoritative project ADR.\n"
        "constraint_strength: hard\n"
        f"adr_source_id: {projection['sourceId']}\n"
        f"adr_source_path: {projection['sourcePath']}\n"
        f"adr_source_content_hash: {projection['sourceContentHash']}\n"
        "---\n\n"
        f"# {_single_line(title, 'title')} - execution constraints\n\n"
        "> Derived projection. The project ADR identified above is authoritative for context, "
        "options, rationale, status, and consequences. Edit the ADR, then regenerate this "
        "projection.\n\n"
        f"{normalized_constraints}\n"
    )


def main() -> int:
    _configure_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, help="Path to one bridge candidate event JSON")
    parser.add_argument("--constraints", required=True, help="Path to agent-reviewed constraints Markdown")
    parser.add_argument("--wiki-id", required=True)
    parser.add_argument("--title", required=True)
    args = parser.parse_args()

    try:
        event = json.loads(Path(args.candidate).read_text(encoding="utf-8"))
        constraints = Path(args.constraints).read_text(encoding="utf-8")
        rendered = render_projection(event, constraints, args.wiki_id, args.title)
    except (OSError, json.JSONDecodeError, JournalError) as exc:
        print(f"ADR projection error: {exc}", file=sys.stderr)
        return 2
    if rendered is None:
        print(json.dumps({"status": "skipped", "reason": SKIP_REASON}, separators=(",", ":")))
        return 0
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
