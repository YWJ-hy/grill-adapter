#!/usr/bin/env python3
"""Role-specific, user-visible Wiki task snapshots."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any


SNAPSHOT_SCHEMA_VERSION = 1
SNAPSHOT_KIND = "grill-adapter.task-wiki-snapshot"
SNAPSHOT_GENERATED_BY = "grill-adapter"
APPROVAL_SCHEMA_VERSION = 1
APPROVAL_KIND = "grill-adapter.task-wiki-approval"
SNAPSHOT_MARKER = "<!-- grill-adapter:task-wiki-snapshot"
SNAPSHOT_END = "-->"
ROLES = {"implementer", "reviewer"}
ROLE_SUFFIXES = {"implementer": "implement", "reviewer": "review"}


class SnapshotError(Exception):
    pass


def _digest_bytes(value: bytes) -> str:
    return f"sha256:{hashlib.sha256(value).hexdigest()}"


def file_digest(path: Path) -> str:
    try:
        return _digest_bytes(path.read_bytes())
    except OSError as exc:
        raise SnapshotError(f"could not read {path}: {exc}") from exc


def safe_task_id(task_id: str) -> str:
    if not isinstance(task_id, str) or not task_id.strip():
        raise SnapshotError("taskId must be a non-empty string")
    value = task_id.strip()
    if value in {".", ".."} or Path(value).name != value or "/" in value or "\\" in value:
        raise SnapshotError("taskId must not contain path separators")
    return value


def snapshot_filename(task_id: str, role: str) -> str:
    task_id = safe_task_id(task_id)
    if role not in ROLES:
        raise SnapshotError(f"snapshot role must be one of {', '.join(sorted(ROLES))}")
    return f"{task_id}.wiki-{ROLE_SUFFIXES[role]}.md"


def snapshot_path(context_path: Path, task_id: str, role: str) -> Path:
    return context_path.resolve().parent / snapshot_filename(task_id, role)


def approval_filename(task_id: str) -> str:
    return f"{safe_task_id(task_id)}.wiki-approval.json"


def approval_path(context_path: Path, task_id: str) -> Path:
    return context_path.resolve().parent / approval_filename(task_id)


def _body_from_file(text: str) -> str:
    prefix = SNAPSHOT_MARKER + "\n"
    if not text.startswith(prefix):
        raise SnapshotError("snapshot is missing the grill-adapter metadata marker")
    marker = "\n" + SNAPSHOT_END + "\n"
    end = text.find(marker, len(prefix))
    if end < 0:
        raise SnapshotError("snapshot metadata marker is not closed")
    body = text[end + len(marker) :]
    if not body.strip():
        raise SnapshotError("snapshot body must not be empty")
    return body


def parse_snapshot_text(text: str) -> tuple[dict[str, Any], str]:
    prefix = SNAPSHOT_MARKER + "\n"
    if not text.startswith(prefix):
        raise SnapshotError("snapshot is missing the grill-adapter metadata marker")
    marker = "\n" + SNAPSHOT_END + "\n"
    end = text.find(marker, len(prefix))
    if end < 0:
        raise SnapshotError("snapshot metadata marker is not closed")
    metadata_text = text[len(prefix) : end]
    try:
        metadata = json.loads(metadata_text)
    except json.JSONDecodeError as exc:
        raise SnapshotError(f"snapshot metadata is invalid JSON: {exc}") from exc
    if not isinstance(metadata, dict):
        raise SnapshotError("snapshot metadata must be a JSON object")
    body = text[end + len(marker) :]
    if not body.strip():
        raise SnapshotError("snapshot body must not be empty")
    expected_digest = metadata.get("bodyDigest")
    if not isinstance(expected_digest, str) or expected_digest != _digest_bytes(body.encode("utf-8")):
        raise SnapshotError("snapshot body digest does not match its metadata")
    return metadata, body


def load_snapshot(path: Path) -> tuple[dict[str, Any], str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SnapshotError(f"could not read snapshot {path}: {exc}") from exc
    return parse_snapshot_text(text)


def _required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SnapshotError(f"{field} must be a non-empty string")
    return value.strip()


def validate_snapshot(
    path: Path,
    *,
    context_path: Path,
    feature_slug: str,
    ticket_source: str,
    task_id: str,
    task_title: str,
    task_fingerprint: str,
    role: str,
    expected_digest: str | None = None,
) -> tuple[dict[str, Any], str]:
    metadata, body = load_snapshot(path)
    if metadata.get("schemaVersion") != SNAPSHOT_SCHEMA_VERSION:
        raise SnapshotError(f"snapshot schemaVersion must be {SNAPSHOT_SCHEMA_VERSION}")
    if metadata.get("kind") != SNAPSHOT_KIND:
        raise SnapshotError(f"snapshot kind must be {SNAPSHOT_KIND}")
    if metadata.get("generatedBy") != SNAPSHOT_GENERATED_BY:
        raise SnapshotError("snapshot generatedBy must be grill-adapter")
    checks = {
        "featureSlug": feature_slug,
        "ticketSource": ticket_source,
        "taskId": task_id,
        "taskTitle": task_title,
        "taskFingerprint": task_fingerprint,
        "role": role,
        "contextFile": context_path.name,
        "contextDigest": file_digest(context_path),
    }
    for field, expected in checks.items():
        if metadata.get(field) != expected:
            raise SnapshotError(f"snapshot {field} does not match the current task")
    if role not in ROLES:
        raise SnapshotError(f"snapshot role must be one of {', '.join(sorted(ROLES))}")
    if expected_digest is not None:
        actual_digest = file_digest(path)
        if actual_digest != expected_digest:
            raise SnapshotError(f"snapshot file drifted: expected {expected_digest}, got {actual_digest}")
    return metadata, body


def render_snapshot(
    *,
    context: dict[str, Any],
    context_path: Path,
    task: dict[str, str],
    task_id: str,
    role: str,
    rendered: str,
    materialized: str,
    origin: str,
) -> str:
    task_id = safe_task_id(task_id)
    if role not in ROLES:
        raise SnapshotError(f"snapshot role must be one of {', '.join(sorted(ROLES))}")
    body_parts = [
        "# Task Wiki Snapshot",
        "",
        f"- Task: `{task_id}` · {task['title']}",
        f"- Role: `{role}`",
        f"- Snapshot origin: `{origin}`",
        "",
        rendered.strip(),
    ]
    if materialized.strip():
        body_parts.extend(["", materialized.strip()])
    if role == "reviewer":
        body_parts.extend(
            [
                "",
                "## Reviewer Handoff",
                "",
                "- Status: ready",
                "- Use this same read-only context for both isolated review axes.",
                "- Standards reports repository-standard and code-quality findings only.",
                "- Spec reports issue/spec completeness, correctness, and scope findings only.",
                "- Wiki constraints may inform either axis but must not merge or change its output structure.",
            ]
        )
    body = "\n".join(body_parts).rstrip() + "\n"
    metadata: dict[str, Any] = {
        "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
        "kind": SNAPSHOT_KIND,
        "generatedBy": SNAPSHOT_GENERATED_BY,
        "featureSlug": context["featureSlug"],
        "ticketSource": context["ticketSource"],
        "taskId": task_id,
        "taskTitle": task["title"],
        "taskFingerprint": task["hash"],
        "role": role,
        "contextFile": context_path.name,
        "contextDigest": file_digest(context_path),
        "sourceSnapshotHash": context.get("snapshotHash"),
        "snapshotOrigin": origin,
        "bodyDigest": _digest_bytes(body.encode("utf-8")),
    }
    metadata_text = json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True)
    return f"{SNAPSHOT_MARKER}\n{metadata_text}\n{SNAPSHOT_END}\n{body}"


def write_snapshot(path: Path, text: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        parse_snapshot_text(text)
    except SnapshotError:
        raise
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_name = handle.name
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        Path(temp_name).replace(path)
    finally:
        if temp_name:
            Path(temp_name).unlink(missing_ok=True)
    return file_digest(path)


def write_approval(
    path: Path,
    *,
    context_path: Path,
    context: dict[str, Any],
    task: dict[str, str],
    task_id: str,
    implement_digest: str,
    review_digest: str,
) -> None:
    payload = {
        "schemaVersion": APPROVAL_SCHEMA_VERSION,
        "kind": APPROVAL_KIND,
        "generatedBy": SNAPSHOT_GENERATED_BY,
        "featureSlug": context["featureSlug"],
        "ticketSource": context["ticketSource"],
        "taskId": safe_task_id(task_id),
        "taskTitle": task["title"],
        "taskFingerprint": task["hash"],
        "contextFile": context_path.name,
        "contextDigest": file_digest(context_path),
        "sourceSnapshotHash": context.get("snapshotHash"),
        "implementWikiFile": snapshot_filename(task_id, "implementer"),
        "implementWikiDigest": implement_digest,
        "reviewWikiFile": snapshot_filename(task_id, "reviewer"),
        "reviewWikiDigest": review_digest,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_name = handle.name
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        Path(temp_name).replace(path)
    finally:
        if temp_name:
            Path(temp_name).unlink(missing_ok=True)


def validate_approval(
    path: Path,
    *,
    context_path: Path,
    context: dict[str, Any],
    task: dict[str, str],
    task_id: str,
) -> tuple[str, str]:
    try:
        approval = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SnapshotError(f"could not read approval manifest {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SnapshotError(f"approval manifest is invalid JSON: {exc}") from exc
    if not isinstance(approval, dict):
        raise SnapshotError("approval manifest must be a JSON object")
    if approval.get("schemaVersion") != APPROVAL_SCHEMA_VERSION or approval.get("kind") != APPROVAL_KIND:
        raise SnapshotError("approval manifest schema or kind is invalid")
    expected = {
        "featureSlug": context["featureSlug"],
        "ticketSource": context["ticketSource"],
        "taskId": safe_task_id(task_id),
        "taskTitle": task["title"],
        "taskFingerprint": task["hash"],
        "contextFile": context_path.name,
        "contextDigest": file_digest(context_path),
        "sourceSnapshotHash": context.get("snapshotHash"),
        "implementWikiFile": snapshot_filename(task_id, "implementer"),
        "reviewWikiFile": snapshot_filename(task_id, "reviewer"),
    }
    for field, value in expected.items():
        if approval.get(field) != value:
            raise SnapshotError(f"approval manifest {field} does not match the current task")
    implement_digest = approval.get("implementWikiDigest")
    review_digest = approval.get("reviewWikiDigest")
    if not isinstance(implement_digest, str) or not isinstance(review_digest, str):
        raise SnapshotError("approval manifest is missing role snapshot digests")
    if file_digest(context_path.parent / expected["implementWikiFile"]) != implement_digest:
        raise SnapshotError("approved implementer snapshot drifted")
    if file_digest(context_path.parent / expected["reviewWikiFile"]) != review_digest:
        raise SnapshotError("approved reviewer snapshot drifted")
    return implement_digest, review_digest
