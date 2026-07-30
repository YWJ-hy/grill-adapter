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
import tempfile
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
KIND = "grill-adapter.wiki-session-state"
GENERATED_BY = "grill-adapter"
READINESS_STATUSES = {"ready", "no-relevant", "disabled", "broken", "unknown", "unrecorded"}
SESSION_FILENAME = "wiki-session-state.json"


class SessionStateError(ValueError):
    """Raised when a continuation state cannot be safely written."""


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
        state.get("schemaVersion") != SCHEMA_VERSION
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


def _candidate_count(journal_path: Path) -> int:
    """Return a best-effort count of candidate identities.

    This value is intentionally advisory. A malformed or concurrently written journal leaves the
    authoritative Capture path responsible for reporting the real error; the continuation hint
    simply omits the damaged records from its count.
    """

    try:
        text = journal_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return 0
    candidate_ids: set[str] = set()
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            isinstance(event, dict)
            and event.get("eventType") == "candidate"
            and isinstance(event.get("candidateId"), str)
            and event["candidateId"].strip()
        ):
            candidate_ids.add(event["candidateId"])
    return len(candidate_ids)


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
        return f"{command} {task_id}"
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
    if readiness_status is None and task_id is None:
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

    state = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "generatedBy": GENERATED_BY,
        "featureSlug": feature_slug,
        "lastSelectedTask": task_id,
        "rosterDigest": _digest_file(roster_path),
        "contextDigest": _digest_file(context_path),
        "snapshotDigest": _snapshot_digest(directory, task_id),
        "readinessStatus": readiness_status,
        "candidateCount": _candidate_count(journal_path),
        "nextCommand": next_command,
    }
    _write_json(state_path, state)
    return state_path


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
    return parser


def main() -> int:
    args = build_parser().parse_args()
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
