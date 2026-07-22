#!/usr/bin/env bash
set -euo pipefail

# Public contract smoke for the deterministic, read-only legacy Wiki -> Obsidian planner.
# Usage: bash tests/obsidian-wiki-migration-plan-smoke.sh <adapter-root>

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLANNER="$ROOT/scripts/wiki_migration_plan.py"
SKILL="$ROOT/skills/migrate-wiki/SKILL.md"
CONTRACT="$ROOT/contracts/obsidian-migration-plan-v1.example.jsonc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$SKILL" ]] || { printf 'Missing migrate-wiki skill\n' >&2; exit 1; }
[[ -f "$CONTRACT" ]] || { printf 'Missing migration plan contract\n' >&2; exit 1; }
grep -Fq '${CLAUDE_PLUGIN_ROOT}/scripts/wiki_migration_plan.py' "$SKILL" \
  || { printf 'migrate-wiki skill does not expose the planner\n' >&2; exit 1; }
grep -Fq 'plan-only' "$SKILL" \
  || { printf 'migrate-wiki skill does not declare a plan-only mode\n' >&2; exit 1; }

PROJECT="$TMP/project"
VAULT_REPO="$TMP/vault-repo"
PROJECT_WIKI="$PROJECT/.adapter/wiki"
SHARED_WIKI="$PROJECT/.shared-adapter/wiki"
PROJECT_SOURCE="$VAULT_REPO/Projects/example"
SHARED_SOURCE="$VAULT_REPO/Shared/engineering"
OTHER_SHARED_SOURCE="$VAULT_REPO/Shared/other"
mkdir -p "$PROJECT_WIKI/guides" "$SHARED_WIKI" "$PROJECT_SOURCE/_meta" "$PROJECT_SOURCE/existing" "$SHARED_SOURCE/_meta" "$OTHER_SHARED_SOURCE/_meta" "$PROJECT/.claude/skills"

cat > "$PROJECT/.shared-adapter/settings.json" <<'JSON'
{
  "wiki": {
    "provider": "obsidian",
    "publishing": {"mode": "git-pr"},
    "obsidian": {
      "bindings": [
        {"sourceId": "project-source", "role": "project", "vaultRef": "knowledge", "repositoryRef": "wiki", "root": "Projects/example", "access": {"read": true}},
        {"sourceId": "shared-source", "role": "shared", "vaultRef": "knowledge", "repositoryRef": "wiki", "root": "Shared/engineering", "access": {"read": true}},
        {"sourceId": "other-shared", "role": "shared", "vaultRef": "knowledge", "repositoryRef": "wiki", "root": "Shared/other", "access": {"read": true}}
      ]
    },
    "sharedNeutrality": {
      "blockedTerms": ["ACME_INTERNAL"],
      "blockedPatterns": ["tenant-[0-9]+"]
    }
  }
}
JSON

cat > "$TMP/registry.json" <<JSON
{
  "vaults": {"knowledge": {"selector": "Knowledge"}},
  "repositories": {
    "wiki": {
      "worktreeRoot": "$VAULT_REPO",
      "remote": "origin",
      "expectedRemote": "https://example.com/wiki.git",
      "baseBranch": "main"
    }
  }
}
JSON

cat > "$PROJECT_SOURCE/_meta/wiki-source.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: project-source
scope: project
update_existing: confirm
create_note: confirm
---
MD
cat > "$SHARED_SOURCE/_meta/wiki-source.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: shared-source
scope: shared
update_existing: confirm
create_note: confirm
blocked_terms:
  - ACME_INTERNAL
blocked_patterns:
  - "tenant-[0-9]+"
---
MD
cat > "$OTHER_SHARED_SOURCE/_meta/wiki-source.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: other-shared
scope: shared
update_existing: confirm
create_note: confirm
blocked_terms: []
blocked_patterns: []
---
MD

cat > "$PROJECT_WIKI/index.md" <<'MD'
# Project Wiki

- `rules.md`
- `multi.md`
- `Foo.md`
- `guides/`
MD
cat > "$PROJECT_WIKI/guides/index.md" <<'MD'
# Guides

- `skills.md`
MD
cat > "$PROJECT_WIKI/rules.md" <<'MD'
# Rules

<!-- wiki-section:api-contract summary="API requests must preserve the contract." -->
## API contract

Requests MUST preserve the public contract. [[depends-on: rules#soft-guidance]]
<!-- /wiki-section:api-contract -->

<!-- wiki-section:soft-guidance summary="Prefer small compatibility helpers." -->
## Compatibility guidance

Prefer small compatibility helpers. [[rules#missing-section]]
<!-- /wiki-section:soft-guidance -->
MD
cat > "$PROJECT_WIKI/multi.md" <<'MD'
# Compound page

## First concern

First independent concern.

## Second concern

Second independent concern.
MD
cat > "$PROJECT_WIKI/Foo.md" <<'MD'
# Collision source

One atomic page whose normalized ID collides with target duplicates.
MD
cat > "$PROJECT_WIKI/orphan.md" <<'MD'
# Unindexed page

This page must still appear in inventory and in the plan.
MD
cat > "$PROJECT_WIKI/guides/skills.md" <<'MD'
# Skills

<!-- wiki-section:review-pack summary="Review release receipts." roles="review" -->
## Review Pack

适用：release review

审查相关产物时，**必须使用 skill：`review-pack`**。
<!-- /wiki-section:review-pack -->

<!-- wiki-section:release-pack summary="Run the release checklist." roles="implement,review" -->
## Release Pack

适用：release, deployment

实现或审查相关产物时，**必须使用 skill：`release-pack`**。
<!-- /wiki-section:release-pack -->
MD
mkdir -p "$PROJECT/.claude/skills/release-pack"
cat > "$PROJECT/.claude/skills/release-pack/SKILL.md" <<'MD'
---
name: release-pack
version: 1.2.3
description: Run the release checklist for release and deployment work.
---

# Release Pack

Run the verified checklist.
MD
cat > "$PROJECT_WIKI/.graph.json" <<'JSON'
{
  "schema": "section-graph/3",
  "nodes": ["rules.md#api-contract", "rules.md#soft-guidance"],
  "pageTypes": {"rules.md": "constraint", "guides/skills.md": "guide"},
  "edges": [
    {"from": "rules.md#api-contract", "to": "rules.md#soft-guidance", "type": "depends-on", "raw": "[[depends-on: rules#soft-guidance]]"}
  ],
  "backlinks": {},
  "dangling": [
    {"from": "rules.md#soft-guidance", "raw": "[[rules#missing-section]]", "reason": "target section 'missing-section' not found in rules.md"}
  ]
}
JSON

cat > "$SHARED_WIKI/index.md" <<'MD'
# Shared Wiki

- `portable.md`
MD
cat > "$SHARED_WIKI/portable.md" <<'MD'
# Shared Contract

<!-- wiki-section:tenant-routing summary="Portable tenant routing rules." -->
## Tenant routing

ACME_INTERNAL tenant-42 routing is mandatory.
<!-- /wiki-section:tenant-routing -->
MD
cat > "$SHARED_WIKI/unindexed-shared.md" <<'MD'
# Shared orphan

Prefer neutral terminology.
MD

cat > "$PROJECT_SOURCE/existing/api-contract.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project-source/rules/api-contract
type: constraint
status: active
summary: Existing API contract.
constraint_strength: hard
---

# Existing API Contract
MD
for duplicate in one two; do
  cat > "$PROJECT_SOURCE/existing/foo-$duplicate.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project-source/foo
type: constraint
status: active
summary: Duplicate target identity.
constraint_strength: soft
---

# Duplicate
MD
done

snapshot() {
  find "$PROJECT/.adapter" "$PROJECT/.shared-adapter" "$PROJECT/.claude" "$VAULT_REPO" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256
}

BEFORE="$(snapshot)"
OUT_ONE="$TMP/plan-one.json"
OUT_TWO="$TMP/plan-two.json"
if python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" > /dev/null 2> "$TMP/ambiguous.err"; then
  printf 'Planner accepted ambiguous Shared target without --shared-source-id\n' >&2
  exit 1
fi
grep -Fq -- '--shared-source-id' "$TMP/ambiguous.err" \
  || { printf 'Ambiguous Shared target error did not explain disambiguation\n' >&2; exit 1; }
python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --shared-source-id shared-source > "$OUT_ONE"
python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --shared-source-id shared-source > "$OUT_TWO"
AFTER="$(snapshot)"

cmp -s "$OUT_ONE" "$OUT_TWO" || { printf 'Planner output is not deterministic\n' >&2; exit 1; }
[[ "$BEFORE" == "$AFTER" ]] || { printf 'Planner modified legacy Wiki or target Source files\n' >&2; exit 1; }

python3 - "$OUT_ONE" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["schemaVersion"] == 1
assert plan["kind"] == "grill-adapter.obsidian-migration-plan"
assert plan["mode"] == "plan-only"
assert plan["writePerformed"] is False
assert plan["sourceSnapshot"]["digest"].startswith("sha256:")
assert plan["targetSnapshot"]["digest"].startswith("sha256:")
assert plan["targetSources"] == [
    {"role": "project", "root": "Projects/example", "sourceId": "project-source"},
    {"role": "shared", "root": "Shared/engineering", "sourceId": "shared-source"},
]

inventory = plan["inventory"]
pages = inventory["pages"]
assert any(p["legacyRoot"] == "project" and p["path"] == "rules.md" and p["indexed"] for p in pages)
assert any(p["legacyRoot"] == "project" and p["path"] == "orphan.md" and not p["indexed"] for p in pages)
assert any(p["legacyRoot"] == "shared" and p["path"] == "unindexed-shared.md" and not p["indexed"] for p in pages)
assert {s["sectionId"] for s in inventory["sections"]} >= {"api-contract", "soft-guidance", "review-pack", "release-pack", "tenant-routing"}
assert {s["constraintStrength"] for s in inventory["sections"]} >= {"hard", "soft"}
assert any(i["path"] == "index.md" for i in inventory["indexes"])
assert inventory["graphEdges"][0]["type"] == "depends-on"
assert {card["skillName"] for card in inventory["skillDiscovery"]} == {"review-pack", "release-pack"}

source_ids = {item["sourceItemId"] for item in inventory["sourceItems"]}
mapped_ids = [item["sourceItemId"] for item in plan["planItems"]]
assert len(mapped_ids) == len(set(mapped_ids))
assert source_ids == set(mapped_ids), "every source item must have exactly one plan decision"

decisions = {item["decision"] for item in plan["planItems"]}
assert decisions >= {"create", "update", "skip", "conflict"}
api = next(item for item in plan["planItems"] if item.get("noteId") == "project-source/rules/api-contract" and item["sourceKind"] == "section")
assert api["decision"] == "update", api
assert api["targetSource"]["sourceId"] == "project-source"
assert api["proposedPath"] == "Projects/example/rules/api-contract.md"
assert api["edgeTransformation"] == [{"property": "depends_on", "targetNoteId": "project-source/rules/soft-guidance"}]
release = next(item for item in plan["planItems"] if item.get("noteId") == "project-source/skills/release-pack")
assert release["decision"] == "create"
assert release["proposedPath"] == "Projects/example/Skills/release-pack.md"
assert release["skillCard"]["provider"] == "claude-code-project"
assert release["skillCard"]["version"] == "1.2.3"
assert release["skillCard"]["contractHash"].startswith("sha256:")
assert release["skillCard"]["roles"] == ["implementer", "reviewer"]
assert release["skillCard"]["triggers"] == ["release", "deployment"]
assert release["skillCard"]["summary"] == "Run the release checklist."

confirmation = plan["confirmation"]
assert confirmation["required"] is True
codes = {issue["code"] for issue in confirmation["issues"]}
assert codes >= {
    "semantic-split",
    "duplicate-id",
    "dangling-edge",
    "unavailable-pack",
    "shared-neutrality-violation",
    "non-migratable-navigation",
}
assert plan["summary"]["confirmationIssueCount"] == len(confirmation["issues"])
PY

printf 'obsidian wiki migration plan smoke complete\n'
