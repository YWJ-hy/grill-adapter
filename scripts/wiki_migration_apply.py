#!/usr/bin/env python3
"""Apply, verify, and cut over a confirmed Obsidian migration plan."""

from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from wiki_migration_plan import PLAN_KIND, PlanError, _clone_legacy_shared_wiki, build_plan  # noqa: E402
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


_LEGACY_SHARED_CLONES: dict[str, Path] = {}


@atexit.register
def _cleanup_legacy_shared_clones() -> None:
    for checkout in _LEGACY_SHARED_CLONES.values():
        shutil.rmtree(checkout.parent, ignore_errors=True)


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
        detail = completed.stderr.strip() or f"exit {completed.returncode}; stdout discarded"
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
    for item in items:
        if not isinstance(item, dict):
            raise MigrationError("migration plan contains a non-object planItem")
        decision = item.get("decision")
        expected_path = item.get("expectedPath")
        expected = item.get("expectedBeforeHash")
        if decision == "update":
            if not isinstance(expected_path, str) or not expected_path:
                raise MigrationError(f"migration update lacks its reviewed target path: {item.get('sourceItemId')}")
            if not isinstance(expected, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", expected):
                raise MigrationError(f"migration update lacks its reviewed target hash: {item.get('sourceItemId')}")
        if decision == "create" and (expected_path is not None or expected is not None):
            raise MigrationError(f"migration create has an unexpected target snapshot: {item.get('sourceItemId')}")


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


def legacy_shared_wiki_url(plan: dict[str, Any]) -> str | None:
    sources = plan.get("legacySources")
    shared = sources.get("shared") if isinstance(sources, dict) else None
    url = shared.get("repoUrl") if isinstance(shared, dict) else None
    return url if isinstance(url, str) and url.strip() else None


def legacy_shared_root(project_root: Path, plan: dict[str, Any]) -> Path:
    url = legacy_shared_wiki_url(plan)
    if not url:
        return project_root / ".shared-adapter" / "wiki"
    if url not in _LEGACY_SHARED_CLONES:
        checkout, _ = _clone_legacy_shared_wiki(url)
        _LEGACY_SHARED_CLONES[url] = checkout
    return _LEGACY_SHARED_CLONES[url]


def assert_plan_current(plan: dict[str, Any], project_root: Path, registry: Path) -> None:
    root_selector, project_source, shared_source = selectors(plan)
    try:
        current = build_plan(
            project_root,
            registry,
            root_selector,
            project_source,
            shared_source,
            legacy_shared_wiki_url=legacy_shared_wiki_url(plan),
        )
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
        current = build_plan(
            project_root,
            registry,
            root_selector,
            project_source,
            shared_source,
            legacy_shared_wiki_url=legacy_shared_wiki_url(plan),
        )
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
    root = project_root / ".adapter" / "wiki" if root_name == "project" else legacy_shared_root(project_root, plan)
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


def search_wiki_id(
    wiki_id: str,
    project_root: Path,
    registry: Path,
    publish_feature_slug: str | None = None,
) -> list[dict[str, Any]]:
    payload: dict[str, Any] = {"query": f"[wiki_id:{wiki_id}]"}
    if publish_feature_slug:
        payload["publishFeatureSlug"] = publish_feature_slug
    result = bundle_call("search", payload, project_root, registry)
    notes = result.get("notes")
    if not isinstance(notes, list):
        raise MigrationError("Obsidian Wiki search result is missing notes")
    return [note for note in notes if isinstance(note, dict) and note.get("wikiId") == wiki_id]


def manifest_path(project_root: Path, plan_hash: str) -> Path:
    return project_root / ".adapter" / "context" / f"migration-{plan_hash.removeprefix('sha256:')[:12]}.obsidian-migration.json"


def public_manifest(manifest: dict[str, Any], path: Path) -> dict[str, Any]:
    return {**manifest, "manifestPath": str(path)}


def writable_plan_items(plan: dict[str, Any]) -> list[dict[str, Any]]:
    return [item for item in plan["planItems"] if item["decision"] in ("create", "update")]


def binding_snapshot(status: dict[str, Any], target_sources: list[dict[str, Any]]) -> list[dict[str, Any]]:
    bindings = {
        item.get("sourceId"): item
        for item in status.get("bindings", [])
        if isinstance(item, dict) and isinstance(item.get("sourceId"), str)
    }
    snapshot = []
    for target in target_sources:
        source_id = target["sourceId"]
        binding = bindings.get(source_id)
        if not binding:
            raise MigrationError(f"target Source binding is unavailable: {source_id}")
        snapshot.append({
            "sourceId": source_id,
            "role": binding.get("role"),
            "root": binding.get("root"),
            "repositoryRef": binding.get("repositoryRef"),
            "bindingDigest": binding.get("bindingDigest"),
            "publishingMode": binding.get("publishingMode"),
            "effectiveReadPolicy": binding.get("effectiveReadPolicy"),
            "effectiveUpdatePolicy": binding.get("effectiveUpdatePolicy"),
            "effectiveCreatePolicy": binding.get("effectiveCreatePolicy"),
            "manifest": binding.get("manifest"),
            "repositoryIdentity": binding.get("repositoryHealth"),
        })
    return sorted(snapshot, key=lambda item: item["sourceId"])


def folded_publish_journal(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
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


def finish_publication(
    manifest: dict[str, Any],
    path: Path,
    project_root: Path,
    registry: Path,
) -> dict[str, Any]:
    published = bundle_call("publish", folded_publish_journal(manifest), project_root, registry)
    repositories = published.get("repositories")
    if not isinstance(repositories, list) or any(
        repo.get("state") != "published" for repo in repositories if isinstance(repo, dict)
    ):
        raise MigrationError("migration publisher did not return completed repositories")
    manifest["repositories"] = repositories
    manifest["state"] = "published"
    atomic_write_json(path, manifest)
    return public_manifest(manifest, path)


def validate_manifest_plan(manifest: dict[str, Any], plan: dict[str, Any] | None = None) -> dict[str, Any]:
    if manifest.get("schemaVersion") != MANIFEST_SCHEMA or manifest.get("kind") != MIGRATION_KIND:
        raise MigrationError("migration manifest has an unsupported contract")
    stored_plan = manifest.get("plan")
    if not isinstance(stored_plan, dict):
        raise MigrationError("migration manifest has no immutable migration plan")
    validate_plan(stored_plan)
    if object_digest(stored_plan) != manifest.get("planHash"):
        raise MigrationError("migration manifest planHash does not match its immutable plan")
    if plan is not None and stored_plan != plan:
        raise MigrationError("migration manifest belongs to another plan")
    for field in ("sourceSnapshot", "targetSnapshot", "targetSources"):
        if manifest.get(field) != stored_plan.get(field):
            raise MigrationError(f"migration manifest {field} differs from its immutable plan")
    binding_state = manifest.get("bindingSnapshot")
    if not isinstance(binding_state, list) or object_digest(binding_state) != manifest.get("bindingSnapshotHash"):
        raise MigrationError("migration manifest binding snapshot hash mismatch")
    operations = manifest.get("operations")
    if not isinstance(operations, list) or object_digest(operations) != manifest.get("operationsHash"):
        raise MigrationError("migration manifest operation roster hash mismatch")
    bindings_by_source = {
        item.get("sourceId"): item
        for item in binding_state
        if isinstance(item, dict) and isinstance(item.get("sourceId"), str)
    }
    for operation in operations:
        if not isinstance(operation, dict):
            raise MigrationError("migration manifest operation roster contains a non-object")
        binding = bindings_by_source.get(operation.get("sourceId"))
        if not binding or operation.get("repositoryRef") != binding.get("repositoryRef") or operation.get("bindingDigest") != binding.get("bindingDigest"):
            raise MigrationError(f"migration operation binding identity drift: {operation.get('sourceItemId')}")
    return stored_plan


def expected_operation_ids(plan: dict[str, Any]) -> list[str]:
    return sorted(item["sourceItemId"] for item in writable_plan_items(plan))


def assert_operation_coverage(manifest: dict[str, Any], plan: dict[str, Any]) -> None:
    expected = expected_operation_ids(plan)
    operations = manifest.get("operations")
    if not isinstance(operations, list):
        raise MigrationError("migration manifest has no immutable operation roster")
    operation_ids = sorted(
        item.get("sourceItemId") for item in operations
        if isinstance(item, dict) and isinstance(item.get("sourceItemId"), str)
    )
    if operation_ids != expected or len(operation_ids) != len(operations):
        raise MigrationError("migration operation coverage differs from the immutable plan")
    notes = manifest.get("notes")
    if manifest.get("state") in ("published", "verified", "cutover"):
        if not isinstance(notes, list):
            raise MigrationError("migration manifest has no Note mappings")
        note_ids = sorted(
            item.get("sourceItemId") for item in notes
            if isinstance(item, dict) and isinstance(item.get("sourceItemId"), str)
        )
        if note_ids != expected or len(note_ids) != len(notes):
            raise MigrationError("migration Note mapping coverage differs from the immutable plan")


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
        validate_manifest_plan(manifest, plan)
        assert_operation_coverage(manifest, plan)
        if manifest.get("state") in ("published", "verified", "cutover"):
            return public_manifest(manifest, path)
        assert_resume_source_current(plan, project_root, registry)
    else:
        assert_plan_current(plan, project_root, registry)
        status = bundle_call("status", None, project_root, registry)
        if status.get("healthy") is not True:
            raise MigrationError("Obsidian Wiki bindings are unhealthy before migration: " + "; ".join(status.get("errors", [])))
        bindings = binding_snapshot(status, plan["targetSources"])
        bindings_by_source = {item["sourceId"]: item for item in bindings}
        writable = writable_plan_items(plan)
        pages, sections = legacy_record_maps(plan)
        records = {**pages, **sections}
        target_paths: dict[str, str] = {}
        before_hashes: dict[str, str | None] = {}
        for item in writable:
            source_item_id = item["sourceItemId"]
            wiki_id = item.get("noteId")
            proposed = item.get("proposedPath")
            if not isinstance(wiki_id, str) or not isinstance(proposed, str):
                raise MigrationError(f"writable migration item lacks Note identity: {source_item_id}")
            matches = search_wiki_id(wiki_id, project_root, registry)
            if item["decision"] == "create":
                if matches:
                    raise MigrationError(f"create target wiki_id already exists: {wiki_id}")
                target_paths[wiki_id] = proposed
                before_hashes[source_item_id] = None
            else:
                if len(matches) != 1:
                    raise MigrationError(f"update target wiki_id must resolve exactly once: {wiki_id}")
                reviewed_path = item.get("expectedPath")
                reviewed_hash = item.get("expectedBeforeHash")
                if matches[0].get("path") != reviewed_path or matches[0].get("contentHash") != reviewed_hash:
                    raise MigrationError(f"confirmed target Note changed after plan validation: {source_item_id}")
                target_paths[wiki_id] = reviewed_path
                before_hashes[source_item_id] = reviewed_hash

        operations = []
        for item in writable:
            source_item_id = item["sourceItemId"]
            record = records.get(source_item_id)
            if not record:
                raise MigrationError(f"migration inventory record is unavailable: {source_item_id}")
            body = note_body(item, record, project_root, plan)
            content, edges = render_note(item, record, body, target_paths)
            seed_item = {**item, "edgeTransformation": []}
            seed_content, _ = render_note(seed_item, record, body, target_paths)
            source_id = item["targetSource"]["sourceId"]
            binding = bindings_by_source.get(source_id)
            if not binding:
                raise MigrationError(f"migration target binding is unavailable: {source_id}")
            operations.append({
                "sourceItemId": source_item_id,
                "sourceKind": item["sourceKind"],
                "sourceId": source_id,
                "repositoryRef": binding["repositoryRef"],
                "bindingDigest": binding["bindingDigest"],
                "wikiId": item["noteId"],
                "path": target_paths[item["noteId"]],
                "operation": item["decision"],
                "beforeHash": before_hashes[source_item_id],
                "seedHash": content_hash(seed_content),
                "contentHash": content_hash(content),
                "noteType": item["noteType"],
                "constraintStrength": item["constraintStrength"],
                "edges": edges,
            })
        manifest = {
            "schemaVersion": MANIFEST_SCHEMA,
            "kind": MIGRATION_KIND,
            "migrationId": f"migration-{plan_hash.removeprefix('sha256:')[:12]}",
            "state": "applying",
            "planHash": plan_hash,
            "plan": plan,
            "sourceSnapshot": plan["sourceSnapshot"],
            "targetSnapshot": plan["targetSnapshot"],
            "targetSources": plan["targetSources"],
            "bindingSnapshot": bindings,
            "bindingSnapshotHash": object_digest(bindings),
            "operations": operations,
            "operationsHash": object_digest(operations),
            "seededNotes": [],
            "notes": [],
            "repositories": [],
        }
        atomic_write_json(path, manifest)

    stored_plan = validate_manifest_plan(manifest, plan)
    assert_operation_coverage(manifest, stored_plan)
    writable = writable_plan_items(stored_plan)
    operation_intents = {
        item["sourceItemId"]: item
        for item in manifest["operations"]
        if isinstance(item, dict) and isinstance(item.get("sourceItemId"), str)
    }
    target_paths = {item["wikiId"]: item["path"] for item in operation_intents.values()}
    pages, sections = legacy_record_maps(stored_plan)
    records = {**pages, **sections}
    prepared: dict[str, dict[str, Any]] = {}
    for item in writable:
        source_id = item["sourceItemId"]
        intent = operation_intents[source_id]
        record = records.get(source_id)
        if not record:
            raise MigrationError(f"migration inventory record is unavailable: {source_id}")
        body = note_body(item, record, project_root, stored_plan)
        content, edges = render_note(item, record, body, target_paths)
        seed_item = {**item, "edgeTransformation": []}
        seed_content, _ = render_note(seed_item, record, body, target_paths)
        expected_identity = {
            "sourceKind": item["sourceKind"],
            "wikiId": item["noteId"],
            "operation": item["decision"],
            "seedHash": content_hash(seed_content),
            "contentHash": content_hash(content),
            "noteType": item["noteType"],
            "constraintStrength": item["constraintStrength"],
            "edges": edges,
        }
        if any(intent.get(key) != value for key, value in expected_identity.items()):
            raise MigrationError(f"migration write intent identity drift for {source_id}")
        prepared[source_id] = {"content": content, "seedContent": seed_content}

    if manifest.get("state") == "publishing":
        return finish_publication(manifest, path, project_root, registry)

    publish = bundle_call(
        "prepare-publish",
        {
            "featureSlug": manifest["migrationId"],
            "operations": [
                {
                    "sourceId": item["sourceId"],
                    "repositoryRef": item["repositoryRef"],
                    "bindingDigest": item["bindingDigest"],
                    "path": item["path"],
                }
                for item in manifest["operations"]
            ],
        },
        project_root,
        registry,
    )
    repositories = publish.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        raise MigrationError("migration publisher did not prepare dedicated branches")

    existing_notes = {
        note["sourceItemId"]: note for note in manifest.get("notes", [])
        if isinstance(note, dict) and isinstance(note.get("sourceItemId"), str)
    }
    seeded_notes = {
        note["sourceItemId"]: note for note in manifest.get("seededNotes", [])
        if isinstance(note, dict) and isinstance(note.get("sourceItemId"), str)
    }

    current_by_source: dict[str, dict[str, Any] | None] = {}
    for item in manifest["operations"]:
        matches = search_wiki_id(item["wikiId"], project_root, registry, manifest["migrationId"])
        if len(matches) > 1:
            raise MigrationError(f"migration write intent wiki_id is not unique: {item['wikiId']}")
        current = matches[0] if matches else None
        if current and (current.get("sourceId") != item["sourceId"] or current.get("path") != item["path"]):
            raise MigrationError(f"migration write intent escaped its Source or path: {item['sourceItemId']}")
        allowed_hashes = {item["contentHash"]}
        if item["operation"] == "create":
            allowed_hashes.add(item["seedHash"])
            if current and current.get("contentHash") not in allowed_hashes:
                raise MigrationError(f"migration write intent drift for {item['sourceItemId']}")
        elif not current or current.get("contentHash") not in {item["beforeHash"], item["contentHash"]}:
            raise MigrationError(f"migration write intent drift for {item['sourceItemId']}")
        current_by_source[item["sourceItemId"]] = current

    # Create a valid edge-free Note for every new identity first. The second CAS pass can then
    # author typed links in any order, including mutually-referential cycles.
    for item in writable:
        if item["decision"] != "create":
            continue
        source_id = item["sourceItemId"]
        intent = operation_intents[source_id]
        current = current_by_source[source_id]
        if source_id in existing_notes or source_id in seeded_notes or current is not None:
            continue
        result = bundle_call(
            "apply-note-change",
            {
                "sourceId": item["targetSource"]["sourceId"],
                "operation": "create",
                "path": intent["path"],
                "content": prepared[source_id]["seedContent"],
                "expectedHash": None,
                "authorized": True,
                "publishFeatureSlug": manifest["migrationId"],
            },
            project_root,
            registry,
        )
        diff = result.get("diff") if isinstance(result.get("diff"), dict) else {}
        if diff.get("afterHash") != intent["seedHash"]:
            raise MigrationError(f"seed write receipt hash mismatch for {source_id}")
        seeded = {
            "sourceItemId": source_id,
            "sourceId": item["targetSource"]["sourceId"],
            "repositoryRef": intent["repositoryRef"],
            "bindingDigest": intent["bindingDigest"],
            "wikiId": item["noteId"],
            "path": intent["path"],
            "contentHash": intent["seedHash"],
        }
        manifest["seededNotes"].append(seeded)
        manifest["seededNotes"].sort(key=lambda note: note["sourceItemId"])
        seeded_notes[source_id] = seeded
        atomic_write_json(path, manifest)
        current_by_source[source_id] = {"contentHash": intent["seedHash"]}

    for source_id, current in current_by_source.items():
        intent = operation_intents[source_id]
        if intent["operation"] == "create" and current and current.get("contentHash") == intent["seedHash"] and source_id not in seeded_notes:
            seeded = {
                "sourceItemId": source_id,
                "sourceId": intent["sourceId"],
                "repositoryRef": intent["repositoryRef"],
                "bindingDigest": intent["bindingDigest"],
                "wikiId": intent["wikiId"],
                "path": intent["path"],
                "contentHash": intent["seedHash"],
            }
            manifest["seededNotes"].append(seeded)
            manifest["seededNotes"].sort(key=lambda note: note["sourceItemId"])
            seeded_notes[source_id] = seeded
            atomic_write_json(path, manifest)

    for item in writable:
        source_id = item["sourceItemId"]
        intent = operation_intents[source_id]
        after_hash = intent["contentHash"]
        resumed = existing_notes.get(source_id)
        if resumed:
            if resumed.get("contentHash") != after_hash:
                raise MigrationError(f"migration resume content differs for {source_id}")
            continue
        operation = intent["operation"]
        before_hash = intent["beforeHash"]
        seeded = seeded_notes.get(source_id)
        current = current_by_source[source_id]
        if current and current.get("contentHash") == after_hash:
            diff: dict[str, Any] = {"beforeHash": None, "afterHash": after_hash}
        else:
            effective_operation = "update" if operation == "create" else operation
            effective_before = seeded["contentHash"] if operation == "create" and seeded else before_hash
            result = bundle_call(
                "apply-note-change",
                {
                    "sourceId": item["targetSource"]["sourceId"],
                    "operation": effective_operation,
                    "path": intent["path"],
                    "content": prepared[source_id]["content"],
                    "expectedHash": effective_before,
                    "authorized": True,
                    "publishFeatureSlug": manifest["migrationId"],
                },
                project_root,
                registry,
            )
            diff = result.get("diff") if isinstance(result.get("diff"), dict) else {}
            if diff.get("afterHash") != after_hash:
                raise MigrationError(f"write receipt hash mismatch for {source_id}")
            current_by_source[source_id] = {"contentHash": after_hash}
        note_receipt = {
            "sourceItemId": source_id,
            "sourceKind": item["sourceKind"],
            "sourceId": item["targetSource"]["sourceId"],
            "repositoryRef": intent["repositoryRef"],
            "bindingDigest": intent["bindingDigest"],
            "wikiId": item["noteId"],
            "path": intent["path"],
            "operation": operation,
            "beforeHash": before_hash,
            "contentHash": after_hash,
            "noteType": intent["noteType"],
            "constraintStrength": intent["constraintStrength"],
            "edges": intent["edges"],
        }
        manifest["notes"].append(note_receipt)
        manifest["notes"].sort(key=lambda note: note["sourceItemId"])
        atomic_write_json(path, manifest)

    assert_operation_coverage({**manifest, "state": "published"}, stored_plan)
    manifest["state"] = "publishing"
    atomic_write_json(path, manifest)
    return finish_publication(manifest, path, project_root, registry)


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
    plan = validate_manifest_plan(manifest)
    assert_operation_coverage(manifest, plan)
    if manifest.get("state") not in ("published", "verified", "cutover"):
        raise MigrationError("migration manifest is not fully published")
    assert_resume_source_current(plan, project_root, registry)
    repositories = manifest.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        raise MigrationError("migration manifest has no published repositories")
    operations = {item["sourceItemId"]: item for item in manifest["operations"]}
    expected_repositories: dict[str, list[str]] = {}
    for operation in operations.values():
        expected_repositories.setdefault(operation["repositoryRef"], []).append(operation["path"])
    expected_repository_coverage = {
        repository_ref: sorted(set(paths))
        for repository_ref, paths in expected_repositories.items()
    }
    actual_repository_coverage: dict[str, list[str]] = {}
    for repository in repositories:
        if not isinstance(repository, dict) or not isinstance(repository.get("prUrl"), str):
            raise MigrationError("migration repository receipt has no PR URL")
        repository_ref = repository.get("repositoryRef")
        paths = repository.get("paths")
        if not isinstance(repository_ref, str) or not isinstance(paths, list) or any(not isinstance(item, str) for item in paths):
            raise MigrationError("migration repository receipt has invalid coverage")
        if repository_ref in actual_repository_coverage:
            raise MigrationError("migration repository coverage contains duplicates")
        actual_repository_coverage[repository_ref] = sorted(paths)
        state = gh_pr_state(repository["prUrl"])
        if state.get("state") != "MERGED" or not state.get("mergedAt"):
            raise MigrationError(f"migration PR is not merged: {repository['prUrl']}")
    if actual_repository_coverage != expected_repository_coverage:
        raise MigrationError("migration repository coverage differs from the immutable operation roster")

    status = bundle_call("status", None, project_root, registry)
    if status.get("healthy") is not True:
        raise MigrationError("Obsidian Wiki bindings are unhealthy after migration: " + "; ".join(status.get("errors", [])))
    target_ids = {source["sourceId"] for source in plan["targetSources"]}
    status_bindings = {
        binding.get("sourceId"): binding
        for binding in status.get("bindings", [])
        if isinstance(binding, dict)
    }
    for source_id in target_ids:
        binding = status_bindings.get(source_id)
        if not binding or binding.get("repositoryHealth", {}).get("baseSynchronized") is not True:
            raise MigrationError(f"target Source base is not synchronized after migration: {source_id}")
    current_binding_snapshot = binding_snapshot(status, plan["targetSources"])
    if current_binding_snapshot != manifest.get("bindingSnapshot"):
        raise MigrationError("migration binding snapshot drift after publication")

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
        intent = operations.get(expected.get("sourceItemId"))
        if not intent:
            raise MigrationError("migration Note mapping coverage differs from the immutable plan")
        immutable_fields = (
            "sourceKind", "sourceId", "repositoryRef", "bindingDigest", "wikiId", "path",
            "operation", "beforeHash", "contentHash", "noteType", "constraintStrength", "edges",
        )
        if any(expected.get(field) != intent.get(field) for field in immutable_fields):
            raise MigrationError(f"migration Note receipt identity drift: {expected.get('sourceItemId')}")
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
    plan = validate_manifest_plan(verified)
    selected_roles = {source["role"] for source in plan["targetSources"]}
    roots = []
    for role, relative in (("project", ".adapter/wiki"), ("shared", ".shared-adapter/wiki")):
        if role not in selected_roles:
            continue
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
