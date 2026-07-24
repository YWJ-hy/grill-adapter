#!/usr/bin/env python3
"""Materialize task-scoped hard constraints from bound Obsidian Sources."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from adr_identity import AdrIdentityError, validate_identity  # noqa: E402
from wiki_common import repo_root  # noqa: E402
from wiki_context_render import (  # noqa: E402
    ValidationError,
    _load_context,
    _v6_task_notes,
    _validate_context,
)

REREAD_HEADING = "## Hard Wiki Constraint Rereads"
REREAD_PREAMBLE = (
    "Authoritative full Note rereads of this task's hard constraints. Treat them as binding; "
    "sidecar summaries never replace this runtime content."
)


class MaterializeError(Exception):
    pass


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (OSError, ValueError):
            pass


def _render_note_block(materialized: dict[str, Any]) -> str:
    lines = [f"### Reread: `{materialized['displayPath']}` # `{materialized['sectionId']}`"]
    if materialized.get("closedVia"):
        lines.append(f"- Pulled in via: depends-on closure of `{materialized['closedVia']}`")
    for caveat in materialized.get("caveats") or []:
        lines.append(f"- Caveat: {caveat}")
    required_skill = materialized.get("requiredSkill")
    if isinstance(required_skill, dict):
        lines.extend(
            [
                "#### Required executable skill",
                "",
                f"MUST invoke project skill `{required_skill['name']}` for this "
                f"`{required_skill['role']}` task before acting on the Card below.",
                "The Card text is discovery metadata; the verified pack is the executable procedure.",
            ]
        )
    lines.extend(["#### Full Note text", "", materialized["content"]])
    return "\n".join(lines)


def _render_rereads(materialized: list[dict[str, Any]]) -> str:
    output = [REREAD_HEADING, "", REREAD_PREAMBLE, ""]
    output.append("\n\n".join(_render_note_block(note) for note in materialized))
    return "\n".join(output).rstrip() + "\n"


def _obsidian_cmd(explicit: str | None) -> dict[str, Any] | None:
    if explicit:
        return {"argv": shlex.split(explicit), "env": {}}
    env_cmd = os.environ.get("OBSIDIAN_WIKI_MCP_CMD")
    if env_cmd:
        return {"argv": shlex.split(env_cmd), "env": {}}
    entry = Path(__file__).resolve().parent.parent / "mcp" / "obsidian-wiki" / "dist" / "index.js"
    if entry.is_file():
        return {"argv": ["node", entry.as_posix()], "env": {}}
    return None


def _invoke_obsidian_cli(
    command: dict[str, Any],
    project_root: Path,
    request: dict[str, Any],
    subcommand: str,
) -> dict[str, Any]:
    env = dict(os.environ)
    env.update(command.get("env") or {})
    env["CLAUDE_PROJECT_DIR"] = str(project_root)
    argv = [*command["argv"], subcommand]
    try:
        process = subprocess.run(
            argv,
            input=json.dumps(request),
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            check=False,
        )
    except OSError as exc:
        raise MaterializeError(f"failed to launch Obsidian Wiki MCP CLI {argv!r}: {exc}") from exc
    if process.returncode != 0:
        detail = process.stderr.strip() or f"exit code {process.returncode}; partial stdout discarded"
        raise MaterializeError(f"Obsidian Wiki MCP CLI failed (exit {process.returncode}): {detail}")
    try:
        result = json.loads(process.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError) as exc:
        raise MaterializeError(f"could not parse Obsidian Wiki MCP CLI output: {exc}") from exc
    if not isinstance(result, dict):
        raise MaterializeError("Obsidian Wiki MCP CLI output was not a JSON object")
    return result


def _assert_note_matches(
    expected: dict[str, Any],
    actual: dict[str, Any],
    role: str,
    is_skill: bool,
) -> None:
    identity = f"{expected.get('path')} ({expected.get('wikiId')})"
    for key in ("sourceId", "role", "path", "wikiId", "type", "bindingDigest", "contentHash"):
        if actual.get(key) != expected.get(key):
            if key == "contentHash":
                raise MaterializeError(f"Obsidian Note content drift for {identity}")
            raise MaterializeError(f"Obsidian Note {key} drift for {identity}")
    if actual.get("summary") != expected.get("summary"):
        raise MaterializeError(f"Obsidian Note summary drift for {identity}")
    expected_adr = (
        expected.get("adrSourceId"),
        expected.get("adrSourcePath"),
        expected.get("adrSourceContentHash"),
    )
    actual_adr = (
        actual.get("adrSourceId"),
        actual.get("adrSourcePath"),
        actual.get("adrSourceContentHash"),
    )
    if any(value is not None for value in expected_adr + actual_adr) and actual_adr != expected_adr:
        raise MaterializeError(f"ADR projection identity drift for {identity}")
    if is_skill:
        for key in (
            "skillProvider",
            "skillName",
            "skillVersion",
            "skillContractHash",
            "skillTriggers",
            "discoveryState",
        ):
            if actual.get(key) != expected.get(key):
                raise MaterializeError(f"required Skill Card {key} drift for {identity}")
        roles = actual.get("skillRoles")
        expected_roles = expected.get("requiredFor")
        if not isinstance(roles, list) or not isinstance(expected_roles, list) or sorted(roles) != sorted(expected_roles):
            raise MaterializeError(f"required Skill Card role policy drift for {identity}")
        if role not in roles:
            raise MaterializeError(f"required Skill Card role policy violation for {identity}: {role} is no longer allowed")
    elif actual.get("constraintStrength") != "hard":
        raise MaterializeError(f"hard Note policy violation for {identity}: runtime Note is no longer hard")
    if not isinstance(actual.get("content"), str) or not actual["content"].strip():
        raise MaterializeError(f"Obsidian Note has no readable content: {identity}")


def _validate_adr_authority(project_root: Path, note: dict[str, Any], identity: str) -> None:
    if not note.get("adrSourceId"):
        return
    try:
        validate_identity(
            project_root,
            note["adrSourceId"],
            note["adrSourcePath"],
            note["adrSourceContentHash"],
        )
    except (AdrIdentityError, KeyError, TypeError) as exc:
        raise MaterializeError(f"ADR projection authority validation failed for {identity}: {exc}") from exc


def _materialize(
    data: dict[str, Any],
    task_id: str | None,
    role: str,
    project_root: Path,
    explicit_command: str | None,
) -> list[dict[str, Any]]:
    if not task_id:
        raise MaterializeError("schema-v6 materialization requires --task-id")
    notes, skills = _v6_task_notes(data, task_id, role)
    direct: list[tuple[dict[str, Any], bool]] = [
        (note, False) for note in notes if note.get("constraintStrength") == "hard"
    ]
    direct.extend((skill, True) for skill in skills)
    if not direct:
        return []

    command = _obsidian_cmd(explicit_command)
    if not command:
        raise MaterializeError(
            "Obsidian Wiki MCP CLI could not be resolved; install the plugin bundle or pass --obsidian-wiki-cmd"
        )

    direct_ids = [str(note["wikiId"]) for note, _ in direct]
    read = _invoke_obsidian_cli(command, project_root, {"wikiIds": direct_ids}, "read-notes-by-wiki-ids")
    direct_snapshot = read.get("snapshotHash")
    if not isinstance(direct_snapshot, str) or not direct_snapshot:
        raise MaterializeError("Obsidian Wiki MCP returned no direct Note snapshot hash")
    actual_notes = read.get("notes")
    if not isinstance(actual_notes, list) or len(actual_notes) != len(direct_ids):
        raise MaterializeError("Obsidian Wiki MCP returned partial Note results")
    by_id: dict[str, dict[str, Any]] = {}
    for actual in actual_notes:
        if not isinstance(actual, dict) or not isinstance(actual.get("wikiId"), str) or actual["wikiId"] in by_id:
            raise MaterializeError("Obsidian Wiki MCP returned duplicate or invalid Note IDs")
        by_id[actual["wikiId"]] = actual

    materialized: list[dict[str, Any]] = []
    for expected, is_skill in direct:
        actual = by_id.get(expected["wikiId"])
        if actual is None:
            raise MaterializeError(f"Obsidian Wiki MCP returned no Note for {expected['wikiId']}")
        _validate_adr_authority(project_root, expected, expected["wikiId"])
        _assert_note_matches(expected, actual, role, is_skill)
        materialized.append(
            {
                "displayPath": actual["path"],
                "sectionId": actual["wikiId"],
                "content": actual["content"],
                "closedVia": None,
                "caveats": [],
                "requiredSkill": {"name": actual["skillName"], "role": role} if is_skill else None,
            }
        )

    hard_note_ids = [str(note["wikiId"]) for note, is_skill in direct if not is_skill]
    closure_ids: list[str] = []
    closed_via: dict[str, str] = {}
    direct_id_set = set(direct_ids)
    graph: dict[str, Any] | None = None
    if hard_note_ids:
        graph = _invoke_obsidian_cli(command, project_root, {"wikiIds": hard_note_ids}, "graph-neighbors")
        neighbors = graph.get("neighbors")
        if not isinstance(neighbors, dict):
            raise MaterializeError("Obsidian Wiki MCP returned invalid graph neighbors")
        for wiki_id in hard_note_ids:
            edges = neighbors.get(wiki_id)
            if not isinstance(edges, list):
                raise MaterializeError(f"Obsidian Wiki MCP returned no graph slice for {wiki_id}")
            for edge in edges:
                if not isinstance(edge, dict) or edge.get("type") != "depends_on":
                    continue
                target_id = edge.get("wikiId")
                path = edge.get("path")
                if not isinstance(target_id, str) or not target_id or not isinstance(path, str) or not path:
                    raise MaterializeError(f"Obsidian Wiki MCP returned invalid depends_on edge for {wiki_id}")
                if target_id not in direct_id_set and target_id not in closed_via:
                    closure_ids.append(target_id)
                    closed_via[target_id] = wiki_id

    if closure_ids:
        closure_read = _invoke_obsidian_cli(
            command,
            project_root,
            {"wikiIds": closure_ids},
            "read-notes-by-wiki-ids",
        )
        closure_notes = closure_read.get("notes")
        if not isinstance(closure_notes, list) or len(closure_notes) != len(closure_ids):
            raise MaterializeError("Obsidian Wiki MCP returned partial depends_on Note results")
        closure_by_id = {
            note.get("wikiId"): note
            for note in closure_notes
            if isinstance(note, dict) and isinstance(note.get("wikiId"), str)
        }
        if len(closure_by_id) != len(closure_ids):
            raise MaterializeError("Obsidian Wiki MCP returned duplicate or invalid depends_on Note IDs")
        for wiki_id in closure_ids:
            actual = closure_by_id.get(wiki_id)
            if actual is None or not isinstance(actual.get("content"), str) or not actual["content"].strip():
                raise MaterializeError(f"depends_on Note policy violation for {wiki_id}")
            _validate_adr_authority(project_root, actual, wiki_id)
            materialized.append(
                {
                    "displayPath": actual["path"],
                    "sectionId": actual["wikiId"],
                    "content": actual["content"],
                    "closedVia": closed_via[wiki_id],
                    "caveats": [],
                }
            )

    if hard_note_ids and graph is not None:
        verified_graph = _invoke_obsidian_cli(
            command,
            project_root,
            {"wikiIds": hard_note_ids},
            "graph-neighbors",
        )
        if verified_graph.get("neighbors") != graph.get("neighbors"):
            raise MaterializeError("Obsidian Wiki dependency graph drifted during materialization")
        verified_read = _invoke_obsidian_cli(
            command,
            project_root,
            {"wikiIds": direct_ids},
            "read-notes-by-wiki-ids",
        )
        if verified_read.get("snapshotHash") != direct_snapshot:
            raise MaterializeError("Obsidian Wiki direct Note snapshot drifted during materialization")
        verified_notes = verified_read.get("notes")
        if not isinstance(verified_notes, list) or len(verified_notes) != len(direct_ids):
            raise MaterializeError("Obsidian Wiki MCP returned partial verification Note results")
        verified_by_id = {
            note.get("wikiId"): note
            for note in verified_notes
            if isinstance(note, dict) and isinstance(note.get("wikiId"), str)
        }
        if len(verified_by_id) != len(direct_ids):
            raise MaterializeError("Obsidian Wiki MCP returned duplicate or invalid verification Note IDs")
        for expected, is_skill in direct:
            verified = verified_by_id.get(expected["wikiId"])
            if verified is None:
                raise MaterializeError(f"Obsidian Wiki MCP returned no verification Note for {expected['wikiId']}")
            _assert_note_matches(expected, verified, role, is_skill)
    return materialized


def _append(path: Path, block: str) -> None:
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    text = (existing + "\n" if existing else "") + block
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def main() -> int:
    _configure_stdio()
    parser = argparse.ArgumentParser(
        description="Materialize task-scoped hard constraints from bound Obsidian Sources."
    )
    parser.add_argument("context_path", help="Path to the schema-v6 .wiki-context.json sidecar")
    parser.add_argument("--task-id", help="Render only rereads bound to this finalized task id")
    parser.add_argument("--role", choices=["implementer", "reviewer"], default="implementer")
    parser.add_argument("--project-root", default=None, help="Project root (auto-detected if omitted)")
    parser.add_argument("--append-to", default=None, help="Append rendered rereads to this file")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--execution-ready", action="store_true")
    parser.add_argument("--obsidian-wiki-cmd", default=None)
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve() if args.project_root else repo_root(Path.cwd())
    try:
        data = _load_context(Path(args.context_path))
        _validate_context(data, args.strict, args.execution_ready, project_root)
        materialized = _materialize(
            data,
            args.task_id,
            args.role,
            project_root,
            args.obsidian_wiki_cmd,
        )
    except (ValidationError, MaterializeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    if not materialized:
        scope = f"task `{args.task_id}`" if args.task_id else "selected wiki context"
        print(f"no hard-constraint rereads for {scope}", file=sys.stderr)
        return 0
    block = _render_rereads(materialized)
    if args.append_to:
        _append(Path(args.append_to), block)
        print(
            f"materialized {len(materialized)} Obsidian hard-constraint reread(s) -> {args.append_to}",
            file=sys.stderr,
        )
    else:
        sys.stdout.write(block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
