#!/usr/bin/env python3
"""Build a deterministic, auditable, read-only legacy Wiki migration plan.

The planner reads legacy project/shared Wiki roots plus the configured Obsidian
Source worktrees. It writes JSON to stdout only. It never edits either side and
does not invoke Obsidian, Git, an MCP server, or a write bridge.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scaffold_practice_skill import skill_contract_hash  # noqa: E402
from wiki_common import build_wiki_index_graph  # noqa: E402
from wiki_section import (  # noqa: E402
    extract_all_sections,
    extract_section_roles,
    extract_section_summaries,
    list_section_ids,
    page_type,
    validate_section_markers,
)


PLAN_KIND = "grill-adapter.obsidian-migration-plan"
HARD_RE = re.compile(
    r"\b(?:MUST|MUST NOT|REQUIRED|SHALL|SHALL NOT)\b|必须|禁止|不得|严禁|强制|mandatory",
    re.IGNORECASE,
)
SKILL_NAME_RE = re.compile(r"(?:必须使用\s*skill[：:]?|skill[：:]?)\s*`([a-z0-9][a-z0-9-]*)`", re.IGNORECASE)
SKILL_TRIGGERS_RE = re.compile(r"^\s*(?:适用|triggers?)\s*[：:]\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)
EDGE_PROPERTIES = {
    "depends-on": "depends_on",
    "see-also": "see_also",
    "supersedes": "supersedes",
    "contradicts": "contradicts",
}


class PlanError(RuntimeError):
    pass


def read_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise PlanError(f"{description} not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise PlanError(f"invalid JSON in {description} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PlanError(f"{description} must be a JSON object: {path}")
    return value


def parse_frontmatter(text: str) -> dict[str, Any]:
    normalized = text.replace("\r\n", "\n")
    if not normalized.startswith("---\n"):
        return {}
    end = normalized.find("\n---\n", 4)
    if end < 0:
        return {}
    lines = normalized[4:end].splitlines()
    values: dict[str, Any] = {}
    index = 0
    while index < len(lines):
        match = re.match(r"^([a-z_]+):\s*(.*)$", lines[index])
        if not match:
            index += 1
            continue
        key, raw = match.groups()
        if raw:
            values[key] = raw.strip().strip("'\"")
            index += 1
            continue
        items: list[str] = []
        index += 1
        while index < len(lines):
            item = re.match(r"^\s+-\s+(.*)$", lines[index])
            if not item:
                break
            items.append(item.group(1).strip().strip("'\""))
            index += 1
        values[key] = items
    return values


def stable_digest(entries: list[tuple[str, bytes]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"grill-adapter.obsidian-migration-snapshot/v1\0")
    for label, content in sorted(entries):
        digest.update(label.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(content).digest())
        digest.update(b"\0")
    return f"sha256:{digest.hexdigest()}"


def file_entries(root: Path, prefix: str, include_meta: bool = True) -> list[tuple[str, bytes]]:
    if not root.is_dir():
        return []
    entries = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or (not include_meta and "_meta" in path.relative_to(root).parts):
            continue
        entries.append((f"{prefix}/{path.relative_to(root).as_posix()}", path.read_bytes()))
    return entries


def slug_segment(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = re.sub(r"[\s_]+", "-", normalized)
    normalized = "".join(char for char in normalized if char.isalnum() or char == "-")
    normalized = re.sub(r"-+", "-", normalized).strip("-")
    if normalized:
        return normalized
    return "item-" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def slug_path(path: str) -> str:
    source = Path(path)
    without_suffix = source.with_suffix("")
    return "/".join(slug_segment(part) for part in without_suffix.parts)


def source_item_id(root_name: str, kind: str, identity: str) -> str:
    return f"legacy:{root_name}:{kind}:{identity}"


def graph_item_id(root_name: str, kind: str, value: dict[str, Any]) -> str:
    canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    suffix = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:20]
    return source_item_id(root_name, kind, suffix)


def strength_for(body: str, skill_name: str | None = None) -> tuple[str, str]:
    if skill_name:
        return "hard", "legacy-skill-discovery"
    if HARD_RE.search(body):
        return "hard", "normative-language"
    return "soft", "non-normative-language"


def skill_triggers(body: str) -> list[str]:
    match = SKILL_TRIGGERS_RE.search(body)
    if not match:
        return []
    return [token.strip() for token in re.split(r"[,，、]", match.group(1)) if token.strip()]


def heading_count(text: str, level: int = 2) -> int:
    prefix = "#" * level
    return sum(1 for line in text.splitlines() if re.match(rf"^{re.escape(prefix)}\s+\S", line))


def load_bindings(
    project_root: Path,
    registry_path: Path,
    selected_roles: list[str],
    project_source_id: str | None,
    shared_source_id: str | None,
) -> tuple[dict[str, dict[str, Any]], list[tuple[str, bytes]]]:
    settings_path = project_root / ".shared-adapter" / "settings.json"
    settings = read_json(settings_path, "project Wiki settings")
    registry = read_json(registry_path, "Obsidian Wiki registry")
    wiki = settings.get("wiki")
    if not isinstance(wiki, dict):
        raise PlanError("project Wiki settings must contain wiki")
    obsidian = wiki.get("obsidian")
    if not isinstance(obsidian, dict) or not isinstance(obsidian.get("bindings"), list):
        raise PlanError("project Wiki settings must contain wiki.obsidian.bindings")
    repositories = registry.get("repositories")
    if not isinstance(repositories, dict):
        raise PlanError("Obsidian Wiki registry must contain repositories")

    candidates: dict[str, list[dict[str, Any]]] = defaultdict(list)
    configuration_entries: list[tuple[str, bytes]] = [
        ("configuration/project-settings.json", settings_path.read_bytes()),
        ("configuration/registry.json", registry_path.read_bytes()),
    ]
    for raw in obsidian["bindings"]:
        if not isinstance(raw, dict):
            raise PlanError("each wiki.obsidian.bindings entry must be an object")
        role = raw.get("role")
        source_id = raw.get("sourceId")
        root = raw.get("root")
        repository_ref = raw.get("repositoryRef")
        if role not in ("project", "shared") or not all(isinstance(value, str) and value for value in (source_id, root, repository_ref)):
            raise PlanError("each binding must declare sourceId, role, repositoryRef, and root")
        repository = repositories.get(repository_ref)
        if not isinstance(repository, dict) or not isinstance(repository.get("worktreeRoot"), str):
            raise PlanError(f"binding {source_id} has unavailable repositoryRef {repository_ref}")
        worktree_root = Path(repository["worktreeRoot"]).expanduser().resolve()
        source_root = (worktree_root / root).resolve()
        try:
            source_root.relative_to(worktree_root)
        except ValueError as exc:
            raise PlanError(f"binding {source_id} root escapes its repository") from exc
        manifest_path = source_root / "_meta" / "wiki-source.md"
        if not manifest_path.is_file():
            raise PlanError(f"binding {source_id} Source manifest not found: {manifest_path}")
        manifest = parse_frontmatter(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("wiki_source_id") != source_id or manifest.get("scope") != role:
            raise PlanError(f"binding {source_id} does not match its Source manifest")
        notes: list[dict[str, str]] = []
        for note_path in sorted(source_root.rglob("*.md")):
            relative = note_path.relative_to(worktree_root)
            if "_meta" in note_path.relative_to(source_root).parts:
                continue
            frontmatter = parse_frontmatter(note_path.read_text(encoding="utf-8"))
            wiki_id = frontmatter.get("wiki_id")
            if isinstance(wiki_id, str) and wiki_id:
                notes.append({"wikiId": wiki_id, "path": relative.as_posix()})
        candidates[role].append({
            "sourceId": source_id,
            "role": role,
            "root": Path(root).as_posix().rstrip("/"),
            "sourceRoot": source_root,
            "manifest": manifest,
            "notes": notes,
            "snapshotEntries": file_entries(source_root, f"target/{source_id}"),
        })

    requested = {"project": project_source_id, "shared": shared_source_id}
    by_role: dict[str, dict[str, Any]] = {}
    snapshot_entries = list(configuration_entries)
    for role in selected_roles:
        choices = candidates.get(role, [])
        requested_id = requested[role]
        if requested_id:
            chosen = next((candidate for candidate in choices if candidate["sourceId"] == requested_id), None)
            if chosen is None:
                raise PlanError(f"--{role}-source-id {requested_id} does not name a configured {role} Source")
        elif len(choices) == 1:
            chosen = choices[0]
        elif not choices:
            raise PlanError(f"no Obsidian binding has role {role}")
        else:
            option = f"--{role}-source-id"
            ids = ", ".join(candidate["sourceId"] for candidate in choices)
            raise PlanError(f"multiple Obsidian bindings have role {role}; select one with {option} ({ids})")
        by_role[role] = chosen
        snapshot_entries.extend(chosen["snapshotEntries"])
    return by_role, snapshot_entries


def collect_legacy_root(project_root: Path, root_name: str, wiki_root: Path) -> dict[str, Any]:
    graph = build_wiki_index_graph(wiki_root)
    indexed_leaves = {path.resolve() for path in graph.leaves}
    indexed_indexes = {path.resolve() for path in graph.indexes}
    pages: list[dict[str, Any]] = []
    sections: list[dict[str, Any]] = []
    indexes: list[dict[str, Any]] = []
    skills: list[dict[str, Any]] = []

    for path in sorted(wiki_root.rglob("*.md")):
        relative = path.relative_to(wiki_root).as_posix()
        if path.name == "index.md" or path.stem.endswith(".index"):
            indexes.append({
                "sourceItemId": source_item_id(root_name, "index", relative),
                "legacyRoot": root_name,
                "path": relative,
                "indexed": path.resolve() in indexed_indexes,
                "kind": "navigation-index",
            })
            continue
        text = path.read_text(encoding="utf-8")
        section_ids = list_section_ids(text)
        marker_errors = validate_section_markers(text)
        page = {
            "sourceItemId": source_item_id(root_name, "page", relative),
            "legacyRoot": root_name,
            "path": relative,
            "indexed": path.resolve() in indexed_leaves,
            "pageType": page_type(text),
            "hasSectionMarkers": bool(section_ids),
            "sectionIds": section_ids,
            "markerErrors": marker_errors,
            "level2HeadingCount": heading_count(text),
        }
        page["constraintStrength"], page["strengthBasis"] = strength_for(text)
        pages.append(page)
        bodies = extract_all_sections(text)
        summaries = extract_section_summaries(text)
        roles = extract_section_roles(text)
        for section_id in section_ids:
            body = bodies.get(section_id, "")
            skill_match = SKILL_NAME_RE.search(body) if relative == "guides/skills.md" else None
            skill_name = skill_match.group(1) if skill_match else (section_id if relative == "guides/skills.md" else None)
            strength, basis = strength_for(body, skill_name)
            record = {
                "sourceItemId": source_item_id(root_name, "section", f"{relative}#{section_id}"),
                "legacyRoot": root_name,
                "path": relative,
                "sectionId": section_id,
                "summary": summaries.get(section_id, "").strip(),
                "constraintStrength": strength,
                "strengthBasis": basis,
                "pageType": page["pageType"],
            }
            if skill_name:
                triggers = skill_triggers(body)
                record["skillName"] = skill_name
                record["legacyRoles"] = roles.get(section_id, ["implement", "review"])
                record["skillTriggers"] = triggers
                skills.append({
                    "sourceItemId": record["sourceItemId"],
                    "legacyRoot": root_name,
                    "path": relative,
                    "sectionId": section_id,
                    "skillName": skill_name,
                    "roles": record["legacyRoles"],
                    "triggers": triggers,
                    "summary": record["summary"],
                })
            sections.append(record)

    graph_edges: list[dict[str, Any]] = []
    dangling: list[dict[str, Any]] = []
    graph_path = wiki_root / ".graph.json"
    if graph_path.is_file():
        graph_data = read_json(graph_path, f"{root_name} legacy section graph")
        for edge in graph_data.get("edges", []):
            if isinstance(edge, dict):
                record = {"legacyRoot": root_name, **edge}
                record["sourceItemId"] = graph_item_id(root_name, "graph-edge", record)
                graph_edges.append(record)
        for entry in graph_data.get("dangling", []):
            if isinstance(entry, dict):
                record = {"legacyRoot": root_name, **entry}
                record["sourceItemId"] = graph_item_id(root_name, "dangling-edge", record)
                dangling.append(record)

    return {
        "pages": pages,
        "sections": sections,
        "indexes": indexes,
        "graphEdges": graph_edges,
        "danglingEdges": dangling,
        "skillDiscovery": skills,
    }


def note_identity(binding: dict[str, Any], page_path: str, section_id: str | None, skill_name: str | None) -> tuple[str, str]:
    source_id = binding["sourceId"]
    binding_root = binding["root"]
    if skill_name:
        name = slug_segment(skill_name)
        return f"{source_id}/skills/{name}", f"{binding_root}/Skills/{name}.md"
    base = slug_path(page_path)
    if section_id:
        section = slug_segment(section_id)
        return f"{source_id}/{base}/{section}", f"{binding_root}/{base}/{section}.md"
    return f"{source_id}/{base}", f"{binding_root}/{base}.md"


def pack_metadata(project_root: Path, skill_name: str) -> tuple[dict[str, Any] | None, str | None]:
    pack = project_root / ".claude" / "skills" / skill_name
    skill_file = pack / "SKILL.md"
    if not skill_file.is_file():
        return None, f"project skill pack is unavailable: .claude/skills/{skill_name}/SKILL.md"
    frontmatter = parse_frontmatter(skill_file.read_text(encoding="utf-8"))
    if frontmatter.get("name") != skill_name or not isinstance(frontmatter.get("version"), str):
        return None, f"project skill pack {skill_name} lacks matching name/version metadata"
    try:
        contract_hash = skill_contract_hash(pack)
    except Exception as exc:  # Pack validation errors are reported, never hidden or repaired.
        return None, f"project skill pack {skill_name} cannot be hashed: {exc}"
    return {
        "provider": "claude-code-project",
        "name": skill_name,
        "version": frontmatter["version"],
        "contractHash": contract_hash,
    }, None


def neutrality_hits(text: str, binding: dict[str, Any], settings: dict[str, Any]) -> list[str]:
    manifest = binding["manifest"]
    wiki = settings.get("wiki") if isinstance(settings.get("wiki"), dict) else {}
    legacy = wiki.get("sharedNeutrality") if isinstance(wiki.get("sharedNeutrality"), dict) else {}
    terms = sorted(set([*manifest.get("blocked_terms", []), *legacy.get("blockedTerms", [])]))
    patterns = sorted(set([*manifest.get("blocked_patterns", []), *legacy.get("blockedPatterns", [])]))
    hits = [f"term:{term}" for term in terms if isinstance(term, str) and term and term.casefold() in text.casefold()]
    for pattern in patterns:
        if not isinstance(pattern, str) or not pattern:
            continue
        try:
            if re.search(pattern, text):
                hits.append(f"pattern:{pattern}")
        except re.error:
            hits.append(f"invalid-pattern:{pattern}")
    return hits


def build_plan(
    project_root: Path,
    registry_path: Path,
    root_selector: str,
    project_source_id: str | None = None,
    shared_source_id: str | None = None,
) -> dict[str, Any]:
    roots = {
        "project": project_root / ".adapter" / "wiki",
        "shared": project_root / ".shared-adapter" / "wiki",
    }
    selected = [root_selector] if root_selector in roots else ["project", "shared"]
    bindings, target_entries = load_bindings(
        project_root,
        registry_path,
        selected,
        project_source_id,
        shared_source_id,
    )
    settings = read_json(project_root / ".shared-adapter" / "settings.json", "project Wiki settings")
    inventory: dict[str, list[dict[str, Any]]] = {
        "pages": [], "sections": [], "indexes": [], "graphEdges": [],
        "danglingEdges": [], "skillDiscovery": [], "sourceItems": [],
    }
    source_entries: list[tuple[str, bytes]] = []
    for root_name in selected:
        wiki_root = roots[root_name]
        if not wiki_root.is_dir():
            continue
        collected = collect_legacy_root(project_root, root_name, wiki_root)
        for key, values in collected.items():
            inventory[key].extend(values)
        source_entries.extend(file_entries(wiki_root, f"legacy/{root_name}"))

    for skill_name in sorted({item["skillName"] for item in inventory["skillDiscovery"]}):
        source_entries.extend(file_entries(project_root / ".claude" / "skills" / skill_name, f"packs/{skill_name}"))

    for key in ("pages", "sections", "indexes", "graphEdges", "danglingEdges"):
        inventory[key].sort(key=lambda item: item["sourceItemId"])
    inventory["skillDiscovery"].sort(key=lambda item: item["sourceItemId"])
    all_items = [*inventory["pages"], *inventory["sections"], *inventory["indexes"], *inventory["graphEdges"], *inventory["danglingEdges"]]
    inventory["sourceItems"] = [
        {"sourceItemId": item["sourceItemId"], "kind": item["sourceItemId"].split(":", 3)[2]}
        for item in sorted(all_items, key=lambda item: item["sourceItemId"])
    ]

    confirmations: list[dict[str, Any]] = []
    plan_items: dict[str, dict[str, Any]] = {}
    source_ref_to_note: dict[tuple[str, str], str] = {}

    def add_confirmation(code: str, source_ids: list[str], detail: str) -> None:
        confirmations.append({"code": code, "sourceItemIds": sorted(set(source_ids)), "detail": detail})

    target_by_id: dict[str, list[dict[str, str]]] = defaultdict(list)
    for binding in bindings.values():
        for note in binding["notes"]:
            target_by_id[note["wikiId"]].append(note)
    for wiki_id, notes in sorted(target_by_id.items()):
        if len(notes) > 1:
            add_confirmation("duplicate-id", [], f"target Notes duplicate wiki_id {wiki_id}: {', '.join(note['path'] for note in notes)}")

    page_by_key = {(page["legacyRoot"], page["path"]): page for page in inventory["pages"]}
    sections_by_page: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for section in inventory["sections"]:
        sections_by_page[(section["legacyRoot"], section["path"])].append(section)

    planned_notes: list[dict[str, Any]] = []
    for page in inventory["pages"]:
        root_name = page["legacyRoot"]
        binding = bindings.get(root_name)
        item = {
            "sourceItemId": page["sourceItemId"],
            "sourceKind": "page",
            "targetSource": {"sourceId": binding["sourceId"], "role": binding["role"]} if binding else None,
            "noteId": None,
            "proposedPath": None,
            "edgeTransformation": [],
            "decision": "skip" if page["hasSectionMarkers"] else "create",
            "decisionReason": "sectioned page is represented by atomic section Notes" if page["hasSectionMarkers"] else "unsectioned page maps to one atomic Note",
        }
        if not binding:
            item.update(decision="conflict", decisionReason=f"no target Source has role {root_name}")
        elif not page["hasSectionMarkers"]:
            note_id, proposed = note_identity(binding, page["path"], None, None)
            item.update(noteId=note_id, proposedPath=proposed)
            source_ref_to_note[(root_name, page["path"])] = note_id
            planned_notes.append(item)
            if page["level2HeadingCount"] > 1:
                item.update(decision="conflict", decisionReason="unsectioned page has multiple semantic headings and requires an atomic split decision")
                add_confirmation("semantic-split", [page["sourceItemId"]], f"{root_name}:{page['path']} has {page['level2HeadingCount']} level-2 headings")
        if page["markerErrors"]:
            item.update(decision="conflict", decisionReason="legacy section markers are invalid")
            add_confirmation("semantic-split", [page["sourceItemId"]], "; ".join(page["markerErrors"]))
        plan_items[item["sourceItemId"]] = item

    for section in inventory["sections"]:
        root_name = section["legacyRoot"]
        binding = bindings.get(root_name)
        skill_name = section.get("skillName")
        item = {
            "sourceItemId": section["sourceItemId"],
            "sourceKind": "skill-discovery" if skill_name else "section",
            "targetSource": {"sourceId": binding["sourceId"], "role": binding["role"]} if binding else None,
            "noteId": None,
            "proposedPath": None,
            "noteType": "guide" if skill_name else section["pageType"],
            "constraintStrength": section["constraintStrength"],
            "edgeTransformation": [],
            "decision": "create",
            "decisionReason": "legacy section maps to one atomic Note",
        }
        if not binding:
            item.update(decision="conflict", decisionReason=f"no target Source has role {root_name}")
        else:
            note_id, proposed = note_identity(binding, section["path"], section["sectionId"], skill_name)
            item.update(noteId=note_id, proposedPath=proposed)
            source_ref_to_note[(root_name, f"{section['path']}#{section['sectionId']}")] = note_id
            planned_notes.append(item)
            if skill_name:
                metadata, error = pack_metadata(project_root, skill_name)
                if error:
                    item.update(decision="conflict", decisionReason=error)
                    add_confirmation("unavailable-pack", [section["sourceItemId"]], error)
                else:
                    item["skillCard"] = {
                        **metadata,
                        "roles": ["implementer" if role == "implement" else "reviewer" for role in section.get("legacyRoles", [])],
                        "triggers": section.get("skillTriggers", []),
                        "summary": section["summary"],
                    }
                    if not item["skillCard"]["triggers"] or not item["skillCard"]["summary"]:
                        item.update(decision="conflict", decisionReason="legacy skill discovery card lacks a summary or trigger list")
                        add_confirmation("incomplete-skill-card", [section["sourceItemId"]], item["decisionReason"])
        plan_items[item["sourceItemId"]] = item

    planned_by_id: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in planned_notes:
        if item.get("noteId"):
            planned_by_id[item["noteId"]].append(item)
    for note_id, items in sorted(planned_by_id.items()):
        if len(items) > 1:
            for item in items:
                item.update(decision="conflict", decisionReason=f"multiple legacy items map to stable Note ID {note_id}")
            add_confirmation("duplicate-id", [item["sourceItemId"] for item in items], f"multiple legacy items map to stable Note ID {note_id}")
        target_matches = target_by_id.get(note_id, [])
        if len(target_matches) > 1:
            for item in items:
                item.update(decision="conflict", decisionReason=f"target Source contains duplicate Note ID {note_id}")
            add_confirmation("duplicate-id", [item["sourceItemId"] for item in items], f"target Source contains duplicate Note ID {note_id}")
        elif len(items) == 1 and len(target_matches) == 1 and items[0]["decision"] == "create":
            items[0].update(decision="update", decisionReason=f"target Note already exists at {target_matches[0]['path']}")

    for page in inventory["pages"]:
        if page["legacyRoot"] != "shared":
            continue
        binding = bindings.get("shared")
        if not binding:
            continue
        text = (roots["shared"] / page["path"]).read_text(encoding="utf-8")
        hits = neutrality_hits(text, binding, settings)
        if not hits:
            continue
        affected = [page["sourceItemId"]] + [section["sourceItemId"] for section in sections_by_page[("shared", page["path"])]]
        for source_id in affected:
            if source_id in plan_items:
                plan_items[source_id].update(decision="conflict", decisionReason="Shared content violates target Source neutrality policy")
        add_confirmation("shared-neutrality-violation", affected, f"shared:{page['path']} matched {', '.join(hits)}")

    for edge in inventory["graphEdges"]:
        root_name = edge["legacyRoot"]
        source_note = source_ref_to_note.get((root_name, str(edge.get("from", ""))))
        target_note = source_ref_to_note.get((root_name, str(edge.get("to", ""))))
        transform = []
        if source_note and target_note and edge.get("type") in EDGE_PROPERTIES:
            transform = [{"property": EDGE_PROPERTIES[edge["type"]], "targetNoteId": target_note}]
            for candidate in planned_by_id.get(source_note, []):
                candidate["edgeTransformation"].extend(transform)
            decision = "skip"
            reason = f"edge is represented on atomic Note {source_note}"
        else:
            decision = "conflict"
            reason = "edge cannot be mapped to atomic source and target Notes"
            add_confirmation("dangling-edge", [edge["sourceItemId"]], f"cannot transform graph edge {edge.get('from')} -> {edge.get('to')}")
        plan_items[edge["sourceItemId"]] = {
            "sourceItemId": edge["sourceItemId"],
            "sourceKind": "graph-edge",
            "targetSource": {"sourceId": bindings[root_name]["sourceId"], "role": root_name} if root_name in bindings else None,
            "noteId": source_note,
            "proposedPath": None,
            "edgeTransformation": transform,
            "decision": decision,
            "decisionReason": reason,
        }

    for dangling in inventory["danglingEdges"]:
        add_confirmation("dangling-edge", [dangling["sourceItemId"]], f"{dangling.get('from')}: {dangling.get('reason', 'unresolved edge')}")
        plan_items[dangling["sourceItemId"]] = {
            "sourceItemId": dangling["sourceItemId"],
            "sourceKind": "dangling-edge",
            "targetSource": {"sourceId": bindings[dangling["legacyRoot"]]["sourceId"], "role": dangling["legacyRoot"]} if dangling["legacyRoot"] in bindings else None,
            "noteId": source_ref_to_note.get((dangling["legacyRoot"], str(dangling.get("from", "")))),
            "proposedPath": None,
            "edgeTransformation": [],
            "decision": "conflict",
            "decisionReason": str(dangling.get("reason", "legacy graph edge is dangling")),
        }

    for index in inventory["indexes"]:
        add_confirmation("non-migratable-navigation", [index["sourceItemId"]], f"{index['legacyRoot']}:{index['path']} is legacy navigation, not an atomic Note")
        plan_items[index["sourceItemId"]] = {
            "sourceItemId": index["sourceItemId"],
            "sourceKind": "navigation-index",
            "targetSource": {"sourceId": bindings[index["legacyRoot"]]["sourceId"], "role": index["legacyRoot"]} if index["legacyRoot"] in bindings else None,
            "noteId": None,
            "proposedPath": None,
            "edgeTransformation": [],
            "decision": "skip",
            "decisionReason": "legacy index navigation is replaced by Obsidian Source search and typed links",
        }

    for item in planned_notes:
        item["edgeTransformation"].sort(key=lambda value: (value["property"], value["targetNoteId"]))
    confirmations.sort(key=lambda issue: (issue["code"], issue["sourceItemIds"], issue["detail"]))
    ordered_plan = [plan_items[source["sourceItemId"]] for source in inventory["sourceItems"]]
    decision_counts = Counter(item["decision"] for item in ordered_plan)

    return {
        "schemaVersion": 1,
        "kind": PLAN_KIND,
        "generatedBy": "grill-adapter",
        "mode": "plan-only",
        "writePerformed": False,
        "sourceSnapshot": {"algorithm": "sha256:grill-adapter-obsidian-migration-snapshot-v1", "digest": stable_digest(source_entries)},
        "targetSnapshot": {"algorithm": "sha256:grill-adapter-obsidian-migration-snapshot-v1", "digest": stable_digest(target_entries)},
        "targetSources": [
            {"sourceId": bindings[role]["sourceId"], "role": role, "root": bindings[role]["root"]}
            for role in selected
        ],
        "inventory": inventory,
        "planItems": ordered_plan,
        "confirmation": {"required": bool(confirmations), "issues": confirmations},
        "summary": {
            "sourceItemCount": len(inventory["sourceItems"]),
            "planItemCount": len(ordered_plan),
            "decisionCounts": {key: decision_counts.get(key, 0) for key in ("create", "update", "skip", "conflict")},
            "confirmationIssueCount": len(confirmations),
        },
    }


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")


def main() -> None:
    configure_stdio()
    parser = argparse.ArgumentParser(description="Plan a deterministic, no-write legacy Wiki migration to bound Obsidian Sources.")
    parser.add_argument("--project-root", required=True, help="Project containing legacy Wiki roots and Obsidian bindings")
    parser.add_argument("--registry", default=None, help="Obsidian Wiki registry JSON (defaults to OBSIDIAN_WIKI_REGISTRY or ~/.config/grill-adapter/obsidian-wiki.json)")
    parser.add_argument("--wiki-root", choices=["project", "shared", "all"], default="all")
    parser.add_argument("--project-source-id", default=None, help="Select the target project Source when configuration is ambiguous")
    parser.add_argument("--shared-source-id", default=None, help="Select the target Shared Source when multiple shared bindings exist")
    args = parser.parse_args()
    project_root = Path(args.project_root).expanduser().resolve()
    registry_value = args.registry or __import__("os").environ.get("OBSIDIAN_WIKI_REGISTRY")
    registry_path = Path(registry_value).expanduser().resolve() if registry_value else Path.home() / ".config" / "grill-adapter" / "obsidian-wiki.json"
    try:
        plan = build_plan(
            project_root,
            registry_path,
            args.wiki_root,
            project_source_id=args.project_source_id,
            shared_source_id=args.shared_source_id,
        )
    except (PlanError, OSError, ValueError) as exc:
        print(f"migration plan failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
