#!/usr/bin/env python3
"""Apply, verify, and cut over a confirmed Obsidian migration plan."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from wiki_migration_plan import PLAN_KIND, PlanError, build_plan  # noqa: E402
from wiki_section import extract_all_sections  # noqa: E402


MIGRATION_KIND = "grill-adapter.obsidian-migration"
MANIFEST_SCHEMA = 1
EDGE_TYPES = {
    "depends_on": "depends_on",
    "see_also": "see_also",
    "supersedes": "supersedes",
    "contradicts": "contradicts",
}


class MigrationError(RuntimeError):
    pass


def read_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise MigrationError(f"{description} not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MigrationError(f"invalid JSON in {description} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise MigrationError(f"{description} must be a JSON object: {path}")
    return value


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def object_digest(value: Any) -> str:
    return f"sha256:{hashlib.sha256(canonical_json(value)).hexdigest()}"


def content_hash(value: str) -> str:
    canonical = value.replace("\r\n", "\n")
    return f"sha256:{hashlib.sha256(canonical.encode('utf-8')).hexdigest()}"


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise MigrationError(f"refusing to replace symbolic-link manifest: {path}")
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", newline="\n", dir=path.parent, prefix=f".{path.name}.", delete=False
    )
    temporary = Path(handle.name)
    try:
        with handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def registry_path(value: str | None) -> Path:
    configured = value or os.environ.get("OBSIDIAN_WIKI_REGISTRY")
    return Path(configured).expanduser().resolve() if configured else Path.home() / ".config" / "grill-adapter" / "obsidian-wiki.json"


def bundle_path() -> Path:
    return Path(__file__).resolve().parents[1] / "mcp" / "obsidian-wiki" / "dist" / "index.js"


def bundle_call(subcommand: str, payload: dict[str, Any] | None, project_root: Path, registry: Path) -> dict[str, Any]:
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = str(project_root)
    env["OBSIDIAN_WIKI_REGISTRY"] = str(registry)
    command = [env.get("OBSIDIAN_WIKI_NODE", "node"), str(bundle_path()), subcommand]
    try:
        completed = subprocess.run(
            command,
            input=json.dumps(payload, ensure_ascii=False) if payload is not None else None,
            text=True,
            encoding="utf-8",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            check=False,
        )
    except OSError as exc:
        raise MigrationError(f"cannot run bundled Obsidian Wiki CLI: {exc}") from exc
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise MigrationError(f"Obsidian Wiki {subcommand} failed: {detail}")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise MigrationError(f"Obsidian Wiki {subcommand} returned invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise MigrationError(f"Obsidian Wiki {subcommand} result must be an object")
    return value


def validate_plan(plan: dict[str, Any]) -> None:
    if plan.get("schemaVersion") != 1 or plan.get("kind") != PLAN_KIND:
        raise MigrationError("migration plan must use grill-adapter.obsidian-migration-plan schemaVersion 1")
    if plan.get("mode") != "plan-only" or plan.get("writePerformed") is not False:
        raise MigrationError("migration apply accepts only an original read-only plan")
    items = plan.get("planItems")
    if not isinstance(items, list) or not items:
        raise MigrationError("migration plan has no planItems")
    conflicts = [item.get("sourceItemId") for item in items if isinstance(item, dict) and item.get("decision") == "conflict"]
    if conflicts:
        raise MigrationError("migration plan still has unresolved conflicts: " + ", ".join(str(value) for value in conflicts))


def selectors(plan: dict[str, Any]) -> tuple[str, str | None, str | None]:
    sources = plan.get("targetSources")
    if not isinstance(sources, list) or not sources:
        raise MigrationError("migration plan has no targetSources")
    by_role = {
        source.get("role"): source.get("sourceId")
        for source in sources
        if isinstance(source, dict) and source.get("role") in ("project", "shared") and isinstance(source.get("sourceId"), str)
    }
    roles = [role for role in ("project", "shared") if role in by_role]
    if not roles:
        raise MigrationError("migration plan targetSources do not name project or shared Sources")
    root_selector = roles[0] if len(roles) == 1 else "all"
    return root_selector, by_role.get("project"), by_role.get("shared")


def assert_plan_current(plan: dict[str, Any], project_root: Path, registry: Path) -> None:
    root_selector, project_source, shared_source = selectors(plan)
    try:
        current = build_plan(project_root, registry, root_selector, project_source, shared_source)
    except (PlanError, OSError, ValueError) as exc:
        raise MigrationError(f"cannot revalidate migration plan inputs: {exc}") from exc
    if current != plan:
        if current.get("sourceSnapshot") != plan.get("sourceSnapshot"):
            reason = "legacy source snapshot drift"
        elif current.get("targetSnapshot") != plan.get("targetSnapshot"):
            reason = "target Source snapshot drift"
        else:
            reason = "plan content does not match the deterministic planner output"
        raise MigrationError(f"migration plan is stale or modified: {reason}")


def assert_resume_source_current(plan: dict[str, Any], project_root: Path, registry: Path) -> None:
    root_selector, project_source, shared_source = selectors(plan)
    try:
        current = build_plan(project_root, registry, root_selector, project_source, shared_source)
    except (PlanError, OSError, ValueError) as exc:
        raise MigrationError(f"cannot revalidate migration source during resume: {exc}") from exc
    if current.get("sourceSnapshot") != plan.get("sourceSnapshot"):
        raise MigrationError("migration resume refused legacy source snapshot drift")


def yaml_scalar(value: str, field: str) -> str:
    if not value or "\n" in value or "\r" in value or '"' in value or "\\" in value:
        raise MigrationError(f"{field} cannot be represented safely in atomic Note frontmatter")
    return f'"{value}"'


def legacy_record_maps(plan: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    inventory = plan.get("inventory")
    if not isinstance(inventory, dict):
        raise MigrationError("migration plan inventory must be an object")
    pages = {
        item["sourceItemId"]: item
        for item in inventory.get("pages", [])
        if isinstance(item, dict) and isinstance(item.get("sourceItemId"), str)
    }
    sections = {
        item["sourceItemId"]: item
        for item in inventory.get("sections", [])
        if isinstance(item, dict) and isinstance(item.get("sourceItemId"), str)
    }
    return pages, sections


def note_body(item: dict[str, Any], record: dict[str, Any], project_root: Path, plan: dict[str, Any]) -> str:
    root_name = record["legacyRoot"]
    root = project_root / (".adapter/wiki" if root_name == "project" else ".shared-adapter/wiki")
    path = root / record["path"]
    if path.is_symlink():
        raise MigrationError(f"legacy migration input became a symbolic link: {path}")
    text = path.read_text(encoding="utf-8")
    if item["sourceKind"] in ("section", "skill-discovery"):
        body = extract_all_sections(text).get(record["sectionId"])
        if body is None:
            raise MigrationError(f"legacy section is unavailable: {item['sourceItemId']}")
        reference = f"{record['path']}#{record['sectionId']}"
        for edge in plan["inventory"].get("graphEdges", []):
            if isinstance(edge, dict) and edge.get("legacyRoot") == root_name and edge.get("from") == reference:
                raw = edge.get("raw")
                if isinstance(raw, str) and raw:
                    body = body.replace(raw, "")
        return body.strip()
    return text.strip()


def path_without_suffix(path: str) -> str:
    return path[:-3] if path.endswith(".md") else path


def render_note(
    item: dict[str, Any],
    record: dict[str, Any],
    body: str,
    target_paths: dict[str, str],
) -> tuple[str, list[dict[str, str]]]:
    summary = record.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise MigrationError(f"migration item has no atomic Note summary: {item['sourceItemId']}")
    fields = [
        "---",
        "wiki_schema: grill-adapter.obsidian-note/v1",
        f"wiki_id: {yaml_scalar(item['noteId'], 'wiki_id')}",
        f"type: {item['noteType']}",
        "status: active",
        "agent_visible: true",
        f"summary: {yaml_scalar(summary.strip(), 'summary')}",
        f"constraint_strength: {item['constraintStrength']}",
    ]
    rendered_edges: list[dict[str, str]] = []
    by_property: dict[str, list[str]] = {}
    for edge in item.get("edgeTransformation", []):
        if not isinstance(edge, dict) or edge.get("property") not in EDGE_TYPES or not isinstance(edge.get("targetNoteId"), str):
            raise MigrationError(f"migration item has an invalid typed edge: {item['sourceItemId']}")
        target_id = edge["targetNoteId"]
        target_path = target_paths.get(target_id)
        if not target_path:
            raise MigrationError(f"typed edge target is not an applied Note: {target_id}")
        link = f"[[{path_without_suffix(target_path)}]]"
        by_property.setdefault(edge["property"], []).append(link)
        rendered_edges.append({"type": EDGE_TYPES[edge["property"]], "targetWikiId": target_id})
    for property_name in ("depends_on", "see_also", "supersedes", "contradicts"):
        links = sorted(set(by_property.get(property_name, [])))
        if links:
            fields.append(f"{property_name}:")
            fields.extend(f"  - {yaml_scalar(link, property_name)}" for link in links)
    skill = item.get("skillCard")
    if isinstance(skill, dict):
        fields.extend([
            f"skill_provider: {skill['provider']}",
            f"skill_name: {skill['name']}",
            f"skill_version: {skill['version']}",
            f"skill_contract_hash: {skill['contractHash']}",
            "skill_roles:",
            *(f"  - {role}" for role in skill["roles"]),
            "skill_triggers:",
            *(f"  - {yaml_scalar(trigger, 'skill trigger')}" for trigger in skill["triggers"]),
        ])
    fields.extend(["---", "", body, ""])
    return "\n".join(fields), sorted(rendered_edges, key=lambda edge: (edge["type"], edge["targetWikiId"]))


def search_wiki_id(wiki_id: str, project_root: Path, registry: Path) -> list[dict[str, Any]]:
    result = bundle_call("search", {"query": f"[wiki_id:{wiki_id}]"}, project_root, registry)
    notes = result.get("notes")
    if not isinstance(notes, list):
        raise MigrationError("Obsidian Wiki search result is missing notes")
    return [note for note in notes if isinstance(note, dict) and note.get("wikiId") == wiki_id]


def manifest_path(project_root: Path, plan_hash: str) -> Path:
    return project_root / ".adapter" / "context" / f"migration-{plan_hash.removeprefix('sha256:')[:12]}.obsidian-migration.json"


def public_manifest(manifest: dict[str, Any], path: Path) -> dict[str, Any]:
    return {**manifest, "manifestPath": str(path)}


def apply_plan(args: argparse.Namespace) -> dict[str, Any]:
    if not args.confirmed:
        raise MigrationError("migration apply requires explicit confirmation (--confirmed)")
    project_root = Path(args.project_root).expanduser().resolve()
    registry = registry_path(args.registry)
    plan = read_json(Path(args.plan).expanduser().resolve(), "migration plan")
    validate_plan(plan)
    plan_hash = object_digest(plan)
    path = manifest_path(project_root, plan_hash)
    if path.is_file():
        manifest = read_json(path, "migration manifest")
        if manifest.get("planHash") != plan_hash:
            raise MigrationError("migration manifest belongs to another plan")
        if manifest.get("state") in ("published", "verified", "cutover"):
            return public_manifest(manifest, path)
        assert_resume_source_current(plan, project_root, registry)
    else:
        assert_plan_current(plan, project_root, registry)
        manifest = {
            "schemaVersion": MANIFEST_SCHEMA,
            "kind": MIGRATION_KIND,
            "migrationId": f"migration-{plan_hash.removeprefix('sha256:')[:12]}",
            "state": "applying",
            "planHash": plan_hash,
            "sourceSnapshot": plan["sourceSnapshot"],
            "targetSnapshot": plan["targetSnapshot"],
            "targetSources": plan["targetSources"],
            "seededNotes": [],
            "notes": [],
            "repositories": [],
        }
        atomic_write_json(path, manifest)

    existing_notes = {
        note["sourceItemId"]: note for note in manifest.get("notes", [])
        if isinstance(note, dict) and isinstance(note.get("sourceItemId"), str)
    }
    seeded_notes = {
        note["sourceItemId"]: note for note in manifest.get("seededNotes", [])
        if isinstance(note, dict) and isinstance(note.get("sourceItemId"), str)
    }
    writable = [item for item in plan["planItems"] if item["decision"] in ("create", "update")]
    pages, sections = legacy_record_maps(plan)
    records = {**pages, **sections}
    target_paths: dict[str, str] = {}
    operations: dict[str, tuple[str, str | None]] = {}
    for item in writable:
        wiki_id = item.get("noteId")
        proposed = item.get("proposedPath")
        if not isinstance(wiki_id, str) or not isinstance(proposed, str):
            raise MigrationError(f"writable migration item lacks Note identity: {item.get('sourceItemId')}")
        matches = search_wiki_id(wiki_id, project_root, registry)
        if item["decision"] == "create":
            if matches:
                resumed = existing_notes.get(item["sourceItemId"])
                seeded = seeded_notes.get(item["sourceItemId"])
                expected_hashes = {
                    value for value in (
                        resumed.get("contentHash") if resumed else None,
                        seeded.get("contentHash") if seeded else None,
                    ) if isinstance(value, str)
                }
                if len(matches) != 1 or matches[0].get("contentHash") not in expected_hashes:
                    raise MigrationError(f"create target wiki_id already exists: {wiki_id}")
                target_paths[wiki_id] = str(matches[0]["path"])
            else:
                target_paths[wiki_id] = proposed
            operations[item["sourceItemId"]] = ("create", None)
        else:
            if len(matches) != 1:
                raise MigrationError(f"update target wiki_id must resolve exactly once: {wiki_id}")
            target_paths[wiki_id] = str(matches[0]["path"])
            operations[item["sourceItemId"]] = ("update", str(matches[0]["contentHash"]))

    prepared: dict[str, dict[str, Any]] = {}
    for item in writable:
        source_id = item["sourceItemId"]
        record = records.get(source_id)
        if not record:
            raise MigrationError(f"migration inventory record is unavailable: {source_id}")
        body = note_body(item, record, project_root, plan)
        content, edges = render_note(item, record, body, target_paths)
        seed_item = {**item, "edgeTransformation": []}
        seed_content, _ = render_note(seed_item, record, body, target_paths)
        prepared[source_id] = {
            "item": item,
            "content": content,
            "contentHash": content_hash(content),
            "seedContent": seed_content,
            "seedHash": content_hash(seed_content),
            "edges": edges,
        }

    # Create a valid edge-free Note for every new identity first. The second CAS pass can then
    # author typed links in any order, including mutually-referential cycles.
    for item in writable:
        if item["decision"] != "create":
            continue
        source_id = item["sourceItemId"]
        if source_id in existing_notes or source_id in seeded_notes:
            continue
        candidate = prepared[source_id]
        result = bundle_call(
            "apply-note-change",
            {
                "sourceId": item["targetSource"]["sourceId"],
                "operation": "create",
                "path": target_paths[item["noteId"]],
                "content": candidate["seedContent"],
                "expectedHash": None,
                "authorized": True,
            },
            project_root,
            registry,
        )
        diff = result.get("diff") if isinstance(result.get("diff"), dict) else {}
        if diff.get("afterHash") != candidate["seedHash"]:
            raise MigrationError(f"seed write receipt hash mismatch for {source_id}")
        seeded = {
            "sourceItemId": source_id,
            "sourceId": item["targetSource"]["sourceId"],
            "repositoryRef": result["repositoryRef"],
            "bindingDigest": result["bindingDigest"],
            "wikiId": item["noteId"],
            "path": target_paths[item["noteId"]],
            "contentHash": candidate["seedHash"],
        }
        manifest["seededNotes"].append(seeded)
        manifest["seededNotes"].sort(key=lambda note: note["sourceItemId"])
        seeded_notes[source_id] = seeded
        atomic_write_json(path, manifest)

    for item in writable:
        source_id = item["sourceItemId"]
        candidate = prepared[source_id]
        after_hash = candidate["contentHash"]
        resumed = existing_notes.get(source_id)
        if resumed:
            if resumed.get("contentHash") != after_hash:
                raise MigrationError(f"migration resume content differs for {source_id}")
            continue
        operation, before_hash = operations[source_id]
        seeded = seeded_notes.get(source_id)
        if operation == "create" and seeded and seeded["contentHash"] == after_hash:
            result = seeded
            diff: dict[str, Any] = {"beforeHash": None, "afterHash": after_hash}
        else:
            effective_operation = "update" if operation == "create" else operation
            effective_before = seeded["contentHash"] if operation == "create" and seeded else before_hash
            result = bundle_call(
                "apply-note-change",
                {
                    "sourceId": item["targetSource"]["sourceId"],
                    "operation": effective_operation,
                    "path": target_paths[item["noteId"]],
                    "content": candidate["content"],
                    "expectedHash": effective_before,
                    "authorized": True,
                },
                project_root,
                registry,
            )
            diff = result.get("diff") if isinstance(result.get("diff"), dict) else {}
            if diff.get("afterHash") != after_hash:
                raise MigrationError(f"write receipt hash mismatch for {source_id}")
        note_receipt = {
            "sourceItemId": source_id,
            "sourceKind": item["sourceKind"],
            "sourceId": item["targetSource"]["sourceId"],
            "repositoryRef": result["repositoryRef"],
            "bindingDigest": result["bindingDigest"],
            "wikiId": item["noteId"],
            "path": target_paths[item["noteId"]],
            "operation": operation,
            "beforeHash": before_hash,
            "contentHash": after_hash,
            "noteType": item["noteType"],
            "constraintStrength": item["constraintStrength"],
            "edges": candidate["edges"],
        }
        manifest["notes"].append(note_receipt)
        manifest["notes"].sort(key=lambda note: note["sourceItemId"])
        atomic_write_json(path, manifest)

    manifest["state"] = "publishing"
    atomic_write_json(path, manifest)
    folded = {
        "schemaVersion": 1,
        "featureSlug": manifest["migrationId"],
        "candidates": [
            {
                "candidateId": f"migration-{index + 1}",
                "status": "kept",
                "writeReceipt": {
                    "provider": "obsidian",
                    "state": "applied",
                    "operation": note["operation"],
                    "sourceId": note["sourceId"],
                    "repositoryRef": note["repositoryRef"],
                    "bindingDigest": note["bindingDigest"],
                    "wikiId": note["wikiId"],
                    "path": note["path"],
                    "beforeHash": note["beforeHash"],
                    "afterHash": note["contentHash"],
                },
            }
            for index, note in enumerate(manifest["notes"])
        ],
    }
    published = bundle_call("publish", folded, project_root, registry)
    repositories = published.get("repositories")
    if not isinstance(repositories, list) or any(repo.get("state") != "published" for repo in repositories if isinstance(repo, dict)):
        raise MigrationError("migration publisher did not return completed repositories")
    manifest["repositories"] = repositories
    manifest["state"] = "published"
    atomic_write_json(path, manifest)
    return public_manifest(manifest, path)


def gh_pr_state(url: str) -> dict[str, Any]:
    executable = os.environ.get("OBSIDIAN_WIKI_GH_CLI", "gh")
    completed = subprocess.run(
        [executable, "pr", "view", url, "--json", "state,mergedAt"],
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise MigrationError(f"cannot verify migration PR {url}: {completed.stderr.strip() or completed.stdout.strip()}")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise MigrationError(f"GitHub returned invalid PR state for {url}: {exc}") from exc
    return value if isinstance(value, dict) else {}


def verify_manifest(project_root: Path, path: Path, registry: Path, persist: bool = True) -> dict[str, Any]:
    manifest = read_json(path, "migration manifest")
    if manifest.get("schemaVersion") != MANIFEST_SCHEMA or manifest.get("kind") != MIGRATION_KIND:
        raise MigrationError("migration manifest has an unsupported contract")
    if manifest.get("state") not in ("published", "verified", "cutover"):
        raise MigrationError("migration manifest is not fully published")
    repositories = manifest.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        raise MigrationError("migration manifest has no published repositories")
    for repository in repositories:
        if not isinstance(repository, dict) or not isinstance(repository.get("prUrl"), str):
            raise MigrationError("migration repository receipt has no PR URL")
        state = gh_pr_state(repository["prUrl"])
        if state.get("state") != "MERGED" or not state.get("mergedAt"):
            raise MigrationError(f"migration PR is not merged: {repository['prUrl']}")

    status = bundle_call("status", None, project_root, registry)
    if status.get("healthy") is not True:
        raise MigrationError("Obsidian Wiki bindings are unhealthy after migration: " + "; ".join(status.get("errors", [])))
    target_ids = {source["sourceId"] for source in manifest["targetSources"]}
    status_bindings = {
        binding.get("sourceId"): binding
        for binding in status.get("bindings", [])
        if isinstance(binding, dict)
    }
    for source_id in target_ids:
        binding = status_bindings.get(source_id)
        if not binding or binding.get("repositoryHealth", {}).get("baseSynchronized") is not True:
            raise MigrationError(f"target Source base is not synchronized after migration: {source_id}")

    expected_notes = manifest.get("notes")
    if not isinstance(expected_notes, list) or not expected_notes:
        raise MigrationError("migration manifest has no Note mappings")
    wiki_ids = [note["wikiId"] for note in expected_notes]
    if len(set(wiki_ids)) != len(wiki_ids):
        raise MigrationError("migration manifest contains duplicate wiki IDs")
    reread = bundle_call("read-notes-by-wiki-ids", {"wikiIds": wiki_ids}, project_root, registry)
    actual_notes = reread.get("notes")
    if not isinstance(actual_notes, list) or len(actual_notes) != len(expected_notes):
        raise MigrationError("migration mapping coverage failed during stable Note reread")
    actual_by_id = {note.get("wikiId"): note for note in actual_notes if isinstance(note, dict)}
    if len(actual_by_id) != len(expected_notes):
        raise MigrationError("migrated Notes do not have unique wiki IDs")
    for expected in expected_notes:
        actual = actual_by_id.get(expected["wikiId"])
        if not actual:
            raise MigrationError(f"migrated Note is missing: {expected['wikiId']}")
        if actual.get("sourceId") != expected["sourceId"] or actual.get("path") != expected["path"]:
            raise MigrationError(f"migrated Note escaped its planned Source or path: {expected['wikiId']}")
        if actual.get("contentHash") != expected["contentHash"]:
            raise MigrationError(f"migrated Note content hash drift: {expected['wikiId']}")
        found = search_wiki_id(expected["wikiId"], project_root, registry)
        if len(found) != 1 or found[0].get("path") != expected["path"]:
            raise MigrationError(f"migrated Note search identity is not unique: {expected['wikiId']}")
        if expected.get("constraintStrength") == "hard" and not actual.get("content"):
            raise MigrationError(f"hard migrated Note could not be reread in full: {expected['wikiId']}")

    with_edges = [note for note in expected_notes if note.get("edges")]
    if with_edges:
        graph = bundle_call("graph-neighbors", {"wikiIds": [note["wikiId"] for note in with_edges]}, project_root, registry)
        neighbors = graph.get("neighbors") if isinstance(graph.get("neighbors"), dict) else {}
        for note in with_edges:
            expected_edges = sorted((edge["type"], edge["targetWikiId"]) for edge in note["edges"])
            actual_edges = sorted(
                (edge.get("type"), edge.get("wikiId"))
                for edge in neighbors.get(note["wikiId"], [])
                if isinstance(edge, dict)
            )
            if actual_edges != expected_edges:
                raise MigrationError(f"migrated typed edge drift: {note['wikiId']}")

    checks = {
        "mergedPullRequests": True,
        "baseSynchronized": True,
        "mappingCoverage": True,
        "uniqueWikiIds": True,
        "schemaAndPolicy": True,
        "sourceIsolation": True,
        "search": True,
        "hardNoteReread": True,
        "typedEdges": True,
    }
    result = {**manifest, "state": "verified", "checks": checks}
    if persist and manifest.get("state") != "cutover":
        stored = {key: value for key, value in result.items() if key != "manifestPath"}
        atomic_write_json(path, stored)
    return public_manifest(result, path)


def verify_command(args: argparse.Namespace) -> dict[str, Any]:
    project_root = Path(args.project_root).expanduser().resolve()
    path = Path(args.manifest).expanduser().resolve()
    return verify_manifest(project_root, path, registry_path(args.registry))


def active_sidecar(project_root: Path) -> tuple[Path, int] | None:
    candidates = [path for path in (project_root / ".adapter" / "context").glob("*.wiki-context.json") if path.is_file()]
    if not candidates:
        return None
    path = max(candidates, key=lambda candidate: candidate.stat().st_mtime_ns)
    value = read_json(path, "active Wiki context sidecar")
    schema = value.get("schemaVersion")
    return path, schema if isinstance(schema, int) else -1


def cutover_command(args: argparse.Namespace) -> dict[str, Any]:
    if not args.confirmed:
        raise MigrationError("migration cutover requires explicit confirmation (--confirmed)")
    project_root = Path(args.project_root).expanduser().resolve()
    path = Path(args.manifest).expanduser().resolve()
    registry = registry_path(args.registry)
    verified = verify_manifest(project_root, path, registry)
    sidecar = active_sidecar(project_root)
    if sidecar and sidecar[1] == 5:
        raise MigrationError(f"active execution sidecar still uses schemaVersion 5: {sidecar[0]}")

    settings_path = project_root / ".shared-adapter" / "settings.json"
    settings = read_json(settings_path, "project Wiki settings")
    wiki = settings.get("wiki")
    if not isinstance(wiki, dict):
        raise MigrationError("project Wiki settings must contain wiki")
    roots = []
    for relative in (".adapter/wiki", ".shared-adapter/wiki"):
        if (project_root / relative).is_dir():
            roots.append(relative)
    relative_manifest = path.relative_to(project_root).as_posix()
    expected_archive = {
        "mode": "read-only-archive",
        "roots": roots,
        "migrationManifest": relative_manifest,
    }
    existing = wiki.get("legacyRuntime")
    if existing is not None and existing != expected_archive:
        raise MigrationError("wiki.legacyRuntime already records a different cutover")
    wiki["provider"] = "obsidian"
    wiki["legacyRuntime"] = expected_archive
    atomic_write_json(settings_path, settings)

    stored = {key: value for key, value in verified.items() if key != "manifestPath"}
    stored["state"] = "cutover"
    stored["cutover"] = {"settingsPath": ".shared-adapter/settings.json", "legacyRuntime": expected_archive}
    atomic_write_json(path, stored)
    return public_manifest(stored, path)


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")


def main() -> None:
    configure_stdio()
    parser = argparse.ArgumentParser(description="Apply, verify, or cut over a confirmed Obsidian migration plan.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("apply", "verify", "cutover"):
        command = subparsers.add_parser(name)
        command.add_argument("--project-root", required=True)
        command.add_argument("--registry", default=None)
        if name == "apply":
            command.add_argument("--plan", required=True)
            command.add_argument("--confirmed", action="store_true")
        else:
            command.add_argument("--manifest", required=True)
            if name == "cutover":
                command.add_argument("--confirmed", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "apply":
            result = apply_plan(args)
        elif args.command == "verify":
            result = verify_command(args)
        else:
            result = cutover_command(args)
    except (MigrationError, OSError, ValueError, KeyError) as exc:
        print(f"migration {args.command} failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
