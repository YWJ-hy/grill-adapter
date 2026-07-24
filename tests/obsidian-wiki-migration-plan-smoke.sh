#!/usr/bin/env bash
set -euo pipefail

# Public contract smoke for the deterministic, read-only legacy Wiki -> Obsidian planner.
# Usage: bash tests/obsidian-wiki-migration-plan-smoke.sh <adapter-root>

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLANNER="$ROOT/scripts/wiki_migration_plan.py"
SKILL="$ROOT/skills/migrate-wiki/SKILL.md"
CONTRACT="$ROOT/contracts/obsidian-migration-plan-v1.example.jsonc"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_windows-compat.bash"
TMP="$(portable_tmpdir)"
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
blocked_terms:
blocked_patterns:
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

<!-- wiki-section:negative-rule summary="Secrets must stay private." -->
## Secret handling

Never expose secrets.
<!-- /wiki-section:negative-rule -->
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

<!-- wiki-section:bad-pack summary="Reject an invalid project skill pack." roles="review" -->
## Bad Pack

适用：migration review

审查相关产物时，**必须使用 skill：`bad-pack`**。
<!-- /wiki-section:bad-pack -->
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
mkdir -p "$PROJECT/.claude/skills/bad-pack"
cat > "$PROJECT/.claude/skills/bad-pack/SKILL.md" <<'MD'
---
name: bad-pack
version: latest
description: This pack is intentionally invalid for migration planning.
---

# Bad Pack

Review the migration.
MD
cat > "$PROJECT/.claude/skills/bad-pack/rules.md" <<'MD'
# Unreferenced rules
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
mkdir -p "$PROJECT_SOURCE/rules"
cat > "$PROJECT_SOURCE/rules/soft-guidance.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project-source/occupied-soft-guidance
type: guide
status: active
summary: This path is already occupied by another stable identity.
constraint_strength: soft
---

# Occupied target path
MD
cat > "$PROJECT_SOURCE/existing/legacy-release-card.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project-source/skills/legacy-release-pack
type: guide
status: archived
summary: Existing release pack card with another stable ID.
constraint_strength: hard
skill_provider: claude-code-project
skill_name: release-pack
skill_version: 1.0.0
skill_contract_hash: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
skill_roles:
  - reviewer
skill_triggers:
  - release
---

# Legacy Release Pack
MD
mkdir -p "$SHARED_SOURCE/rules"
cat > "$SHARED_SOURCE/rules/negative-rule.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: shared-source/rules/negative-rule
type: guide
status: active
summary: A different Source may use the same relative suffix.
constraint_strength: soft
---

# Shared negative rule
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
  sha256_tree "$PROJECT/.adapter"
  sha256_tree "$PROJECT/.shared-adapter"
  sha256_tree "$PROJECT/.claude"
  sha256_tree "$VAULT_REPO"
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
assert {s["sectionId"] for s in inventory["sections"]} >= {"api-contract", "soft-guidance", "negative-rule", "review-pack", "release-pack", "bad-pack", "tenant-routing"}
assert {s["constraintStrength"] for s in inventory["sections"]} >= {"hard", "soft"}
negative = next(s for s in inventory["sections"] if s["sectionId"] == "negative-rule")
assert negative["constraintStrength"] == "soft"
assert negative["strengthConfidence"] == "heuristic"
api_inventory = next(s for s in inventory["sections"] if s["sectionId"] == "api-contract")
assert api_inventory["constraintStrength"] == "hard"
assert api_inventory["strengthConfidence"] == "heuristic"
assert any(i["path"] == "index.md" for i in inventory["indexes"])
assert inventory["graphEdges"][0]["type"] == "depends-on"
assert {card["skillName"] for card in inventory["skillDiscovery"]} == {"review-pack", "release-pack", "bad-pack"}

source_ids = {item["sourceItemId"] for item in inventory["sourceItems"]}
mapped_ids = [item["sourceItemId"] for item in plan["planItems"]]
assert len(mapped_ids) == len(set(mapped_ids))
assert source_ids == set(mapped_ids), "every source item must have exactly one plan decision"

decisions = {item["decision"] for item in plan["planItems"]}
assert decisions >= {"create", "update", "skip", "conflict"}
api = next(item for item in plan["planItems"] if item.get("noteId") == "project-source/rules/api-contract" and item["sourceKind"] == "section")
assert api["decision"] == "update", api
assert api["expectedPath"] == "Projects/example/existing/api-contract.md", api
assert api["expectedBeforeHash"].startswith("sha256:"), api
assert api["targetSource"]["sourceId"] == "project-source"
assert api["proposedPath"] == "Projects/example/rules/api-contract.md"
assert api["edgeTransformation"] == [{"property": "depends_on", "targetNoteId": "project-source/rules/soft-guidance"}]
release = next(item for item in plan["planItems"] if item.get("noteId") == "project-source/skills/release-pack")
assert release["decision"] == "conflict"
assert release["proposedPath"] == "Projects/example/Skills/release-pack.md"
assert release["skillCard"]["provider"] == "claude-code-project"
assert release["skillCard"]["version"] == "1.2.3"
assert release["skillCard"]["contractHash"].startswith("sha256:")
assert release["skillCard"]["roles"] == ["implementer", "reviewer"]
assert release["skillCard"]["triggers"] == ["release", "deployment"]
assert release["skillCard"]["summary"] == "Run the release checklist."
soft_guidance = next(
    item for item in plan["planItems"]
    if item.get("noteId") == "project-source/rules/soft-guidance" and item["sourceKind"] == "section"
)
assert soft_guidance["decision"] == "conflict"
assert "occupied" in soft_guidance["decisionReason"], soft_guidance
negative_plan = next(
    item for item in plan["planItems"]
    if item.get("noteId") == "project-source/rules/negative-rule" and item["sourceKind"] == "section"
)
assert negative_plan["decision"] == "create", negative_plan
bad_pack = next(item for item in plan["planItems"] if item.get("noteId") == "project-source/skills/bad-pack")
assert bad_pack["decision"] == "conflict"
assert "valid version" in bad_pack["decisionReason"]
assert "not referenced" in bad_pack["decisionReason"]

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
    "strength-confirmation",
    "target-path-collision",
}
semantic_source_ids = {
    source_id
    for issue in confirmation["issues"] if issue["code"] == "semantic-split"
    for source_id in issue["sourceItemIds"]
}
assert "legacy:project:page:orphan.md" in semantic_source_ids
strength_source_ids = {
    source_id
    for issue in confirmation["issues"] if issue["code"] == "strength-confirmation"
    for source_id in issue["sourceItemIds"]
}
assert negative["sourceItemId"] in strength_source_ids
assert api_inventory["sourceItemId"] in strength_source_ids
assert any(
    issue["code"] == "duplicate-id" and "provider/name" in issue["detail"]
    for issue in confirmation["issues"]
)
assert plan["summary"]["confirmationIssueCount"] == len(confirmation["issues"])
PY

REMOTE_SHARED="$TMP/legacy-shared-repo"
mkdir -p "$REMOTE_SHARED"
cp "$SHARED_WIKI/index.md" "$REMOTE_SHARED/index.md"
cp "$SHARED_WIKI/portable.md" "$REMOTE_SHARED/portable.md"
cat > "$REMOTE_SHARED/remote-only.md" <<'MD'
# Remote-only legacy Note

Prefer a portable shared contract.
MD
git -C "$REMOTE_SHARED" init -q
git -C "$REMOTE_SHARED" add .
git -C "$REMOTE_SHARED" -c user.name=test -c user.email=test@example.com commit -q -m 'seed legacy shared wiki'
REMOTE_PLAN="$TMP/remote-plan.json"
python3 "$PLANNER" \
  --project-root "$PROJECT" \
  --registry "$TMP/registry.json" \
  --wiki-root shared \
  --shared-source-id shared-source \
  --legacy-shared-wiki-url "$REMOTE_SHARED" > "$REMOTE_PLAN"
python3 - "$REMOTE_PLAN" "$REMOTE_SHARED" <<'PY'
import json
import subprocess
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
source = plan["legacySources"]["shared"]
assert source["kind"] == "git"
assert source["repoUrl"] == sys.argv[2]
assert source["revision"] == subprocess.check_output(
    ["git", "-C", sys.argv[2], "rev-parse", "HEAD"], text=True
).strip()
assert any(
    page["legacyRoot"] == "shared" and page["path"] == "remote-only.md"
    for page in plan["inventory"]["pages"]
)
PY

SETTINGS="$PROJECT/.shared-adapter/settings.json"
SETTINGS_BACKUP="$TMP/settings.backup.json"
cp "$SETTINGS" "$SETTINGS_BACKUP"

mutate_settings() {
  local case_name="$1"
  cp "$SETTINGS_BACKUP" "$SETTINGS"
  python3 - "$SETTINGS" "$case_name" <<'PY'
import json
import sys

path, case_name = sys.argv[1:]
settings = json.load(open(path, encoding="utf-8"))
bindings = settings["wiki"]["obsidian"]["bindings"]
if case_name == "read-denied":
    bindings[0]["access"]["read"] = False
    bindings[0]["root"] = "Projects/missing-denied"
elif case_name == "duplicate-id":
    bindings[1]["sourceId"] = bindings[0]["sourceId"]
elif case_name == "duplicate-root":
    bindings[2]["root"] = bindings[1]["root"]
elif case_name == "overlapping-root":
    bindings[2]["root"] = bindings[1]["root"] + "/nested"
elif case_name == "extra-project":
    bindings[1]["role"] = "project"
elif case_name == "root-escape":
    bindings[0]["root"] = "Projects/../outside"
else:
    raise AssertionError(case_name)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle)
PY
}

expect_binding_failure() {
  local case_name="$1"
  local expected="$2"
  mutate_settings "$case_name"
  if python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --wiki-root project > /dev/null 2> "$TMP/$case_name.err"; then
    printf 'Planner accepted invalid binding case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$TMP/$case_name.err" \
    || { printf 'Binding failure %s did not report %s\n' "$case_name" "$expected" >&2; cat "$TMP/$case_name.err" >&2; exit 1; }
}

expect_binding_failure read-denied "no readable Obsidian binding has role project"
expect_binding_failure duplicate-id "duplicate sourceId"
expect_binding_failure duplicate-root "duplicate root"
expect_binding_failure overlapping-root "overlapping root"
expect_binding_failure extra-project "at most one binding may have role: project"
expect_binding_failure root-escape "binding root must name a directory inside the Vault"
cp "$SETTINGS_BACKUP" "$SETTINGS"

OUTSIDE_NOTE="$TMP/outside-note.md"
cat > "$OUTSIDE_NOTE" <<'MD'
# Outside target Note
MD

# Windows without Developer Mode may not permit symlink creation. The planner's symlink
# rejection is covered on platforms that can create real links; keep the rest of this smoke
# useful on locked-down Windows checkouts.
SYMLINK_PROBE="$TMP/.symlink-probe"
if ! ln -s "$OUTSIDE_NOTE" "$SYMLINK_PROBE" 2>/dev/null || [[ ! -L "$SYMLINK_PROBE" ]]; then
  printf 'obsidian migration plan smoke passed (symlink checks skipped: platform does not permit symlinks)\n'
  exit 0
fi
unlink "$SYMLINK_PROBE"

ln -s "$OUTSIDE_NOTE" "$PROJECT_SOURCE/symlink-note.md"
if python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --wiki-root project > /dev/null 2> "$TMP/note-symlink.err"; then
  printf 'Planner followed a target Note symlink\n' >&2
  exit 1
fi
grep -Fq "symbolic link" "$TMP/note-symlink.err" \
  || { printf 'Target Note symlink failure was not explicit\n' >&2; cat "$TMP/note-symlink.err" >&2; exit 1; }
unlink "$PROJECT_SOURCE/symlink-note.md"

MANIFEST="$PROJECT_SOURCE/_meta/wiki-source.md"
MANIFEST_BACKUP="$TMP/project-source-manifest.md"
mv "$MANIFEST" "$MANIFEST_BACKUP"
ln -s "$MANIFEST_BACKUP" "$MANIFEST"
if python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --wiki-root project > /dev/null 2> "$TMP/manifest-symlink.err"; then
  printf 'Planner followed a Source manifest symlink\n' >&2
  exit 1
fi
grep -Fq "symbolic link" "$TMP/manifest-symlink.err" \
  || { printf 'Source manifest symlink failure was not explicit\n' >&2; cat "$TMP/manifest-symlink.err" >&2; exit 1; }
unlink "$MANIFEST"
mv "$MANIFEST_BACKUP" "$MANIFEST"

ln -s "$OUTSIDE_NOTE" "$PROJECT/.claude/skills/release-pack/outside.md"
if python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --wiki-root project > /dev/null 2> "$TMP/pack-symlink.err"; then
  printf 'Planner followed a project Skill Pack symlink\n' >&2
  exit 1
fi
grep -Fq "symbolic link" "$TMP/pack-symlink.err" \
  || { printf 'Skill Pack symlink failure was not explicit\n' >&2; cat "$TMP/pack-symlink.err" >&2; exit 1; }
unlink "$PROJECT/.claude/skills/release-pack/outside.md"

LEGACY_INDEX="$PROJECT_WIKI/guides/index.md"
LEGACY_INDEX_BACKUP="$TMP/guides-index.md"
INVALID_LEGACY="$TMP/invalid-legacy.md"
printf '\377' > "$INVALID_LEGACY"
mv "$LEGACY_INDEX" "$LEGACY_INDEX_BACKUP"
ln -s "$INVALID_LEGACY" "$LEGACY_INDEX"
if python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --wiki-root project > /dev/null 2> "$TMP/legacy-symlink.err"; then
  printf 'Planner followed a legacy Wiki symlink before validation\n' >&2
  exit 1
fi
grep -Fq "symbolic link" "$TMP/legacy-symlink.err" \
  || { printf 'Legacy Wiki symlink was read before fail-closed validation\n' >&2; cat "$TMP/legacy-symlink.err" >&2; exit 1; }
unlink "$LEGACY_INDEX"
mv "$LEGACY_INDEX_BACKUP" "$LEGACY_INDEX"

printf 'obsidian wiki migration plan smoke complete\n'
