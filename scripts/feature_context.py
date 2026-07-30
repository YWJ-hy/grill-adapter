#!/usr/bin/env python3
"""Canonical paths for a feature's local grill-adapter working state."""

from __future__ import annotations

from pathlib import Path


CONTEXT_ROOT_RELATIVE = Path(".grill-adapter") / "context"
FEATURE_ARTIFACTS = {
    "selection": "obsidian-wiki-selection.json",
    "context": "wiki-context.json",
    "roster": "ticket-roster.json",
    "issue": "issue.json",
    "brief": "task-brief.md",
    "journal": "wiki-candidates.jsonl",
    "readiness": "wiki-readiness.json",
    "session_state": "wiki-session-state.json",
    "publish": "wiki-publish.json",
}


class FeatureContextPathError(ValueError):
    """Raised when a feature slug cannot safely name a local directory."""


def normalize_feature_slug(feature_slug: str) -> str:
    slug = feature_slug.strip() if isinstance(feature_slug, str) else ""
    if not slug:
        raise FeatureContextPathError("feature slug must be a non-empty string")
    if Path(slug).name != slug or slug in {".", ".."}:
        raise FeatureContextPathError("feature slug must be a plain directory name")
    return slug


def context_root(project_root: Path | str) -> Path:
    return Path(project_root).expanduser().resolve() / CONTEXT_ROOT_RELATIVE


def feature_context_dir(project_root: Path | str, feature_slug: str) -> Path:
    return context_root(project_root) / normalize_feature_slug(feature_slug)


def feature_artifact_path(project_root: Path | str, feature_slug: str, artifact: str) -> Path:
    try:
        filename = FEATURE_ARTIFACTS[artifact]
    except KeyError as exc:
        raise FeatureContextPathError(f"unknown feature context artifact: {artifact}") from exc
    return feature_context_dir(project_root, feature_slug) / filename


def feature_artifact_paths(project_root: Path | str, artifact: str) -> list[Path]:
    """List canonical artifacts for all feature directories under a project."""
    try:
        filename = FEATURE_ARTIFACTS[artifact]
    except KeyError as exc:
        raise FeatureContextPathError(f"unknown feature context artifact: {artifact}") from exc
    root = context_root(project_root)
    return [path for path in root.glob(f"*/{filename}") if path.is_file()]


def is_feature_context_dir(directory: Path | str, project_root: Path | str) -> bool:
    directory_path = Path(directory).expanduser().resolve()
    return directory_path.parent == context_root(project_root)


def infer_project_root(path: Path | str) -> Path | None:
    """Return the project root for either canonical or legacy context artifacts."""
    resolved = Path(path).expanduser().resolve()
    for candidate in (resolved.parent, *resolved.parents):
        if candidate.name == "context" and candidate.parent.name == ".grill-adapter":
            return candidate.parent.parent
    return None
