#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

python3 - "$ROOT" "$SANDBOX" <<'PY'
import copy
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
sandbox = pathlib.Path(sys.argv[2])
agent = (root / "agents" / "wiki-maintenance.md").read_text(encoding="utf-8")
skill = (root / "skills" / "wiki-maintenance" / "SKILL.md").read_text(encoding="utf-8")
contract = (root / "contracts" / "wiki-maintenance-report-v1.example.jsonc").read_text(
    encoding="utf-8"
)
validator = root / "scripts" / "wiki_maintenance_report.py"

for required in (
    "name: wiki-maintenance",
    "mode: audit",
    "obsidian_wiki_maintenance_summary",
    "obsidian_wiki_read_notes_by_wiki_ids",
    "at most 24",
    "current project's readable bindings",
    "Do not call `obsidian_wiki_propose_note_change`",
    "Do not call `obsidian_wiki_apply_note_change`",
    "Do not run Git",
    "Do not modify a candidate journal",
    "Return exactly one JSON object",
    "Never emit Note body",
    "grill-adapter.wiki-maintenance-report",
    "snapshotIdentity",
    "auditedNoteSnapshots.wikiIds",
    "affectedWikiIdentities",
    "recommendedAction",
):
    assert required in agent, required

for required in (
    "Codex dispatch transaction",
    "Reading the file does not adopt that child role in the coordinator",
    "its next operation is spawn",
    "Spawn exactly one maintenance agent",
    "call its `spawn` operation first",
    "call `spawn_agent`",
    "Do not call any wait operation before spawn returns a path",
    "separate `wait_agent` tool",
    "The wait is the only legal next operation after dispatch",
    "same agent path",
    "wait timeout of at least 10 seconds",
    "Do not perform inline Wiki maintenance",
    "dispatch, transport, capacity, or lifecycle failure",
    "`broken`",
    "wiki_maintenance_report.py",
    "--expected-as-of",
    "--expected-identity-limit",
    "--expected-note-read-limit",
    "wiki-maintenance-audit.json",
    "compact summary",
    "non-authoritative",
):
    assert required in skill, required

for required in (
    '"kind": "grill-adapter.wiki-maintenance-report"',
    '"mode": "audit"',
    '"authoritative": false',
    '"snapshotIdentity"',
    '"summaryIdentities"',
    '"wikiIds"',
    '"affectedWikiIdentities"',
    '"recommendedAction"',
):
    assert required in contract, required

valid = {
    "schemaVersion": 1,
    "kind": "grill-adapter.wiki-maintenance-report",
    "authoritative": False,
    "mode": "audit",
    "status": "partial",
    "asOf": "2026-07-31T12:00:00Z",
    "limits": {"identityLimit": 20, "noteReadLimit": 8},
    "scanned": {
        "sources": 2,
        "activeNotes": 12,
        "reviewDueNotes": 1,
        "expiredNotes": 1,
        "contradictoryNotes": 2,
        "noteBodiesRead": 8,
    },
    "findings": [
        {
            "findingId": "audit-001",
            "category": "overloaded-note",
            "severity": "warning",
            "affectedWikiIdentities": [
                {"sourceId": "project", "wikiId": "project/runtime"}
            ],
            "reason": "independent-contracts-share-one-note",
            "recommendedAction": "split-note",
        },
        {
            "findingId": "audit-002",
            "category": "freshness",
            "severity": "warning",
            "affectedWikiIdentities": [
                {"sourceId": "project", "wikiId": "project/review-due"}
            ],
            "reason": "review-date-reached",
            "recommendedAction": "review-note",
        },
        {
            "findingId": "audit-003",
            "category": "contradiction",
            "severity": "warning",
            "affectedWikiIdentities": [
                {"sourceId": "project", "wikiId": "project/contradiction"},
                {"sourceId": "shared", "wikiId": "shared/runtime"},
            ],
            "reason": "typed-contradiction-present",
            "recommendedAction": "resolve-contradiction",
        },
    ],
    "snapshotIdentity": {
        "summarySchemaVersion": 1,
        "asOf": "2026-07-31T12:00:00Z",
        "bindings": [
            {
                "sourceId": "project",
                "role": "project",
                "bindingDigest": "a" * 64,
            },
            {
                "sourceId": "shared",
                "role": "shared",
                "bindingDigest": "c" * 64,
            },
        ],
        "summaryIdentities": {
            "active": [
                {"sourceId": "project", "wikiId": "project/runtime"},
                {"sourceId": "project", "wikiId": "project/build"},
                {"sourceId": "project", "wikiId": "project/deploy"},
                {"sourceId": "project", "wikiId": "project/operations"},
                {"sourceId": "project", "wikiId": "project/testing"},
                {"sourceId": "project", "wikiId": "project/review-due"},
                {"sourceId": "project", "wikiId": "project/expired"},
                {"sourceId": "project", "wikiId": "project/contradiction"},
                {"sourceId": "shared", "wikiId": "shared/api"},
                {"sourceId": "shared", "wikiId": "shared/review"},
                {"sourceId": "shared", "wikiId": "shared/security"},
                {"sourceId": "shared", "wikiId": "shared/runtime"},
            ],
            "reviewDue": [
                {"sourceId": "project", "wikiId": "project/review-due"}
            ],
            "expired": [
                {"sourceId": "project", "wikiId": "project/expired"}
            ],
            "contradictory": [
                {"sourceId": "project", "wikiId": "project/contradiction"},
                {"sourceId": "shared", "wikiId": "shared/runtime"},
            ],
        },
        "auditedNoteSnapshots": [
            {
                "sourceId": "project",
                "noteCount": 5,
                "wikiIds": [
                    "project/runtime",
                    "project/build",
                    "project/deploy",
                    "project/operations",
                    "project/testing",
                ],
                "snapshotHash": "sha256:" + "b" * 64,
            },
            {
                "sourceId": "shared",
                "noteCount": 3,
                "wikiIds": ["shared/api", "shared/review", "shared/security"],
                "snapshotHash": "sha256:" + "d" * 64,
            },
        ],
    },
    "caveats": ["note-read-limit-reached"],
}
valid_path = sandbox / "valid.json"
valid_path.write_text(json.dumps(valid), encoding="utf-8")

checked = subprocess.run(
    [sys.executable, str(validator), "validate", str(valid_path)],
    check=True,
    text=True,
    capture_output=True,
)
assert json.loads(checked.stdout) == valid

compact = subprocess.run(
    [
        sys.executable,
        str(validator),
        "compact",
        str(valid_path),
        "--report-path",
        ".grill-adapter/context/maintenance/wiki-maintenance-audit.json",
    ],
    check=True,
    text=True,
    capture_output=True,
)
assert json.loads(compact.stdout) == {
    "status": "partial",
    "mode": "audit",
    "reportPath": ".grill-adapter/context/maintenance/wiki-maintenance-audit.json",
    "counts": {"sources": 2, "noteBodiesRead": 8, "findings": 3},
    "findingCounts": {"contradiction": 1, "freshness": 1, "overloaded-note": 1},
    "caveats": ["note-read-limit-reached"],
}

invalid_reports = []

missing_snapshot = dict(valid)
missing_snapshot.pop("snapshotIdentity")
invalid_reports.append(missing_snapshot)

body_leak = dict(valid)
body_leak["findings"] = [dict(valid["findings"][0], noteBody="SECRET BODY")]
invalid_reports.append(body_leak)

reason_leak = dict(valid)
reason_leak["findings"] = [dict(valid["findings"][0], reason="SECRET BODY")]
invalid_reports.append(reason_leak)

too_many_reads = dict(valid)
too_many_reads["scanned"] = dict(valid["scanned"], noteBodiesRead=9)
invalid_reports.append(too_many_reads)

arbitrary_path = dict(valid)
arbitrary_path["vaultPath"] = "/private/vault"
invalid_reports.append(arbitrary_path)

invalid_calendar_time = dict(valid)
invalid_calendar_time["asOf"] = "2026-02-31T12:00:00Z"
invalid_calendar_time["snapshotIdentity"] = dict(
    valid["snapshotIdentity"], asOf="2026-02-31T12:00:00Z"
)
invalid_reports.append(invalid_calendar_time)

unbound_finding = copy.deepcopy(valid)
unbound_finding["findings"][0]["affectedWikiIdentities"] = [
    {"sourceId": "unbound", "wikiId": "unbound/runtime"}
]
invalid_reports.append(unbound_finding)

unread_overloaded_finding = copy.deepcopy(valid)
unread_overloaded_finding["findings"][0]["affectedWikiIdentities"] = [
    {"sourceId": "project", "wikiId": "project/not-read"}
]
invalid_reports.append(unread_overloaded_finding)

ungrounded_freshness_finding = copy.deepcopy(valid)
ungrounded_freshness_finding["findings"] = [
    {
        "findingId": "audit-002",
        "category": "freshness",
        "severity": "warning",
        "affectedWikiIdentities": [
            {"sourceId": "project", "wikiId": "project/not-in-summary"}
        ],
        "reason": "review-date-reached",
        "recommendedAction": "review-note",
    }
]
invalid_reports.append(ungrounded_freshness_finding)

ungrounded_contradiction_finding = copy.deepcopy(valid)
ungrounded_contradiction_finding["findings"] = [
    {
        "findingId": "audit-003",
        "category": "contradiction",
        "severity": "warning",
        "affectedWikiIdentities": [
            {"sourceId": "project", "wikiId": "project/not-in-summary"}
        ],
        "reason": "typed-contradiction-present",
        "recommendedAction": "resolve-contradiction",
    }
]
invalid_reports.append(ungrounded_contradiction_finding)

incomplete_summary_identities = copy.deepcopy(valid)
incomplete_summary_identities["snapshotIdentity"]["summaryIdentities"]["active"].pop()
invalid_reports.append(incomplete_summary_identities)

for index, report in enumerate(invalid_reports):
    path = sandbox / f"invalid-{index}.json"
    path.write_text(json.dumps(report), encoding="utf-8")
    failed = subprocess.run(
        [sys.executable, str(validator), "validate", str(path)],
        text=True,
        capture_output=True,
    )
    assert failed.returncode != 0, report
    assert "SECRET BODY" not in failed.stderr
    assert "/private/vault" not in failed.stderr

write_project = sandbox / "write-project"
write_project.mkdir()
write_output = ".grill-adapter/context/issue-32/wiki-maintenance-audit.json"


def write_command(*overrides):
    values = {
        "as_of": valid["asOf"],
        "identity_limit": str(valid["limits"]["identityLimit"]),
        "note_read_limit": str(valid["limits"]["noteReadLimit"]),
    }
    values.update(dict(overrides))
    return [
        sys.executable,
        str(validator),
        "write",
        "--output",
        write_output,
        "--expected-as-of",
        values["as_of"],
        "--expected-identity-limit",
        values["identity_limit"],
        "--expected-note-read-limit",
        values["note_read_limit"],
    ]


written = subprocess.run(
    write_command(),
    cwd=write_project,
    input=json.dumps(valid),
    check=True,
    text=True,
    capture_output=True,
)
written_summary = json.loads(written.stdout)
expected_written_summary = json.loads(compact.stdout)
expected_written_summary["reportPath"] = write_output
assert written_summary == expected_written_summary

for mismatch in (
    (("as_of", "2026-07-31T12:00:01Z"),),
    (("identity_limit", "21"),),
    (("note_read_limit", "7"),),
):
    failed = subprocess.run(
        write_command(*mismatch),
        cwd=write_project,
        input=json.dumps(valid),
        text=True,
        capture_output=True,
    )
    assert failed.returncode != 0, mismatch

if os.name != "nt":
    project = sandbox / "project"
    outside = sandbox / "outside"
    (project / ".grill-adapter" / "context").mkdir(parents=True)
    outside.mkdir()
    (project / ".grill-adapter" / "context" / "issue-32").symlink_to(
        outside, target_is_directory=True
    )
    escaped = subprocess.run(
        [
            sys.executable,
            str(validator),
            "write",
            "--output",
            ".grill-adapter/context/issue-32/wiki-maintenance-audit.json",
            "--expected-as-of",
            valid["asOf"],
            "--expected-identity-limit",
            str(valid["limits"]["identityLimit"]),
            "--expected-note-read-limit",
            str(valid["limits"]["noteReadLimit"]),
        ],
        cwd=project,
        input=json.dumps(valid),
        text=True,
        capture_output=True,
    )
    assert escaped.returncode != 0
    assert not (outside / "wiki-maintenance-audit.json").exists()
PY

printf 'wiki maintenance agent contract smoke OK\n'
