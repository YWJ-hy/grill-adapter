"""Validation and identity helpers for project ADR-backed Wiki projections."""

from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath


class AdrIdentityError(ValueError):
    """Raised when an ADR projection source cannot be trusted."""


def canonical_text(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def normalize_source_path(value: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AdrIdentityError("ADR source path must be a non-empty string")
    if "\\" in value or value.startswith("/"):
        raise AdrIdentityError("ADR source path must be project-relative POSIX text")
    path = PurePosixPath(value)
    parts = path.parts
    if (
        len(parts) < 3
        or parts[-1] in {"", ".", ".."}
        or not parts[-1].endswith(".md")
        or any(part in {"", ".", ".."} for part in parts)
        or not any(parts[index:index + 2] == ("docs", "adr") for index in range(len(parts) - 1))
    ):
        raise AdrIdentityError("ADR source path must be a normalized path under docs/adr")
    normalized = path.as_posix()
    if normalized != value:
        raise AdrIdentityError("ADR source path must be normalized")
    return normalized


def source_id_for_path(source_path: str) -> str:
    normalized = normalize_source_path(source_path)
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    return f"project-adr:{digest}"


def content_hash(text: str) -> str:
    digest = hashlib.sha256(canonical_text(text).encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def resolve_source(project_root: Path, source_path: str) -> Path:
    normalized = normalize_source_path(source_path)
    root = project_root.resolve()
    candidate = (root / PurePosixPath(normalized)).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise AdrIdentityError("ADR source path resolves outside the project root") from exc
    if not candidate.is_file():
        raise AdrIdentityError(f"ADR source file is missing: {normalized}")
    return candidate


def current_identity(project_root: Path, source_path: str) -> tuple[str, str]:
    candidate = resolve_source(project_root, source_path)
    text = candidate.read_text(encoding="utf-8")
    normalized = normalize_source_path(source_path)
    return source_id_for_path(normalized), content_hash(text)


def validate_identity(
    project_root: Path,
    source_id: str,
    source_path: str,
    source_content_hash: str,
) -> None:
    expected_id, expected_hash = current_identity(project_root, source_path)
    if source_id != expected_id:
        raise AdrIdentityError(
            f"ADR source identity drift for {source_path}: expected {expected_id}, got {source_id}"
        )
    if source_content_hash != expected_hash:
        raise AdrIdentityError(
            f"ADR source content drift for {source_path}: expected {expected_hash}, got {source_content_hash}"
        )
