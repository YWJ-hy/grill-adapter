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
project = sandbox / "project"
context = project / ".grill-adapter" / "context"
vault = sandbox / "vault"
registry = sandbox / "registry.json"
obsidian_cli = sandbox / "obsidian"
validator = root / "scripts" / "wiki_maintenance_consolidation_report.py"
bundle = root / "mcp" / "obsidian-wiki" / "dist" / "index.js"
agent = (root / "agents" / "wiki-maintenance-consolidation.md").read_text(encoding="utf-8")
skill = (root / "skills" / "wiki-maintenance" / "SKILL.md").read_text(encoding="utf-8")
contract = (root / "contracts" / "wiki-maintenance-consolidation-report-v1.example.jsonc").read_text(
    encoding="utf-8"
)

for required in (
    "name: wiki-maintenance-consolidation",
    '"mode": "consolidation"',
    "obsidian_wiki_consolidation_candidates",
    "equivalent-durable-claim",
    "contradictory-durable-claims",
    "independent-contract",
    "evidence-insufficient",
    "capture-replacement",
    "request-user-decision",
    "candidate-limit-reached",
    "Never emit candidate claim",
    "Do not group candidates only because",
):
    assert required in agent, required

for required in (
    "wiki-maintenance consolidation <feature-slug>",
    "wiki-maintenance-consolidation.json",
    "wiki_maintenance_consolidation_report.py",
    "--expected-candidate-limit",
    "--project-root",
    "journal drift",
    "same agent path",
    "proposal-only",
    "yield of at least `1000`",
    "write_stdin",
    "Do not use `tty: false`",
):
    assert required in skill, required

for required in (
    '"mode": "consolidation"',
    '"proposalGroups"',
    '"independentCandidateIdentities"',
    '"unresolvedCandidateIdentities"',
    '"candidateSnapshots"',
    '"journalSnapshots"',
):
    assert required in contract, required

source_root = vault / "Projects" / "example"
(source_root / "_meta").mkdir(parents=True)
(source_root / "_meta" / "wiki-source.md").write_text(
    """---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: project
scope: project
update_existing: confirm
create_note: confirm
---

# Project
""",
    encoding="utf-8",
)
(source_root / "Retries.md").write_text(
    """---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project/retries
type: constraint
status: active
agent_visible: true
summary: Retry policy
constraint_strength: hard
---

# Retries

One retry budget is shared across transport layers.
""",
    encoding="utf-8",
)
subprocess.run(["git", "init", "--initial-branch=main", str(vault)], check=True, capture_output=True)
subprocess.run(["git", "-C", str(vault), "config", "user.name", "Test User"], check=True)
subprocess.run(["git", "-C", str(vault), "config", "user.email", "test@example.invalid"], check=True)
subprocess.run(["git", "-C", str(vault), "remote", "add", "origin", "https://github.com/acme/knowledge.git"], check=True)
subprocess.run(["git", "-C", str(vault), "add", "."], check=True)
subprocess.run(["git", "-C", str(vault), "commit", "-m", "fixture"], check=True, capture_output=True)
project_settings = {
    "wiki": {
        "provider": "obsidian",
        "publishing": {"mode": "git-pr"},
        "obsidian": {
            "bindings": [
                {
                    "sourceId": "project",
                    "role": "project",
                    "vaultRef": "knowledge",
                    "repositoryRef": "wiki",
                    "root": "Projects/example",
                    "access": {"read": True, "update": "confirm"},
                }
            ]
        },
    }
}
(project / ".grill-adapter").mkdir(parents=True, exist_ok=True)
(project / ".grill-adapter" / "settings.json").write_text(
    json.dumps(project_settings), encoding="utf-8"
)
registry.write_text(
    json.dumps(
        {
            "vaults": {"knowledge": {"selector": "Knowledge"}},
            "repositories": {
                "wiki": {
                    "worktreeRoot": str(vault),
                    "remote": "origin",
                    "expectedRemote": "github.com/acme/knowledge",
                    "baseBranch": "main",
                    "syncBeforeResearch": False,
                }
            },
        }
    ),
    encoding="utf-8",
)
obsidian_cli.write_text(
    "#!/usr/bin/env sh\n[ \"${1:-}\" = vaults ] && printf 'Knowledge\\n'\n",
    encoding="utf-8",
)
obsidian_cli.chmod(0o755)
os.environ["OBSIDIAN_WIKI_REGISTRY"] = str(registry)
os.environ["OBSIDIAN_WIKI_OBSIDIAN_CLI"] = str(obsidian_cli)


def candidate(feature, event_id, candidate_id, claim, *, kind="decision", correction=None):
    value = {
        "schemaVersion": 1,
        "eventType": "candidate",
        "eventId": event_id,
        "featureSlug": feature,
        "recordedAt": "2026-08-01T00:00:00Z",
        "candidateId": candidate_id,
        "stage": "implementation",
        "candidateType": "wiki_note",
        "kind": kind,
        "claim": claim,
        "why": "Private semantic rationale.",
        "sourceRefs": [f"tests/{candidate_id}"],
    }
    if correction is not None:
        value["correction"] = {
            "affectedWikiIdentity": correction,
            "claim": claim,
            "evidenceRefs": [f"tests/{candidate_id}"],
            "observedImpact": "Private observed impact.",
        }
    return value


events = {
    "feature-a": [
        candidate("feature-a", "event-duplicate-a", "duplicate-a", "Use one shared retry budget."),
        candidate("feature-a", "event-conflict-a", "conflict-a", "Cache failures must fail closed."),
        candidate("feature-a", "event-independent", "independent", "Validate payloads before decode."),
    ],
    "feature-b": [
        candidate(
            "feature-b",
            "event-duplicate-b",
            "duplicate-b",
            "Share one retry budget across layers.",
            kind="correction",
            correction={"sourceId": "project", "wikiId": "project/retries"},
        ),
    ],
    "feature-c": [
        candidate("feature-c", "event-conflict-c", "conflict-c", "Cache failures may use stale data."),
    ],
}

for feature, rows in events.items():
    feature_root = context / feature
    feature_root.mkdir(parents=True, exist_ok=True)
    (feature_root / "wiki-candidates.jsonl").write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows),
        encoding="utf-8",
    )


def snapshots(limit=20):
    completed = subprocess.run(
        ["node", str(bundle), "consolidation-candidates"],
        cwd=project,
        input=json.dumps({"candidateLimit": limit}),
        text=True,
        capture_output=True,
        check=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(project)},
    )
    trusted = json.loads(completed.stdout)
    candidates = [
        {
            "featureSlug": row["featureSlug"],
            "candidateId": row["candidateId"],
            "status": row["status"],
            "kind": row["kind"],
            "candidateDigest": row["candidateDigest"],
            "affectedWikiIdentity": (
                row["correction"]["affectedWikiIdentity"]
                if row["correction"] is not None
                else None
            ),
        }
        for row in trusted["candidates"]
    ]
    return trusted, candidates


trusted, candidate_snapshots = snapshots()
journal_snapshots = trusted["journalSnapshots"]
identity = lambda feature, candidate_id: {
    "featureSlug": feature,
    "candidateId": candidate_id,
}

valid = {
    "schemaVersion": 1,
    "kind": "grill-adapter.wiki-maintenance-report",
    "authoritative": False,
    "mode": "consolidation",
    "status": "ok",
    "asOf": "2026-08-01T12:00:00Z",
    "limits": {"candidateLimit": 20},
    "scanned": trusted["scanned"],
    "proposalGroups": [
        {
            "groupId": "group-001",
            "relationship": "equivalent",
            "candidateIdentities": [
                identity("feature-a", "duplicate-a"),
                identity("feature-b", "duplicate-b"),
            ],
            "affectedWikiIdentities": [
                {"sourceId": "project", "wikiId": "project/retries"}
            ],
            "reason": "equivalent-durable-claim",
            "recommendedAction": "capture-replacement",
        },
        {
            "groupId": "group-002",
            "relationship": "contradictory",
            "candidateIdentities": [
                identity("feature-a", "conflict-a"),
                identity("feature-c", "conflict-c"),
            ],
            "affectedWikiIdentities": [],
            "reason": "contradictory-durable-claims",
            "recommendedAction": "request-user-decision",
        },
    ],
    "independentCandidateIdentities": [identity("feature-a", "independent")],
    "unresolvedCandidateIdentities": [],
    "snapshotIdentity": {
        "bindings": trusted["bindings"],
        "journalSnapshots": journal_snapshots,
        "candidateSnapshots": candidate_snapshots,
    },
    "caveats": [],
}

valid_path = sandbox / "valid.json"
valid_path.write_text(json.dumps(valid), encoding="utf-8")
checked = subprocess.run(
    [sys.executable, str(validator), "validate", str(valid_path), "--project-root", str(project)],
    check=True,
    text=True,
    capture_output=True,
)
assert json.loads(checked.stdout) == valid

overlapping_relationships = copy.deepcopy(valid)
overlapping_relationships["proposalGroups"][1]["candidateIdentities"] = [
    identity("feature-a", "duplicate-a"),
    identity("feature-b", "duplicate-b"),
    identity("feature-c", "conflict-c"),
]
overlapping_relationships["proposalGroups"][1]["affectedWikiIdentities"] = [
    {"sourceId": "project", "wikiId": "project/retries"}
]
overlapping_relationships["independentCandidateIdentities"].append(
    identity("feature-a", "conflict-a")
)
overlapping_path = sandbox / "overlapping.json"
overlapping_path.write_text(json.dumps(overlapping_relationships), encoding="utf-8")
subprocess.run(
    [sys.executable, str(validator), "validate", str(overlapping_path), "--project-root", str(project)],
    check=True,
    text=True,
    capture_output=True,
)

compact = subprocess.run(
    [
        sys.executable,
        str(validator),
        "compact",
        str(valid_path),
        "--report-path",
        ".grill-adapter/context/maintenance/wiki-maintenance-consolidation.json",
        "--project-root",
        str(project),
    ],
    check=True,
    text=True,
    capture_output=True,
)
assert json.loads(compact.stdout) == {
    "status": "ok",
    "mode": "consolidation",
    "reportPath": ".grill-adapter/context/maintenance/wiki-maintenance-consolidation.json",
    "counts": {
        "sources": 1,
        "featureJournals": 3,
        "candidates": 5,
        "proposalGroups": 2,
        "independentCandidates": 1,
        "unresolvedCandidates": 0,
    },
    "groupCounts": {"contradictory": 1, "equivalent": 1},
    "caveats": [],
}


def rejected(value, name):
    path = sandbox / f"invalid-{name}.json"
    path.write_text(json.dumps(value), encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(validator), "validate", str(path), "--project-root", str(project)],
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0, name


claim_leak = copy.deepcopy(valid)
claim_leak["proposalGroups"][0]["claim"] = "PRIVATE CLAIM"
rejected(claim_leak, "claim-leak")

overlap = copy.deepcopy(valid)
overlap["independentCandidateIdentities"] = [identity("feature-a", "duplicate-a")]
rejected(overlap, "classification-overlap")

single_member = copy.deepcopy(valid)
single_member["proposalGroups"][0]["candidateIdentities"] = [identity("feature-a", "duplicate-a")]
single_member["independentCandidateIdentities"].append(identity("feature-b", "duplicate-b"))
rejected(single_member, "single-member-group")

missing_classification = copy.deepcopy(valid)
missing_classification["independentCandidateIdentities"] = []
rejected(missing_classification, "missing-classification")

unresolved_without_caveat = copy.deepcopy(valid)
unresolved_without_caveat["independentCandidateIdentities"] = []
unresolved_without_caveat["unresolvedCandidateIdentities"] = [identity("feature-a", "independent")]
rejected(unresolved_without_caveat, "unresolved-without-caveat")

partial = copy.deepcopy(valid)
partial["status"] = "partial"
partial["limits"] = {"candidateLimit": 2}
partial["snapshotIdentity"]["candidateSnapshots"] = snapshots(2)[1]
partial["proposalGroups"] = []
partial["independentCandidateIdentities"] = [
    identity(row["featureSlug"], row["candidateId"])
    for row in partial["snapshotIdentity"]["candidateSnapshots"]
]
partial["caveats"] = ["candidate-limit-reached"]
partial_path = sandbox / "partial.json"
partial_path.write_text(json.dumps(partial), encoding="utf-8")
subprocess.run(
    [
        sys.executable,
        str(validator),
        "validate",
        str(partial_path),
        "--project-root",
        str(project),
        "--expected-candidate-limit",
        "2",
    ],
    check=True,
    text=True,
    capture_output=True,
)

output_rel = ".grill-adapter/context/maintenance/wiki-maintenance-consolidation.json"
write = subprocess.run(
    [
        sys.executable,
        str(validator),
        "write",
        "--output",
        output_rel,
        "--expected-as-of",
        valid["asOf"],
        "--expected-candidate-limit",
        "20",
        "--project-root",
        str(project),
    ],
    cwd=project,
    input=json.dumps(valid),
    text=True,
    capture_output=True,
    check=True,
)
assert json.loads(write.stdout)["counts"]["proposalGroups"] == 2
persisted = project / output_rel
before = persisted.read_bytes()

# Binding changes after the child snapshot must fail and preserve the last report.
settings_path = project / ".grill-adapter" / "settings.json"
settings_before = settings_path.read_text(encoding="utf-8")
settings_path.write_text(settings_before.replace('"sourceId": "project"', '"sourceId": "changed"'), encoding="utf-8")
binding_drift = subprocess.run(
    [
        sys.executable,
        str(validator),
        "write",
        "--output",
        output_rel,
        "--expected-as-of",
        valid["asOf"],
        "--expected-candidate-limit",
        "20",
        "--project-root",
        str(project),
    ],
    cwd=project,
    input=json.dumps(valid),
    text=True,
    capture_output=True,
)
assert binding_drift.returncode != 0
assert persisted.read_bytes() == before
settings_path.write_text(settings_before, encoding="utf-8")

# A journal change after the child snapshot must fail validation and preserve the last report.
drifting_journal = context / "feature-c" / "wiki-candidates.jsonl"
journal_before = drifting_journal.read_bytes()
with drifting_journal.open("a", encoding="utf-8") as handle:
    handle.write("\n")
drifted = subprocess.run(
    [
        sys.executable,
        str(validator),
        "write",
        "--output",
        output_rel,
        "--expected-as-of",
        valid["asOf"],
        "--expected-candidate-limit",
        "20",
        "--project-root",
        str(project),
    ],
    cwd=project,
    input=json.dumps(valid),
    text=True,
    capture_output=True,
)
assert drifted.returncode != 0
assert persisted.read_bytes() == before

# Restoring the exact snapshot resumes the interrupted write without replacing the report first.
drifting_journal.write_bytes(journal_before)
resumed = subprocess.run(
    [
        sys.executable,
        str(validator),
        "write",
        "--output",
        output_rel,
        "--expected-as-of",
        valid["asOf"],
        "--expected-candidate-limit",
        "20",
        "--project-root",
        str(project),
    ],
    cwd=project,
    input=json.dumps(valid),
    text=True,
    capture_output=True,
    check=True,
)
assert json.loads(resumed.stdout)["counts"]["proposalGroups"] == 2
assert persisted.read_bytes() == before

print("wiki maintenance consolidation smoke OK")
PY
