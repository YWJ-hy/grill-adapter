#!/usr/bin/env python3
"""Append, validate, and fold feature-scoped Wiki candidate journals."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator


SCHEMA_VERSION = 1
EVENT_TYPES = {"candidate", "supersede", "outcome"}
STAGES = {
    "grill-with-docs",
    "specification",
    "tickets",
    "implementation",
    "review",
    "debugging",
    "capture",
}
CANDIDATE_TYPES = {"wiki_note", "skill_card"}
CANDIDATE_KINDS = {
    "decision",
    "gotcha",
    "contract",
    "convention",
    "domain",
    "guide",
    "skill_registration",
}
OUTCOME_STATUSES = {"kept", "skipped", "deferred"}
FINAL_STATUSES = {"kept", "skipped", "superseded"}
VOLATILE_EVENT_FIELDS = {"eventId", "recordedAt"}
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SLUG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class JournalError(ValueError):
    """Raised when a journal cannot be trusted or an event is illegal."""


def _require_keys(event: dict[str, Any], required: set[str], optional: set[str]) -> None:
    missing = required - event.keys()
    unexpected = event.keys() - required - optional
    if missing:
        raise JournalError(f"missing field(s): {', '.join(sorted(missing))}")
    if unexpected:
        raise JournalError(f"unexpected field(s): {', '.join(sorted(unexpected))}")


def _require_text(value: Any, field: str, *, limit: int = 4000) -> str:
    if not isinstance(value, str) or not value.strip():
        raise JournalError(f"{field} must be a non-empty string")
    if value != value.strip():
        raise JournalError(f"{field} must not have leading or trailing whitespace")
    if len(value) > limit:
        raise JournalError(f"{field} exceeds {limit} characters")
    return value


def _require_id(value: Any, field: str) -> str:
    text = _require_text(value, field, limit=128)
    if not ID_PATTERN.fullmatch(text):
        raise JournalError(f"{field} contains unsupported characters")
    return text


def _require_feature_slug(value: Any) -> str:
    text = _require_text(value, "featureSlug", limit=128)
    if not SLUG_PATTERN.fullmatch(text):
        raise JournalError("featureSlug contains unsupported characters")
    return text


def _validate_timestamp(value: Any) -> None:
    text = _require_text(value, "recordedAt", limit=64)
    if not text.endswith("Z"):
        raise JournalError("recordedAt must be a UTC timestamp ending in Z")
    try:
        datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as exc:
        raise JournalError("recordedAt is not a valid ISO-8601 timestamp") from exc


def validate_event_shape(event: Any) -> dict[str, Any]:
    if not isinstance(event, dict):
        raise JournalError("event must be a JSON object")
    common = {"schemaVersion", "eventType", "eventId", "featureSlug", "recordedAt"}
    event_type = event.get("eventType")
    if event_type not in EVENT_TYPES:
        raise JournalError(f"eventType must be one of {', '.join(sorted(EVENT_TYPES))}")

    if event_type == "candidate":
        required = common | {
            "candidateId", "stage", "candidateType", "kind", "claim", "why", "sourceRefs",
        }
        optional = {"taskId", "carveOut", "origin"}
    elif event_type == "supersede":
        required = common | {"candidateId", "byCandidateId", "reason"}
        optional = set()
    else:
        required = common | {"candidateId", "status", "reason"}
        optional = set()
    _require_keys(event, required, optional)

    if event["schemaVersion"] != SCHEMA_VERSION:
        raise JournalError(f"schemaVersion must be {SCHEMA_VERSION}")
    _require_id(event["eventId"], "eventId")
    _require_feature_slug(event["featureSlug"])
    _validate_timestamp(event["recordedAt"])
    _require_id(event["candidateId"], "candidateId")

    if event_type == "candidate":
        if event["stage"] not in STAGES:
            raise JournalError(f"stage must be one of {', '.join(sorted(STAGES))}")
        if event["candidateType"] not in CANDIDATE_TYPES:
            raise JournalError("candidateType must be wiki_note or skill_card")
        if event["kind"] not in CANDIDATE_KINDS:
            raise JournalError(f"kind must be one of {', '.join(sorted(CANDIDATE_KINDS))}")
        if (event["candidateType"] == "skill_card") != (event["kind"] == "skill_registration"):
            raise JournalError("skill_card requires kind=skill_registration, and that kind is card-only")
        _require_text(event["claim"], "claim")
        _require_text(event["why"], "why")
        refs = event["sourceRefs"]
        if not isinstance(refs, list) or not refs:
            raise JournalError("sourceRefs must be a non-empty array")
        if len(refs) != len(set(refs)):
            raise JournalError("sourceRefs must not contain duplicates")
        for ref in refs:
            _require_text(ref, "sourceRefs[]", limit=1000)
        if "taskId" in event and event["taskId"] is not None:
            _require_text(event["taskId"], "taskId", limit=128)
        if "carveOut" in event and not isinstance(event["carveOut"], bool):
            raise JournalError("carveOut must be a boolean")
        if "origin" in event:
            _require_text(event["origin"], "origin", limit=128)
    elif event_type == "supersede":
        _require_id(event["byCandidateId"], "byCandidateId")
        if event["byCandidateId"] == event["candidateId"]:
            raise JournalError("a candidate cannot supersede itself")
        _require_text(event["reason"], "reason")
    else:
        if event["status"] not in OUTCOME_STATUSES:
            raise JournalError("status must be kept, skipped, or deferred")
        _require_text(event["reason"], "reason")
    return event


def _new_state(feature_slug: str | None) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "featureSlug": feature_slug,
        "eventCount": 0,
        "counts": {status: 0 for status in ("pending", "superseded", "kept", "skipped", "deferred")},
        "candidates": [],
    }


def _same_candidate_event(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return (
        left.get("eventType") == right.get("eventType") == "candidate"
        and {key: value for key, value in left.items() if key not in VOLATILE_EVENT_FIELDS}
        == {key: value for key, value in right.items() if key not in VOLATILE_EVENT_FIELDS}
    )


def fold_events(events: list[dict[str, Any]], expected_feature_slug: str | None = None) -> dict[str, Any]:
    feature_slug = _require_feature_slug(expected_feature_slug) if expected_feature_slug else None
    event_ids: set[str] = set()
    candidates: dict[str, dict[str, Any]] = {}
    order: list[str] = []

    for index, raw_event in enumerate(events, start=1):
        try:
            event = validate_event_shape(raw_event)
            if feature_slug is None:
                feature_slug = event["featureSlug"]
            elif event["featureSlug"] != feature_slug:
                raise JournalError(
                    f"featureSlug {event['featureSlug']!r} does not match journal feature {feature_slug!r}"
                )
            if event["eventId"] in event_ids:
                raise JournalError(f"duplicate eventId {event['eventId']!r}")
            event_ids.add(event["eventId"])

            candidate_id = event["candidateId"]
            if event["eventType"] == "candidate":
                if candidate_id in candidates:
                    raise JournalError(f"duplicate candidateId {candidate_id!r}")
                item = dict(event)
                item.pop("schemaVersion")
                item.pop("eventType")
                item["candidateEventId"] = item.pop("eventId")
                item["status"] = "pending"
                item["lastEventId"] = item["candidateEventId"]
                candidates[candidate_id] = item
                order.append(candidate_id)
                continue

            if candidate_id not in candidates:
                raise JournalError(f"unknown candidateId {candidate_id!r}")
            item = candidates[candidate_id]
            if item["status"] in FINAL_STATUSES:
                raise JournalError(
                    f"candidate {candidate_id!r} is already terminal ({item['status']})"
                )

            if event["eventType"] == "supersede":
                replacement_id = event["byCandidateId"]
                replacement = candidates.get(replacement_id)
                if replacement is None:
                    raise JournalError(f"unknown replacement candidateId {replacement_id!r}")
                if replacement["status"] in FINAL_STATUSES:
                    raise JournalError(
                        f"replacement candidate {replacement_id!r} is terminal ({replacement['status']})"
                    )
                item["status"] = "superseded"
                item["supersededBy"] = replacement_id
                item["supersedeReason"] = event["reason"]
            else:
                if item["status"] == "deferred" and event["status"] == "deferred":
                    raise JournalError(f"candidate {candidate_id!r} is already deferred")
                item["status"] = event["status"]
                item["outcomeReason"] = event["reason"]
            item["lastEventId"] = event["eventId"]
        except JournalError as exc:
            raise JournalError(f"event {index}: {exc}") from exc

    state = _new_state(feature_slug)
    state["eventCount"] = len(events)
    state["candidates"] = [candidates[candidate_id] for candidate_id in order]
    for item in state["candidates"]:
        state["counts"][item["status"]] += 1
    return state


def read_events(path: Path, *, require_nonempty: bool = False) -> list[dict[str, Any]]:
    if not path.exists():
        if require_nonempty:
            raise JournalError(f"journal does not exist: {path}")
        return []
    if not path.is_file():
        raise JournalError(f"journal is not a file: {path}")
    raw = path.read_bytes()
    if not raw:
        if require_nonempty:
            raise JournalError("journal is empty")
        return []
    if not raw.endswith(b"\n"):
        raise JournalError("journal ends with a truncated JSONL record (missing newline)")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise JournalError(f"journal is not valid UTF-8: {exc}") from exc
    events: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            raise JournalError(f"line {line_number}: blank JSONL records are not allowed")
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise JournalError(f"line {line_number}: invalid JSON: {exc.msg}") from exc
    return events


@contextmanager
def _journal_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a+b") as lock_file:
        if os.name == "nt":
            import msvcrt

            if lock_file.tell() == 0:
                lock_file.write(b"0")
                lock_file.flush()
            lock_file.seek(0)
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_LOCK, 1)
            try:
                yield
            finally:
                lock_file.seek(0)
                msvcrt.locking(lock_file.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def append_events(
    path: Path,
    new_events: list[dict[str, Any]],
    expected_feature_slug: str | None = None,
    *,
    allow_identical_candidates: bool = False,
) -> tuple[int, int]:
    if not new_events:
        return 0, 0
    for event in new_events:
        validate_event_shape(event)
    with _journal_lock(path):
        events = read_events(path)
        events_to_append = new_events
        skipped = 0
        if allow_identical_candidates:
            existing_candidates = {
                event["candidateId"]: event
                for event in events
                if event.get("eventType") == "candidate"
            }
            events_to_append = []
            for event in new_events:
                if event["eventType"] != "candidate":
                    raise JournalError("idempotent append accepts candidate events only")
                existing = existing_candidates.get(event["candidateId"])
                if existing is None:
                    existing_candidates[event["candidateId"]] = event
                    events_to_append.append(event)
                elif _same_candidate_event(existing, event):
                    skipped += 1
                else:
                    raise JournalError(
                        f"candidateId {event['candidateId']!r} already has different content"
                    )
        fold_events([*events, *events_to_append], expected_feature_slug)
        if not events_to_append:
            return 0, skipped
        encoded = "".join(
            json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
            for event in events_to_append
        ).encode("utf-8")
        with path.open("ab") as journal:
            journal.write(encoded)
            journal.flush()
            os.fsync(journal.fileno())
        return len(events_to_append), skipped


def new_event(event_type: str, feature_slug: str, event_id: str | None = None, **fields: Any) -> dict[str, Any]:
    event = {
        "schemaVersion": SCHEMA_VERSION,
        "eventType": event_type,
        "eventId": event_id or str(uuid.uuid4()),
        "featureSlug": feature_slug,
        "recordedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        **fields,
    }
    validate_event_shape(event)
    return event


def _path(value: str) -> Path:
    return Path(value).expanduser().resolve()


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (OSError, ValueError):
            pass


def _add_common_event_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--journal", required=True)
    parser.add_argument("--feature-slug", required=True)
    parser.add_argument("--event-id")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    append_parser = subparsers.add_parser("append", help="Append a new candidate event")
    _add_common_event_args(append_parser)
    append_parser.add_argument("--candidate-id")
    append_parser.add_argument("--stage", required=True, choices=sorted(STAGES))
    append_parser.add_argument("--candidate-type", required=True, choices=sorted(CANDIDATE_TYPES))
    append_parser.add_argument("--kind", required=True, choices=sorted(CANDIDATE_KINDS))
    append_parser.add_argument("--claim", required=True)
    append_parser.add_argument("--why", required=True)
    append_parser.add_argument("--source-ref", action="append", required=True)
    append_parser.add_argument("--task-id")
    append_parser.add_argument("--carve-out", action="store_true")
    append_parser.add_argument("--origin")

    supersede_parser = subparsers.add_parser("supersede", help="Supersede a candidate")
    _add_common_event_args(supersede_parser)
    supersede_parser.add_argument("--candidate-id", required=True)
    supersede_parser.add_argument("--by-candidate-id", required=True)
    supersede_parser.add_argument("--reason", required=True)

    outcome_parser = subparsers.add_parser("outcome", help="Record a Capture outcome")
    _add_common_event_args(outcome_parser)
    outcome_parser.add_argument("--candidate-id", required=True)
    outcome_parser.add_argument("--status", required=True, choices=sorted(OUTCOME_STATUSES))
    outcome_parser.add_argument("--reason", required=True)

    for command in ("validate", "fold"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--journal", required=True)
        command_parser.add_argument("--feature-slug")
    return parser


def main() -> int:
    _configure_stdio()
    args = build_parser().parse_args()
    journal_path = _path(args.journal)
    if args.command in {"validate", "fold"}:
        state = fold_events(read_events(journal_path, require_nonempty=True), args.feature_slug)
        if args.command == "validate":
            print(json.dumps({
                "valid": True,
                "featureSlug": state["featureSlug"],
                "eventCount": state["eventCount"],
                "counts": state["counts"],
            }, ensure_ascii=False, separators=(",", ":")))
        else:
            print(json.dumps(state, ensure_ascii=False, separators=(",", ":")))
        return 0

    if args.command == "append":
        event = new_event(
            "candidate",
            args.feature_slug,
            args.event_id,
            candidateId=args.candidate_id or str(uuid.uuid4()),
            stage=args.stage,
            candidateType=args.candidate_type,
            kind=args.kind,
            claim=args.claim,
            why=args.why,
            sourceRefs=args.source_ref,
            taskId=args.task_id,
            carveOut=args.carve_out,
            **({"origin": args.origin} if args.origin else {}),
        )
    elif args.command == "supersede":
        event = new_event(
            "supersede",
            args.feature_slug,
            args.event_id,
            candidateId=args.candidate_id,
            byCandidateId=args.by_candidate_id,
            reason=args.reason,
        )
    else:
        event = new_event(
            "outcome",
            args.feature_slug,
            args.event_id,
            candidateId=args.candidate_id,
            status=args.status,
            reason=args.reason,
        )

    append_events(journal_path, [event], args.feature_slug)
    print(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except JournalError as exc:
        print(f"candidate journal error: {exc}", file=sys.stderr)
        raise SystemExit(2)
