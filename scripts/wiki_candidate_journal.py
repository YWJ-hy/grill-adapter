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
from pathlib import Path, PurePosixPath
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
    "adr_execution_projection",
    "decision",
    "gotcha",
    "contract",
    "convention",
    "domain",
    "guide",
    "skill_registration",
}
ADR_PROJECTION_FIELDS = {
    "authorityType",
    "projectionType",
    "sourceId",
    "sourcePath",
    "sourceContentHash",
    "targetScope",
}
OUTCOME_STATUSES = {"kept", "skipped", "deferred"}
FINAL_STATUSES = {"kept", "skipped", "superseded"}
VOLATILE_EVENT_FIELDS = {"eventId", "recordedAt"}
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SLUG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
CONTENT_HASH_PATTERN = re.compile(r"^sha256:[a-f0-9]{64}$")
BINDING_DIGEST_PATTERN = re.compile(r"^[a-f0-9]{64}$")
SKILL_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SKILL_VERSION_PATTERN = re.compile(
    r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
WRITE_RECEIPT_STATES = {"proposed", "applied"}
WRITE_OPERATIONS = {"create", "update"}
WRITE_RECEIPT_FIELDS = {
    "provider", "state", "operation", "sourceId", "repositoryRef", "bindingDigest",
    "wikiId", "path", "beforeHash", "afterHash",
}
WRITE_RECEIPT_OPTIONAL_FIELDS = {"skillRegistration", "adrProjection"}
WRITE_RECEIPT_IDENTITY_FIELDS = (WRITE_RECEIPT_FIELDS - {"state"}) | WRITE_RECEIPT_OPTIONAL_FIELDS
SKILL_REGISTRATION_FIELDS = {
    "provider",
    "name",
    "version",
    "contractHash",
    "roles",
    "triggers",
    "summary",
    "discoveryState",
}
SKILL_PROVIDERS = {"claude-code-project"}
SKILL_ROLES = {"implementer", "reviewer"}


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


def _validate_write_receipt(receipt: Any, outcome_status: str) -> dict[str, Any]:
    if not isinstance(receipt, dict):
        raise JournalError("writeReceipt must be a JSON object")
    _require_keys(receipt, WRITE_RECEIPT_FIELDS, WRITE_RECEIPT_OPTIONAL_FIELDS)
    if receipt["provider"] != "obsidian":
        raise JournalError("writeReceipt.provider must be obsidian")
    if receipt["state"] not in WRITE_RECEIPT_STATES:
        raise JournalError("writeReceipt.state must be proposed or applied")
    if receipt["operation"] not in WRITE_OPERATIONS:
        raise JournalError("writeReceipt.operation must be create or update")
    for field in ("sourceId", "repositoryRef", "wikiId"):
        _require_text(receipt[field], f"writeReceipt.{field}", limit=256)
    digest = _require_text(receipt["bindingDigest"], "writeReceipt.bindingDigest", limit=64)
    if not BINDING_DIGEST_PATTERN.fullmatch(digest):
        raise JournalError("writeReceipt.bindingDigest must be a lowercase sha256 hex digest")
    note_path = _require_text(receipt["path"], "writeReceipt.path", limit=1000)
    parsed_path = PurePosixPath(note_path)
    if (
        "\\" in note_path
        or parsed_path.is_absolute()
        or parsed_path.as_posix() != note_path
        or any(part in {"", ".", ".."} for part in parsed_path.parts)
        or parsed_path.suffix != ".md"
    ):
        raise JournalError("writeReceipt.path must be a normalized relative POSIX .md path")
    before_hash = receipt["beforeHash"]
    if before_hash is not None and (
        not isinstance(before_hash, str) or not CONTENT_HASH_PATTERN.fullmatch(before_hash)
    ):
        raise JournalError("writeReceipt.beforeHash must be null or a canonical sha256 content hash")
    after_hash = receipt["afterHash"]
    if not isinstance(after_hash, str) or not CONTENT_HASH_PATTERN.fullmatch(after_hash):
        raise JournalError("writeReceipt.afterHash must be a canonical sha256 content hash")
    if receipt["operation"] == "create" and before_hash is not None:
        raise JournalError("create writeReceipt.beforeHash must be null")
    if receipt["operation"] == "update" and before_hash is None:
        raise JournalError("update writeReceipt.beforeHash must be a canonical sha256 content hash")
    expected_status = "deferred" if receipt["state"] == "proposed" else "kept"
    if outcome_status != expected_status:
        raise JournalError(
            f"writeReceipt.state={receipt['state']} requires outcome status={expected_status}"
        )
    if "skillRegistration" in receipt:
        _validate_skill_registration(receipt["skillRegistration"])
    if "adrProjection" in receipt:
        _validate_adr_projection(receipt["adrProjection"])
    return receipt


def _validate_skill_registration(registration: Any) -> dict[str, Any]:
    if not isinstance(registration, dict):
        raise JournalError("skillRegistration must be a JSON object")
    _require_keys(registration, SKILL_REGISTRATION_FIELDS, set())
    if registration["provider"] not in SKILL_PROVIDERS:
        raise JournalError(
            f"skillRegistration.provider must be one of {', '.join(sorted(SKILL_PROVIDERS))}"
        )
    name = _require_text(registration["name"], "skillRegistration.name", limit=128)
    if not SKILL_NAME_PATTERN.fullmatch(name):
        raise JournalError("skillRegistration.name must use kebab-case")
    version = _require_text(registration["version"], "skillRegistration.version", limit=64)
    if not SKILL_VERSION_PATTERN.fullmatch(version):
        raise JournalError("skillRegistration.version must be a semantic major.minor.patch version")
    contract_hash = _require_text(
        registration["contractHash"], "skillRegistration.contractHash", limit=71
    )
    if not CONTENT_HASH_PATTERN.fullmatch(contract_hash):
        raise JournalError(
            "skillRegistration.contractHash must be a canonical sha256 content hash"
        )
    roles = registration["roles"]
    if (
        not isinstance(roles, list)
        or not roles
        or len(roles) != len(set(roles))
        or any(role not in SKILL_ROLES for role in roles)
    ):
        raise JournalError(
            "skillRegistration.roles must be a non-empty unique array of implementer/reviewer"
        )
    triggers = registration["triggers"]
    if not isinstance(triggers, list) or not triggers or len(triggers) != len(set(triggers)):
        raise JournalError("skillRegistration.triggers must be a non-empty unique array")
    for trigger in triggers:
        _require_text(trigger, "skillRegistration.triggers[]", limit=256)
    _require_text(registration["summary"], "skillRegistration.summary", limit=400)
    if registration["discoveryState"] != "pending":
        raise JournalError("skillRegistration.discoveryState must be pending in a candidate")
    return registration


def _validate_adr_projection(projection: Any) -> dict[str, Any]:
    if not isinstance(projection, dict):
        raise JournalError("adrProjection must be a JSON object")
    _require_keys(projection, ADR_PROJECTION_FIELDS, set())
    if projection["authorityType"] != "project-adr":
        raise JournalError("adrProjection.authorityType must be project-adr")
    if projection["projectionType"] != "execution-constraints":
        raise JournalError("adrProjection.projectionType must be execution-constraints")
    source_id = _require_text(projection["sourceId"], "adrProjection.sourceId", limit=76)
    if not re.fullmatch(r"project-adr:[a-f0-9]{64}", source_id):
        raise JournalError("adrProjection.sourceId must be project-adr:<lowercase sha256>")
    source_path = _require_text(
        projection["sourcePath"], "adrProjection.sourcePath", limit=1000
    )
    parsed_path = PurePosixPath(source_path)
    path_parts = parsed_path.parts
    has_adr_root = any(
        path_parts[index:index + 2] == ("docs", "adr")
        for index in range(len(path_parts) - 1)
    )
    if (
        "\\" in source_path
        or parsed_path.is_absolute()
        or parsed_path.as_posix() != source_path
        or any(part in {"", ".", ".."} for part in parsed_path.parts)
        or len(parsed_path.parts) < 3
        or not has_adr_root
        or parsed_path.suffix != ".md"
    ):
        raise JournalError(
            "adrProjection.sourcePath must be a normalized project-relative path under docs/adr"
        )
    source_hash = _require_text(
        projection["sourceContentHash"], "adrProjection.sourceContentHash", limit=71
    )
    if not CONTENT_HASH_PATTERN.fullmatch(source_hash):
        raise JournalError(
            "adrProjection.sourceContentHash must be a canonical sha256 content hash"
        )
    if projection["targetScope"] != "project":
        raise JournalError("adrProjection.targetScope must be project")
    return projection


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
        optional = {
            "taskId", "carveOut", "origin", "skillRegistration", "adrProjection",
        }
    elif event_type == "supersede":
        required = common | {"candidateId", "byCandidateId", "reason"}
        optional = set()
    else:
        required = common | {"candidateId", "status", "reason"}
        optional = {"writeReceipt"}
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
        if event["candidateType"] == "skill_card":
            if "skillRegistration" not in event:
                raise JournalError("skill_card candidate requires skillRegistration")
            _validate_skill_registration(event["skillRegistration"])
        elif "skillRegistration" in event:
            raise JournalError("skillRegistration is only valid for skill_card candidates")
        if event["kind"] == "adr_execution_projection":
            if event["candidateType"] != "wiki_note":
                raise JournalError("adr_execution_projection must be a wiki_note candidate")
            if "adrProjection" not in event:
                raise JournalError("adr_execution_projection requires adrProjection")
            _validate_adr_projection(event["adrProjection"])
        elif "adrProjection" in event:
            raise JournalError(
                "adrProjection is only valid for adr_execution_projection candidates"
            )
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
        if "writeReceipt" in event:
            _validate_write_receipt(event["writeReceipt"], event["status"])
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
                previous_receipt = item.get("writeReceipt")
                next_receipt = event.get("writeReceipt")
                expected_skill_registration = item.get("skillRegistration")
                expected_adr_projection = item.get("adrProjection")
                if (
                    expected_skill_registration is not None
                    and event["status"] == "kept"
                    and (
                        not isinstance(next_receipt, dict)
                        or next_receipt.get("state") != "applied"
                    )
                ):
                    raise JournalError(
                        f"candidate {candidate_id!r} is a Skill Card; kept requires an "
                        "applied write receipt bound to its staged registration"
                    )
                if isinstance(next_receipt, dict):
                    receipt_skill_registration = next_receipt.get("skillRegistration")
                    receipt_adr_projection = next_receipt.get("adrProjection")
                    if expected_skill_registration is not None:
                        if receipt_skill_registration != expected_skill_registration:
                            raise JournalError(
                                f"candidate {candidate_id!r} write receipt does not match its "
                                "staged Skill Card registration"
                            )
                    elif receipt_skill_registration is not None:
                        raise JournalError(
                            f"candidate {candidate_id!r} is not a Skill Card but its write "
                            "receipt carries a Skill Card registration"
                        )
                    if expected_adr_projection is not None:
                        if receipt_adr_projection != expected_adr_projection:
                            raise JournalError(
                                f"candidate {candidate_id!r} write receipt does not match its "
                                "ADR projection authority identity"
                            )
                    elif receipt_adr_projection is not None:
                        raise JournalError(
                            f"candidate {candidate_id!r} is not an ADR projection but its write "
                            "receipt carries ADR projection identity"
                        )
                if (
                    expected_adr_projection is not None
                    and event["status"] == "kept"
                    and (
                        not isinstance(next_receipt, dict)
                        or next_receipt.get("state") != "applied"
                        or next_receipt.get("adrProjection") != expected_adr_projection
                    )
                ):
                    raise JournalError(
                        f"candidate {candidate_id!r} is an ADR projection; kept requires an "
                        "applied write receipt bound to its authority identity"
                    )
                if (
                    item["status"] == "deferred"
                    and isinstance(previous_receipt, dict)
                    and previous_receipt.get("state") == "proposed"
                    and event["status"] == "kept"
                ):
                    if not isinstance(next_receipt, dict):
                        raise JournalError(
                            f"candidate {candidate_id!r} has a proposed write receipt; "
                            "kept requires the matching applied receipt"
                        )
                    mismatches = sorted(
                        field
                        for field in WRITE_RECEIPT_IDENTITY_FIELDS
                        if previous_receipt.get(field) != next_receipt.get(field)
                    )
                    if mismatches:
                        raise JournalError(
                            f"candidate {candidate_id!r} applied receipt does not match its "
                            f"latest proposal: {', '.join(mismatches)}"
                        )
                item["status"] = event["status"]
                item["outcomeReason"] = event["reason"]
                if "writeReceipt" in event:
                    item["writeReceipt"] = event["writeReceipt"]
                elif (
                    event["status"] == "deferred"
                    and isinstance(previous_receipt, dict)
                    and previous_receipt.get("state") == "proposed"
                ):
                    item["writeReceipt"] = previous_receipt
                else:
                    item.pop("writeReceipt", None)
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
    append_parser.add_argument("--skill-provider", choices=sorted(SKILL_PROVIDERS))
    append_parser.add_argument("--skill-name")
    append_parser.add_argument("--skill-version")
    append_parser.add_argument("--skill-contract-hash")
    append_parser.add_argument("--skill-role", action="append", choices=sorted(SKILL_ROLES))
    append_parser.add_argument("--skill-trigger", action="append")
    append_parser.add_argument("--skill-summary")

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
    outcome_parser.add_argument("--write-state", choices=sorted(WRITE_RECEIPT_STATES))
    outcome_parser.add_argument("--operation", choices=sorted(WRITE_OPERATIONS))
    outcome_parser.add_argument("--source-id")
    outcome_parser.add_argument("--repository-ref")
    outcome_parser.add_argument("--binding-digest")
    outcome_parser.add_argument("--wiki-id")
    outcome_parser.add_argument("--path")
    outcome_parser.add_argument("--before-hash")
    outcome_parser.add_argument("--after-hash")
    outcome_parser.add_argument("--skill-provider", choices=sorted(SKILL_PROVIDERS))
    outcome_parser.add_argument("--skill-name")
    outcome_parser.add_argument("--skill-version")
    outcome_parser.add_argument("--skill-contract-hash")
    outcome_parser.add_argument("--skill-role", action="append", choices=sorted(SKILL_ROLES))
    outcome_parser.add_argument("--skill-trigger", action="append")
    outcome_parser.add_argument("--skill-summary")
    outcome_parser.add_argument("--adr-authority-type")
    outcome_parser.add_argument("--adr-projection-type")
    outcome_parser.add_argument("--adr-source-id")
    outcome_parser.add_argument("--adr-source-path")
    outcome_parser.add_argument("--adr-source-content-hash")
    outcome_parser.add_argument("--adr-target-scope")

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
        skill_values = (
            args.skill_provider,
            args.skill_name,
            args.skill_version,
            args.skill_contract_hash,
            args.skill_role,
            args.skill_trigger,
            args.skill_summary,
        )
        skill_registration = None
        if any(value is not None for value in skill_values):
            skill_registration = {
                "provider": args.skill_provider,
                "name": args.skill_name,
                "version": args.skill_version,
                "contractHash": args.skill_contract_hash,
                "roles": args.skill_role,
                "triggers": args.skill_trigger,
                "summary": args.skill_summary,
                "discoveryState": "pending",
            }
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
            **(
                {"skillRegistration": skill_registration}
                if skill_registration is not None
                else {}
            ),
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
        skill_values = (
            args.skill_provider,
            args.skill_name,
            args.skill_version,
            args.skill_contract_hash,
            args.skill_role,
            args.skill_trigger,
            args.skill_summary,
        )
        receipt_skill_registration = None
        if any(value is not None for value in skill_values):
            receipt_skill_registration = {
                "provider": args.skill_provider,
                "name": args.skill_name,
                "version": args.skill_version,
                "contractHash": args.skill_contract_hash,
                "roles": args.skill_role,
                "triggers": args.skill_trigger,
                "summary": args.skill_summary,
                "discoveryState": "pending",
            }
        adr_values = (
            args.adr_authority_type,
            args.adr_projection_type,
            args.adr_source_id,
            args.adr_source_path,
            args.adr_source_content_hash,
            args.adr_target_scope,
        )
        receipt_adr_projection = None
        if any(value is not None for value in adr_values):
            receipt_adr_projection = {
                "authorityType": args.adr_authority_type,
                "projectionType": args.adr_projection_type,
                "sourceId": args.adr_source_id,
                "sourcePath": args.adr_source_path,
                "sourceContentHash": args.adr_source_content_hash,
                "targetScope": args.adr_target_scope,
            }
        receipt_args = (
            args.write_state,
            args.operation,
            args.source_id,
            args.repository_ref,
            args.binding_digest,
            args.wiki_id,
            args.path,
            args.before_hash,
            args.after_hash,
        )
        write_receipt = None
        if any(value is not None for value in receipt_args):
            write_receipt = {
                "provider": "obsidian",
                "state": args.write_state,
                "operation": args.operation,
                "sourceId": args.source_id,
                "repositoryRef": args.repository_ref,
                "bindingDigest": args.binding_digest,
                "wikiId": args.wiki_id,
                "path": args.path,
                "beforeHash": args.before_hash,
                "afterHash": args.after_hash,
                **(
                    {"skillRegistration": receipt_skill_registration}
                    if receipt_skill_registration is not None
                    else {}
                ),
                **(
                    {"adrProjection": receipt_adr_projection}
                    if receipt_adr_projection is not None
                    else {}
                ),
            }
        event = new_event(
            "outcome",
            args.feature_slug,
            args.event_id,
            candidateId=args.candidate_id,
            status=args.status,
            reason=args.reason,
            **({"writeReceipt": write_receipt} if write_receipt is not None else {}),
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
