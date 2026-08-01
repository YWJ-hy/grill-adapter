#!/usr/bin/env python3
"""Write the non-authoritative feature continuation summary.

The session state is deliberately a hint-only projection of local workflow artifacts. It never
contains Wiki body text and it is never used to authorize or bind a task. The readiness command
remains the authority for the current roster, context, and frozen task snapshots.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 2
LEGACY_SCHEMA_VERSION = 1
KIND = "grill-adapter.wiki-session-state"
GENERATED_BY = "grill-adapter"
READINESS_STATUSES = {"ready", "no-relevant", "disabled", "broken", "unknown", "unrecorded"}
SESSION_FILENAME = "wiki-session-state.json"
CANDIDATE_STATUSES = ("pending", "deferred", "kept", "skipped", "superseded")
MAINTENANCE_CATEGORIES = ("active", "reviewDue", "expired", "contradictory")
MAX_FEATURE_STATES = 200
MAX_ACTIONS = 3
DIGEST_PATTERN = "sha256:"
RECOVERY_PRIORITIES = {"broken": 0, "unknown": 1, "unrecorded": 2}
MAINTENANCE_URGENT_PRIORITY = 10
MAINTENANCE_REVIEW_PRIORITY = 11
CAPTURE_DEFERRED_PRIORITY = 20
CAPTURE_PENDING_PRIORITY = 21
CONTINUATION_PRIORITY = 40


class SessionStateError(ValueError):
    """Raised when a continuation state cannot be safely written."""


@dataclass(frozen=True)
class NavigationAction:
    priority: int
    modified_ns: int
    action_type: str
    feature_slug: str
    status: str
    command: str

    @property
    def sort_key(self) -> tuple[int, int, str, str]:
        return (self.priority, -self.modified_ns, self.feature_slug, self.action_type)


def _digest_bytes(value: bytes) -> str:
    return f"sha256:{hashlib.sha256(value).hexdigest()}"


def _digest_file(path: Path) -> str | None:
    try:
        return _digest_bytes(path.read_bytes())
    except OSError:
        return None


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _safe_text(value: Any, field: str, *, allow_empty: bool = False) -> str | None:
    if value is None and allow_empty:
        return None
    if not isinstance(value, str):
        raise SessionStateError(f"{field} must be a string")
    text = value.strip()
    if not text and not allow_empty:
        raise SessionStateError(f"{field} must be a non-empty string")
    if any(char in text for char in ("/", "\\")) and field in {"featureSlug", "taskId"}:
        raise SessionStateError(f"{field} must not contain path separators")
    if text in {".", ".."}:
        raise SessionStateError(f"{field} must not be a relative path marker")
    if field in {"featureSlug", "taskId"} and (
        "`" in text or any(ord(char) < 32 or ord(char) == 127 for char in text)
    ):
        raise SessionStateError(f"{field} contains unsafe display characters")
    return text


def _feature_slug_from(directory: Path, *documents: dict[str, Any] | None) -> str:
    values = [
        document.get("featureSlug")
        for document in documents
        if isinstance(document, dict) and isinstance(document.get("featureSlug"), str)
    ]
    if values:
        feature_slug = values[0].strip()
        if any(value.strip() != feature_slug for value in values):
            raise SessionStateError("featureSlug differs between feature artifacts")
    else:
        feature_slug = directory.name
    _safe_text(feature_slug, "featureSlug")
    if directory.name != feature_slug:
        raise SessionStateError("feature directory name does not match featureSlug")
    return feature_slug


def _usable_previous_state(
    state: dict[str, Any] | None,
    *,
    feature_slug: str,
    roster: dict[str, Any] | None,
) -> dict[str, Any]:
    """Return a prior generated projection only when it can safely preserve selection.

    The state file is intentionally non-authoritative. In particular, a damaged or stale prior
    projection must not stop readiness/candidate activity from replacing it with a fresh hint.
    """

    if not isinstance(state, dict):
        return {}
    if (
        state.get("schemaVersion") not in {LEGACY_SCHEMA_VERSION, SCHEMA_VERSION}
        or state.get("kind") != KIND
        or state.get("generatedBy") != GENERATED_BY
        or state.get("featureSlug") != feature_slug
    ):
        return {}

    selected = state.get("lastSelectedTask")
    if selected is not None:
        try:
            selected = _safe_text(selected, "taskId")
        except SessionStateError:
            return {}
        if isinstance(roster, dict) and isinstance(roster.get("tickets"), list):
            roster_ids = {
                item.get("taskId").strip()
                for item in roster["tickets"]
                if isinstance(item, dict) and isinstance(item.get("taskId"), str)
            }
            if selected not in roster_ids:
                return {}

    status = state.get("readinessStatus")
    if status not in READINESS_STATUSES:
        return {}
    command = state.get("nextCommand")
    if not isinstance(command, str) or not command.strip() or len(command.strip()) > 500:
        return {}
    return state


def _ensure_feature_directory(feature_directory: Path) -> Path:
    directory = feature_directory.expanduser().resolve()
    if directory.name in {"", ".", ".."} or directory.parent.name != "context" or directory.parent.parent.name != ".grill-adapter":
        raise SessionStateError(
            "session state must live in <project-root>/.grill-adapter/context/<feature-slug>"
        )
    return directory


def _candidate_lifecycle(
    journal_path: Path,
    feature_slug: str,
) -> tuple[int, dict[str, int], str | None]:
    """Project canonical journal lifecycle counts without copying candidate content."""

    try:
        from wiki_candidate_journal import JournalError, fold_events, read_events

        folded = fold_events(read_events(journal_path), feature_slug)
    except (OSError, UnicodeDecodeError, ValueError, JournalError) as exc:
        raise SessionStateError(f"candidate journal is not valid: {exc}") from exc

    counts = {status: folded["counts"][status] for status in CANDIDATE_STATUSES}
    counts["capturePending"] = counts["pending"] + counts["deferred"]
    counts["correctionPending"] = len(folded["maintenanceSignals"])
    return sum(counts[status] for status in CANDIDATE_STATUSES), counts, _digest_file(journal_path)


def _maintenance_counts(report_path: Path) -> tuple[dict[str, int], str | None]:
    counts = {category: 0 for category in MAINTENANCE_CATEGORIES}
    if not report_path.exists():
        return counts, None
    try:
        from wiki_maintenance_report import ReportError, load_path

        report = load_path(report_path)
    except (OSError, UnicodeDecodeError, ValueError, ReportError) as exc:
        raise SessionStateError(f"maintenance report is not valid: {exc}") from exc
    scanned = report["scanned"]
    counts.update({
        "active": scanned["activeNotes"],
        "reviewDue": scanned["reviewDueNotes"],
        "expired": scanned["expiredNotes"],
        "contradictory": scanned["contradictoryNotes"],
    })
    return counts, _digest_file(report_path)


def _snapshot_digest(feature_directory: Path, task_id: str | None) -> str | None:
    """Digest the selected task's role snapshots, or all snapshots when no task is selected."""

    files: list[tuple[str, Path]] = []
    if task_id:
        files = [
            ("implementer", feature_directory / f"{task_id}.wiki-implement.md"),
            ("reviewer", feature_directory / f"{task_id}.wiki-review.md"),
        ]
    else:
        for path in sorted(feature_directory.glob("*.wiki-implement.md")):
            files.append(("implementer", path))
        for path in sorted(feature_directory.glob("*.wiki-review.md")):
            files.append(("reviewer", path))
    existing = [(role, path) for role, path in files if path.is_file()]
    if not existing:
        return None
    entries: list[dict[str, str]] = []
    for role, path in existing:
        digest = _digest_file(path)
        if digest is not None:
            entries.append({"role": role, "file": path.name, "digest": digest})
    if not entries:
        return None
    canonical = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return _digest_bytes(canonical.encode("utf-8"))


def _selected_readiness(
    readiness: dict[str, Any] | None,
    task_id: str | None,
) -> str | None:
    if not isinstance(readiness, dict):
        return None
    tasks = readiness.get("tasks")
    if not isinstance(tasks, list):
        return None
    for entry in tasks:
        if isinstance(entry, dict) and entry.get("taskId") == task_id:
            status = entry.get("status")
            return status if status in READINESS_STATUSES else "unknown"
    return None


def _default_next_command(task_id: str | None) -> str:
    # Claude Code injects this variable for plugin execution. Codex does not, so its native
    # `$skill` form remains the default for direct CLI/Codex use.
    command = (
        "/grill-adapter:wiki-readiness"
        if os.environ.get("CLAUDE_PROJECT_DIR")
        else "$grill-adapter:wiki-readiness"
    )
    if task_id:
        return f"{command} {shlex.quote(task_id)}"
    return command


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
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
            temporary = handle.name
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        Path(temporary).replace(path)
    finally:
        if temporary:
            Path(temporary).unlink(missing_ok=True)


def update_session_state(
    feature_directory: Path,
    *,
    task_id: str | None = None,
    next_command: str | None = None,
    readiness_status: str | None = None,
) -> Path:
    """Refresh one feature's continuation state and return its path.

    ``task_id`` is only written when a caller explicitly supplies it. Omitting it preserves the
    previous explicit selection, which lets candidate-journal updates refresh digests without
    accidentally changing the current task.
    """

    directory = _ensure_feature_directory(feature_directory)
    state_path = directory / SESSION_FILENAME
    roster_path = directory / "ticket-roster.json"
    context_path = directory / "wiki-context.json"
    readiness_path = directory / "wiki-readiness.json"
    journal_path = directory / "wiki-candidates.jsonl"
    maintenance_report_path = directory / "wiki-maintenance-audit.json"

    roster = _read_json(roster_path)
    context = _read_json(context_path)
    readiness = _read_json(readiness_path)
    feature_slug = _feature_slug_from(directory, roster, context, readiness)
    previous = _usable_previous_state(
        _read_json(state_path),
        feature_slug=feature_slug,
        roster=roster,
    )

    task_was_explicit = task_id is not None
    if task_id is None:
        selected = previous.get("lastSelectedTask")
        task_id = selected.strip() if isinstance(selected, str) and selected.strip() else None
    else:
        task_id = _safe_text(task_id, "taskId")
        if isinstance(roster, dict) and isinstance(roster.get("tickets"), list):
            roster_ids = {
                item.get("taskId")
                for item in roster["tickets"]
                if isinstance(item, dict) and isinstance(item.get("taskId"), str)
            }
            if task_id not in roster_ids:
                raise SessionStateError(f"ticket roster has no task {task_id}")

    if readiness_status is None:
        readiness_status = _selected_readiness(readiness, task_id)
    if readiness_status is None and not task_was_explicit:
        prior_status = previous.get("readinessStatus")
        readiness_status = prior_status if prior_status in READINESS_STATUSES else "unrecorded"
    if readiness_status is None:
        readiness_status = "unrecorded"
    if readiness_status not in READINESS_STATUSES:
        raise SessionStateError(
            f"readinessStatus must be one of {', '.join(sorted(READINESS_STATUSES))}"
        )

    if next_command is None:
        prior_command = previous.get("nextCommand")
        next_command = (
            _default_next_command(task_id)
            if task_was_explicit
            else (
                prior_command.strip()
                if isinstance(prior_command, str) and prior_command.strip()
                else _default_next_command(task_id)
            )
        )
    else:
        next_command = _safe_text(next_command, "nextCommand")
    assert next_command is not None
    if len(next_command) > 500:
        raise SessionStateError("nextCommand must not exceed 500 characters")

    candidate_count, candidate_lifecycle_counts, journal_digest = _candidate_lifecycle(
        journal_path, feature_slug
    )
    maintenance_counts, maintenance_report_digest = _maintenance_counts(maintenance_report_path)

    state = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "generatedBy": GENERATED_BY,
        "featureSlug": feature_slug,
        "lastSelectedTask": task_id,
        "rosterDigest": _digest_file(roster_path),
        "contextDigest": _digest_file(context_path),
        "snapshotDigest": _snapshot_digest(directory, task_id),
        "readinessDigest": _digest_file(readiness_path),
        "readinessStatus": readiness_status,
        "candidateCount": candidate_count,
        "candidateLifecycleCounts": candidate_lifecycle_counts,
        "journalDigest": journal_digest,
        "maintenanceCounts": maintenance_counts,
        "maintenanceReportDigest": maintenance_report_digest,
        "nextCommand": next_command,
    }
    _write_json(state_path, state)
    return state_path


def _is_digest(value: Any) -> bool:
    return (
        isinstance(value, str)
        and value.startswith(DIGEST_PATTERN)
        and len(value) == 71
        and all(char in "0123456789abcdef" for char in value[len(DIGEST_PATTERN):])
    )


def _valid_count_map(value: Any, keys: tuple[str, ...]) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == set(keys)
        and all(isinstance(value[key], int) and not isinstance(value[key], bool) and value[key] >= 0 for key in keys)
    )


def _current_skill_command(skill: str) -> str:
    prefix = "/" if os.environ.get("CLAUDE_PROJECT_DIR") else "$"
    return f"{prefix}grill-adapter:{skill}"


def _validate_projection(path: Path) -> tuple[dict[str, Any], int] | None:
    directory = path.parent
    state = _read_json(path)
    roster = _read_json(directory / "ticket-roster.json")
    context = _read_json(directory / "wiki-context.json")
    readiness = _read_json(directory / "wiki-readiness.json")
    if not isinstance(state, dict):
        return None
    try:
        feature_slug = _feature_slug_from(directory, roster, context, readiness)
    except SessionStateError:
        return None
    state = _usable_previous_state(state, feature_slug=feature_slug, roster=roster)
    if not state:
        return None

    candidate_count = state.get("candidateCount")
    if isinstance(candidate_count, bool) or not isinstance(candidate_count, int) or candidate_count < 0:
        return None
    for field in ("rosterDigest", "contextDigest", "snapshotDigest", "readinessDigest"):
        digest = state.get(field)
        if digest is not None and not _is_digest(digest):
            return None

    task_id = state.get("lastSelectedTask")
    task_id = task_id.strip() if isinstance(task_id, str) and task_id.strip() else None
    if state["schemaVersion"] == LEGACY_SCHEMA_VERSION:
        legacy_digests = {
            "rosterDigest": _digest_file(directory / "ticket-roster.json"),
            "contextDigest": _digest_file(directory / "wiki-context.json"),
            "snapshotDigest": _snapshot_digest(directory, task_id),
        }
        if any(
            state.get(field) is not None and state.get(field) != digest
            for field, digest in legacy_digests.items()
        ):
            return None
        command = state["nextCommand"].strip()
        if "`" in command or any(ord(char) < 32 or ord(char) == 127 for char in command):
            return None
        return state, path.stat().st_mtime_ns

    expected_digests = {
        "rosterDigest": _digest_file(directory / "ticket-roster.json"),
        "contextDigest": _digest_file(directory / "wiki-context.json"),
        "snapshotDigest": _snapshot_digest(directory, task_id),
        "readinessDigest": _digest_file(directory / "wiki-readiness.json"),
    }
    if any(state.get(field) != digest for field, digest in expected_digests.items()):
        return None
    try:
        expected_count, lifecycle, journal_digest = _candidate_lifecycle(
            directory / "wiki-candidates.jsonl", feature_slug
        )
        maintenance, report_digest = _maintenance_counts(
            directory / "wiki-maintenance-audit.json"
        )
    except SessionStateError:
        return None
    lifecycle_keys = (*CANDIDATE_STATUSES, "capturePending", "correctionPending")
    if (
        candidate_count != expected_count
        or not _valid_count_map(state.get("candidateLifecycleCounts"), lifecycle_keys)
        or state["candidateLifecycleCounts"] != lifecycle
        or state.get("journalDigest") != journal_digest
        or not _valid_count_map(state.get("maintenanceCounts"), MAINTENANCE_CATEGORIES)
        or state["maintenanceCounts"] != maintenance
        or state.get("maintenanceReportDigest") != report_digest
    ):
        return None
    return state, path.stat().st_mtime_ns


def build_actions(project_root: Path) -> list[NavigationAction]:
    """Return at most three deterministic, metadata-only navigation actions."""

    context_root = project_root.expanduser().resolve() / ".grill-adapter" / "context"
    if not context_root.is_dir():
        return []
    action_candidates: list[NavigationAction] = []
    state_paths = sorted(context_root.glob(f"*/{SESSION_FILENAME}"))[:MAX_FEATURE_STATES]
    for state_path in state_paths:
        validated = _validate_projection(state_path)
        if validated is None:
            continue
        state, modified_ns = validated
        feature = state["featureSlug"]
        task = state.get("lastSelectedTask")
        readiness = state["readinessStatus"]

        if isinstance(task, str) and task.strip():
            task = task.strip()
            action_type = "recovery" if readiness in {"broken", "unknown", "unrecorded"} else "continuation"
            command = (
                state["nextCommand"].strip()
                if state["schemaVersion"] == LEGACY_SCHEMA_VERSION
                else f"{_current_skill_command('wiki-readiness')} {shlex.quote(task)}"
            )
            action_candidates.append(NavigationAction(
                priority=RECOVERY_PRIORITIES.get(readiness, CONTINUATION_PRIORITY),
                modified_ns=modified_ns,
                action_type=action_type,
                feature_slug=feature,
                status=readiness,
                command=command,
            ))

        if state["schemaVersion"] != SCHEMA_VERSION:
            continue
        lifecycle = state["candidateLifecycleCounts"]
        maintenance = state["maintenanceCounts"]
        maintenance_parts = []
        for key, label in (
            ("reviewDue", "review-due"),
            ("expired", "expired"),
            ("contradictory", "contradictory"),
        ):
            if maintenance[key]:
                maintenance_parts.append(f"{label}={maintenance[key]}")
        if lifecycle["correctionPending"]:
            maintenance_parts.append(f"correction-pending={lifecycle['correctionPending']}")
        if maintenance_parts:
            urgent = maintenance["expired"] + maintenance["contradictory"] + lifecycle["correctionPending"]
            action_candidates.append(NavigationAction(
                priority=(
                    MAINTENANCE_URGENT_PRIORITY if urgent else MAINTENANCE_REVIEW_PRIORITY
                ),
                modified_ns=modified_ns,
                action_type="maintenance",
                feature_slug=feature,
                status=", ".join(maintenance_parts),
                command=(
                    f"{_current_skill_command('wiki-maintenance')} audit {shlex.quote(feature)}"
                ),
            ))

        if lifecycle["capturePending"]:
            action_candidates.append(NavigationAction(
                priority=(
                    CAPTURE_DEFERRED_PRIORITY
                    if lifecycle["deferred"]
                    else CAPTURE_PENDING_PRIORITY
                ),
                modified_ns=modified_ns,
                action_type="capture",
                feature_slug=feature,
                status=f"pending={lifecycle['pending']}, deferred={lifecycle['deferred']}",
                command=f"{_current_skill_command('update-wiki')} {shlex.quote(feature)}",
            ))

    action_candidates.sort(key=lambda action: action.sort_key)
    return action_candidates[:MAX_ACTIONS]


def render_actions(actions: list[NavigationAction]) -> str:
    if not actions:
        return ""
    lines = ["Project memory actions (non-authoritative navigation; readiness remains the task authority):"]
    for index, action in enumerate(actions, start=1):
        lines.append(
            f"{index}. [{action.action_type}] feature `{action.feature_slug}`; "
            f"status `{action.status}`; run `{action.command}`."
        )
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    update = subparsers.add_parser(
        "update",
        aliases=["refresh", "select"],
        help="Refresh the non-authoritative feature continuation summary",
    )
    update.add_argument("--feature-dir", required=True)
    update.add_argument("--task-id")
    update.add_argument("--next-command")
    update.add_argument("--readiness-status", choices=sorted(READINESS_STATUSES))
    actions = subparsers.add_parser(
        "actions",
        help="Render at most three validated SessionStart navigation actions",
    )
    actions.add_argument("--project-root", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "actions":
        rendered = render_actions(build_actions(Path(args.project_root)))
        if rendered:
            print(rendered)
        return 0
    if args.command not in {"update", "refresh", "select"}:
        raise SessionStateError(f"unknown command {args.command}")
    path = update_session_state(
        Path(args.feature_dir),
        task_id=args.task_id,
        next_command=args.next_command,
        readiness_status=args.readiness_status,
    )
    print(path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SessionStateError as exc:
        print(f"session state error: {exc}", file=os.sys.stderr)
        raise SystemExit(2)
