#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PLANNER="$ROOT/scripts/wiki_migration_plan.py"
MIGRATOR="$ROOT/scripts/wiki_migration_apply.py"
BUNDLE="$ROOT/mcp/obsidian-wiki/dist/index.js"
SKILL="$ROOT/skills/migrate-wiki/SKILL.md"
MANIFEST_CONTRACT="$ROOT/contracts/obsidian-migration-manifest-v1.example.jsonc"
TMP="$(mktemp -d)"
BRIDGE_PID=""
cleanup() {
  if [[ -n "$BRIDGE_PID" ]]; then kill "$BRIDGE_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

[[ -f "$MANIFEST_CONTRACT" ]] || { printf 'Missing migration manifest contract\n' >&2; exit 1; }
grep -Fq '${CLAUDE_PLUGIN_ROOT}/scripts/wiki_migration_apply.py apply' "$SKILL" \
  || { printf 'migrate-wiki skill does not expose migration apply\n' >&2; exit 1; }
grep -Fq 'separate explicit cutover confirmation' "$SKILL" \
  || { printf 'migrate-wiki skill does not preserve the cutover confirmation boundary\n' >&2; exit 1; }

PROJECT="$TMP/project"
VAULT="$TMP/vault"
REMOTE="$TMP/vault.git"
SOURCE_ROOT="Projects/example"
mkdir -p "$PROJECT/.adapter/wiki/guides" "$PROJECT/.adapter/context" \
  "$PROJECT/.shared-adapter/wiki" "$PROJECT/.claude/skills/release-check" \
  "$VAULT/$SOURCE_ROOT/_meta" "$VAULT/$SOURCE_ROOT/rules"

cat > "$PROJECT/.shared-adapter/wiki/index.md" <<'MD'
# Unselected Shared Wiki

This root is outside the project-only migration plan.
MD

cat > "$PROJECT/.adapter/wiki/index.md" <<'MD'
# Project Wiki

- `rules.md`
- `guides/skills.md`
MD
cat > "$PROJECT/.adapter/wiki/guides/index.md" <<'MD'
# Guides

- `skills.md`
MD
cat > "$PROJECT/.adapter/wiki/rules.md" <<'MD'
# Rules

<!-- wiki-section:base-contract summary="The base contract remains stable." -->
## Base contract

The base contract MUST remain stable.
<!-- /wiki-section:base-contract -->

<!-- wiki-section:api-contract summary="API changes preserve the base contract." -->
## API contract

API changes MUST preserve compatibility. [[depends-on: rules#base-contract]]
<!-- /wiki-section:api-contract -->
MD
cat > "$PROJECT/.adapter/wiki/guides/skills.md" <<'MD'
# Skills

<!-- wiki-section:release-check summary="Run the release verification pack." roles="review" -->
## Release Check

适用：release review

审查相关产物时，必须使用 skill：`release-check`。
<!-- /wiki-section:release-check -->
MD
cat > "$PROJECT/.adapter/wiki/.graph.json" <<'JSON'
{
  "schema": "section-graph/3",
  "nodes": ["rules.md#base-contract", "rules.md#api-contract"],
  "pageTypes": {"rules.md": "constraint", "guides/skills.md": "guide"},
  "edges": [
    {"from": "rules.md#api-contract", "to": "rules.md#base-contract", "type": "depends-on", "raw": "[[depends-on: rules#base-contract]]"}
  ],
  "backlinks": {},
  "dangling": []
}
JSON
cat > "$PROJECT/.claude/skills/release-check/SKILL.md" <<'MD'
---
name: release-check
version: 1.0.0
description: Verify a release before publication.
---

# Release Check

Run the project release checks.
MD
cat > "$VAULT/$SOURCE_ROOT/_meta/wiki-source.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: project-source
scope: project
update_existing: direct
create_note: direct
---

# Project Source
MD
cat > "$VAULT/$SOURCE_ROOT/rules/base-contract.md" <<'MD'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: "project-source/rules/base-contract"
type: constraint
status: active
agent_visible: true
summary: "An older base contract."
constraint_strength: hard
---

## Base contract

The old base contract may change.
MD

git init --bare --initial-branch=main "$REMOTE" >/dev/null
git init --initial-branch=main "$VAULT" >/dev/null
git -C "$VAULT" config user.name "Migration Test"
git -C "$VAULT" config user.email "migration@example.invalid"
git -C "$VAULT" remote add origin "$REMOTE"
git -C "$VAULT" add .
git -C "$VAULT" commit -m base >/dev/null
git -C "$VAULT" push -u origin main >/dev/null

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
cat > "$TMP/obsidian" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const root = process.env.FAKE_OBSIDIAN_VAULT_ROOT;
function notes(current = root) {
  return fs.readdirSync(current, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(current, entry.name);
    if (entry.isDirectory()) return entry.name === '_meta' ? [] : notes(absolute);
    return entry.isFile() && entry.name.endsWith('.md')
      ? [path.relative(root, absolute).split(path.sep).join('/')]
      : [];
  });
}
if (args[0] === 'vaults') process.stdout.write('Knowledge\n');
else if (args.includes('search')) process.stdout.write(JSON.stringify(notes()));
else if (args.includes('read')) {
  const notePath = args.find((arg) => arg.startsWith('path='))?.slice('path='.length);
  if (!notePath) process.exit(2);
  process.stdout.write(fs.readFileSync(path.join(root, notePath), 'utf8'));
} else process.exit(2);
JS
chmod +x "$TMP/obsidian"
cat > "$TMP/gh" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
const statePath = process.env.FAKE_GH_STATE;
const state = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')) : { calls: [], prs: {} };
state.calls.push(args);
if (args[0] !== 'pr') process.exit(2);
if (args[1] === 'list') {
  const head = args[args.indexOf('--head') + 1];
  process.stdout.write(state.prs[head]?.url || '');
} else if (args[1] === 'create') {
  const head = args[args.indexOf('--head') + 1];
  state.createCount = (state.createCount || 0) + 1;
  const url = `https://github.com/example/wiki/pull/${40 + state.createCount}`;
  state.prs[head] = { url, state: 'OPEN', mergedAt: null };
  process.stdout.write(url + '\n');
} else if (args[1] === 'edit') {
  process.stdout.write(args[2] + '\n');
} else if (args[1] === 'view') {
  const url = args[2];
  const pr = Object.values(state.prs).find((entry) => entry.url === url);
  process.stdout.write(JSON.stringify(pr || { state: 'OPEN', mergedAt: null }));
} else process.exit(2);
fs.writeFileSync(statePath, JSON.stringify(state));
JS
chmod +x "$TMP/gh"

REAL_NODE="$(command -v node)"
cat > "$TMP/node-wrapper" <<SH
#!/usr/bin/env bash
set -uo pipefail
INPUT="$TMP/node-input.json"
OUTPUT="$TMP/node-output.json"
ERROR="$TMP/node-error.txt"
cat > "\$INPUT"
"$REAL_NODE" "\$@" < "\$INPUT" > "\$OUTPUT" 2> "\$ERROR"
STATUS=\$?
cat "\$OUTPUT"
cat "\$ERROR" >&2
if [[ \$STATUS -eq 0 && "\${2:-}" == apply-note-change \
  && -n "\${FAKE_INTERRUPT_AFTER_BASE_UPDATE:-}" \
  && ! -e "$TMP/node-interrupted" ]] \
  && grep -Fq 'Projects/example/rules/base-contract.md' "\$INPUT"; then
  : > "$TMP/node-interrupted"
  printf 'injected interruption after bridge write\n' >&2
  exit 99
fi
if [[ \$STATUS -eq 0 && "\${2:-}" == status \
  && -n "\${FAKE_EDIT_AFTER_STATUS:-}" \
  && ! -e "$TMP/node-status-edited" ]]; then
  : > "$TMP/node-status-edited"
  printf '\nHuman edit after plan validation.\n' >> "$VAULT/$SOURCE_ROOT/rules/base-contract.md"
  git -C "$VAULT" add "$SOURCE_ROOT/rules/base-contract.md"
  git -C "$VAULT" commit -m 'human edit after plan validation' >/dev/null
  git -C "$VAULT" push origin main >/dev/null
fi
if [[ \$STATUS -eq 0 && "\${2:-}" == publish \
  && -n "\${FAKE_INTERRUPT_AFTER_PUBLISH:-}" \
  && ! -e "$TMP/node-publish-interrupted" ]]; then
  : > "$TMP/node-publish-interrupted"
  printf 'injected interruption after publisher completion\n' >&2
  exit 99
fi
exit \$STATUS
SH
chmod +x "$TMP/node-wrapper"

cat > "$PROJECT/.shared-adapter/settings.json" <<JSON
{
  "wiki": {
    "provider": "obsidian",
    "publishing": {"mode": "git-pr"},
    "obsidian": {
      "bindings": [{
        "sourceId": "project-source",
        "role": "project",
        "vaultRef": "knowledge",
        "repositoryRef": "wiki",
        "root": "$SOURCE_ROOT",
        "access": {"read": true, "update": "direct"}
      }]
    }
  }
}
JSON
cat > "$TMP/registry.json" <<JSON
{
  "vaults": {
    "knowledge": {
      "selector": "Knowledge",
      "bridgeUrl": "http://127.0.0.1:$PORT",
      "bridgeTokenEnv": "TEST_BRIDGE_TOKEN"
    }
  },
  "repositories": {
    "wiki": {
      "worktreeRoot": "$VAULT",
      "remote": "origin",
      "expectedRemote": "$REMOTE",
      "baseBranch": "main",
      "syncBeforeResearch": true
    }
  }
}
JSON

export CLAUDE_PROJECT_DIR="$PROJECT"
export OBSIDIAN_WIKI_REGISTRY="$TMP/registry.json"
export OBSIDIAN_WIKI_OBSIDIAN_CLI="$TMP/obsidian"
export OBSIDIAN_WIKI_GH_CLI="$TMP/gh"
export FAKE_OBSIDIAN_VAULT_ROOT="$VAULT"
export FAKE_GH_STATE="$TMP/gh-state.json"
export TEST_BRIDGE_TOKEN="migration-token"
export OBSIDIAN_WIKI_BRIDGE_TOKEN="migration-token"
export OBSIDIAN_WIKI_BRIDGE_VAULT_ROOT="$VAULT"
export OBSIDIAN_WIKI_BRIDGE_VAULT_SELECTOR="Knowledge"
export OBSIDIAN_WIKI_BRIDGE_ALLOWED_ROOTS='["Projects/example"]'
export OBSIDIAN_WIKI_BRIDGE_PROJECT_DIRS="[\"$PROJECT\"]"
export OBSIDIAN_WIKI_BRIDGE_PORT="$PORT"

node "$BUNDLE" serve-write-bridge > "$TMP/bridge.out" 2> "$TMP/bridge.err" &
BRIDGE_PID=$!
for _ in {1..50}; do
  if grep -q '"url"' "$TMP/bridge.out" 2>/dev/null; then break; fi
  sleep 0.1
done
grep -q '"url"' "$TMP/bridge.out" || { cat "$TMP/bridge.err" >&2; exit 1; }

PLAN="$TMP/plan.json"
python3 "$PLANNER" --project-root "$PROJECT" --registry "$TMP/registry.json" --wiki-root project > "$PLAN"
if python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" > /dev/null 2> "$TMP/unconfirmed.err"; then
  printf 'Migration apply accepted a plan without explicit confirmation\n' >&2
  exit 1
fi
grep -Fq 'explicit confirmation' "$TMP/unconfirmed.err"

APPLY_OUT="$TMP/apply.json"
# The reviewed update hash comes from the immutable plan. A human edit after the
# full-plan revalidation must not become the accepted CAS baseline.
cp "$VAULT/$SOURCE_ROOT/rules/base-contract.md" "$TMP/reviewed-base.md"
export OBSIDIAN_WIKI_NODE="$TMP/node-wrapper"
export FAKE_EDIT_AFTER_STATUS=1
if python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" --confirmed > /dev/null 2> "$TMP/plan-race.err"; then
  printf 'Migration apply accepted target drift after plan validation\n' >&2
  exit 1
fi
unset OBSIDIAN_WIKI_NODE FAKE_EDIT_AFTER_STATUS
grep -Fq 'confirmed target Note changed' "$TMP/plan-race.err"
cp "$TMP/reviewed-base.md" "$VAULT/$SOURCE_ROOT/rules/base-contract.md"
git -C "$VAULT" add "$SOURCE_ROOT/rules/base-contract.md"
git -C "$VAULT" commit -m 'restore reviewed target snapshot' >/dev/null
git -C "$VAULT" push origin main >/dev/null

# The write intent must exist before the bridge call, and a crash after that call must
# leave the exact migration result on its dedicated PR branch rather than on main.
export OBSIDIAN_WIKI_NODE="$TMP/node-wrapper"
export FAKE_INTERRUPT_AFTER_BASE_UPDATE=1
if python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" --confirmed > /dev/null 2> "$TMP/interrupted.err"; then
  printf 'Migration apply ignored the post-bridge interruption failpoint\n' >&2
  exit 1
fi
unset OBSIDIAN_WIKI_NODE FAKE_INTERRUPT_AFTER_BASE_UPDATE
grep -Fq 'injected interruption after bridge write' "$TMP/interrupted.err"
ACTIVE_BRANCH="$(git -C "$VAULT" branch --show-current)"
[[ "$ACTIVE_BRANCH" == grill-adapter/wiki/migration-* ]] || {
  printf 'Migration write was not isolated on a dedicated branch: %s\n' "$ACTIVE_BRANCH" >&2
  exit 1
}
UPDATED_NOTE="$VAULT/$SOURCE_ROOT/rules/base-contract.md"
cp "$UPDATED_NOTE" "$TMP/interrupted-update.md"
printf '\nHuman edit during interrupted migration.\n' >> "$UPDATED_NOTE"
DRIFTED_HASH="$(shasum -a 256 "$UPDATED_NOTE")"
if python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" --confirmed > /dev/null 2> "$TMP/interrupted-drift.err"; then
  printf 'Migration resume overwrote a human edit after an interrupted update\n' >&2
  exit 1
fi
grep -Fq 'write intent drift' "$TMP/interrupted-drift.err"
[[ "$(shasum -a 256 "$UPDATED_NOTE")" == "$DRIFTED_HASH" ]] || {
  printf 'Migration resume changed the drifted Note\n' >&2
  exit 1
}
cp "$TMP/interrupted-update.md" "$UPDATED_NOTE"

# The exact expected post-state is reconciled without a duplicate write.
export OBSIDIAN_WIKI_NODE="$TMP/node-wrapper"
export FAKE_INTERRUPT_AFTER_PUBLISH=1
if python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" --confirmed > /dev/null 2> "$TMP/publish-interrupted.err"; then
  printf 'Migration apply ignored the post-publisher interruption\n' >&2
  exit 1
fi
unset OBSIDIAN_WIKI_NODE FAKE_INTERRUPT_AFTER_PUBLISH
grep -Fq 'injected interruption after publisher completion' "$TMP/publish-interrupted.err"

# Publisher state is the durable recovery source when the coordinator receipt was not persisted.
python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" --confirmed > "$APPLY_OUT"
python3 - "$APPLY_OUT" "$VAULT" "$FAKE_GH_STATE" <<'PY'
import json, pathlib, subprocess, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["kind"] == "grill-adapter.obsidian-migration"
assert result["state"] == "published"
assert len(result["notes"]) == 3
assert {note["sourceKind"] for note in result["notes"]} == {"section", "skill-discovery"}
assert result["repositories"][0]["branch"].startswith("grill-adapter/wiki/migration-")
assert subprocess.check_output(["git", "-C", sys.argv[2], "branch", "--show-current"], text=True).strip() == "main"
assert not pathlib.Path(sys.argv[2], "Projects/example/rules/api-contract.md").exists()
assert "The old base contract may change." in pathlib.Path(
    sys.argv[2], "Projects/example/rules/base-contract.md"
).read_text(encoding="utf-8")
gh = json.load(open(sys.argv[3], encoding="utf-8"))
assert gh["createCount"] == 1
PY

# Apply resumes idempotently from the migration and publish manifests.
python3 "$MIGRATOR" apply --project-root "$PROJECT" --plan "$PLAN" --confirmed > "$TMP/apply-two.json"
cmp -s "$APPLY_OUT" "$TMP/apply-two.json"
python3 - "$FAKE_GH_STATE" <<'PY'
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["createCount"] == 1
PY

MANIFEST="$(python3 - "$APPLY_OUT" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["manifestPath"])
PY
)"
if python3 "$MIGRATOR" verify --project-root "$PROJECT" --manifest "$MANIFEST" > /dev/null 2> "$TMP/open-pr.err"; then
  printf 'Migration verify accepted an open PR\n' >&2
  exit 1
fi
grep -Fq 'not merged' "$TMP/open-pr.err"

BRANCH="$(python3 - "$APPLY_OUT" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["repositories"][0]["branch"])
PY
)"
git --git-dir="$REMOTE" update-ref refs/heads/main "refs/heads/$BRANCH"
git -C "$VAULT" fetch origin main >/dev/null
git -C "$VAULT" merge --ff-only origin/main >/dev/null
python3 - "$FAKE_GH_STATE" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path, encoding="utf-8"))
for pr in state["prs"].values():
    pr["state"] = "MERGED"
    pr["mergedAt"] = "2026-07-22T00:00:00Z"
json.dump(state, open(path, "w", encoding="utf-8"))
PY

python3 "$MIGRATOR" verify --project-root "$PROJECT" --manifest "$MANIFEST" > "$TMP/verify.json"
python3 - "$TMP/verify.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["state"] == "verified"
assert result["checks"]["mappingCoverage"] is True
assert result["checks"]["uniqueWikiIds"] is True
assert result["checks"]["search"] is True
assert result["checks"]["hardNoteReread"] is True
assert result["checks"]["typedEdges"] is True
PY

# The immutable embedded plan, not mutable receipt arrays, defines coverage.
cp "$MANIFEST" "$TMP/manifest.good.json"
python3 - "$MANIFEST" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["notes"].pop()
json.dump(value, open(path, "w", encoding="utf-8"), indent=2)
PY
if python3 "$MIGRATOR" verify --project-root "$PROJECT" --manifest "$MANIFEST" > /dev/null 2> "$TMP/coverage.err"; then
  printf 'Migration verify trusted a manifest with a deleted Note row\n' >&2
  exit 1
fi
grep -Fq 'coverage' "$TMP/coverage.err"
cp "$TMP/manifest.good.json" "$MANIFEST"

cp "$PROJECT/.adapter/wiki/rules.md" "$TMP/legacy-rules.good.md"
printf '\nLegacy source drift.\n' >> "$PROJECT/.adapter/wiki/rules.md"
if python3 "$MIGRATOR" verify --project-root "$PROJECT" --manifest "$MANIFEST" > /dev/null 2> "$TMP/source-drift.err"; then
  printf 'Migration verify accepted legacy source drift\n' >&2
  exit 1
fi
grep -Fq 'legacy source snapshot drift' "$TMP/source-drift.err"
cp "$TMP/legacy-rules.good.md" "$PROJECT/.adapter/wiki/rules.md"

cp "$PROJECT/.shared-adapter/settings.json" "$TMP/settings.good.json"
python3 - "$PROJECT/.shared-adapter/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["wiki"]["obsidian"]["bindings"][0]["access"]["update"] = "deny"
json.dump(value, open(path, "w", encoding="utf-8"), indent=2)
PY
if python3 "$MIGRATOR" verify --project-root "$PROJECT" --manifest "$MANIFEST" > /dev/null 2> "$TMP/binding-drift.err"; then
  printf 'Migration verify accepted binding policy drift\n' >&2
  exit 1
fi
grep -Fq 'binding snapshot drift' "$TMP/binding-drift.err"
cp "$TMP/settings.good.json" "$PROJECT/.shared-adapter/settings.json"

# Verification is read-only and refuses a post-merge human edit instead of overwriting it.
NOTE="$VAULT/$SOURCE_ROOT/rules/api-contract.md"
cp "$NOTE" "$TMP/note.backup"
printf '\nHuman edit.\n' >> "$NOTE"
git -C "$VAULT" add "$SOURCE_ROOT/rules/api-contract.md"
git -C "$VAULT" commit -m "human edit after migration" >/dev/null
git -C "$VAULT" push origin main >/dev/null
if python3 "$MIGRATOR" verify --project-root "$PROJECT" --manifest "$MANIFEST" > /dev/null 2> "$TMP/drift.err"; then
  printf 'Migration verify accepted Note content drift\n' >&2
  exit 1
fi
grep -Fq 'content hash drift' "$TMP/drift.err"
cp "$TMP/note.backup" "$NOTE"
git -C "$VAULT" add "$SOURCE_ROOT/rules/api-contract.md"
git -C "$VAULT" commit -m "restore reviewed migration Note" >/dev/null
git -C "$VAULT" push origin main >/dev/null

printf '{"schemaVersion":5,"kind":"grill-adapter.wiki-context"}\n' > "$PROJECT/.adapter/context/active.wiki-context.json"
if python3 "$MIGRATOR" cutover --project-root "$PROJECT" --manifest "$MANIFEST" --confirmed > /dev/null 2> "$TMP/v5.err"; then
  printf 'Migration cutover accepted an active schema-v5 sidecar\n' >&2
  exit 1
fi
grep -Fq 'schemaVersion 5' "$TMP/v5.err"
printf '{"schemaVersion":6,"kind":"grill-adapter.wiki-context"}\n' > "$PROJECT/.adapter/context/active.wiki-context.json"

if python3 "$MIGRATOR" cutover --project-root "$PROJECT" --manifest "$MANIFEST" > /dev/null 2> "$TMP/unconfirmed-cutover.err"; then
  printf 'Migration cutover accepted missing explicit confirmation\n' >&2
  exit 1
fi
grep -Fq 'explicit confirmation' "$TMP/unconfirmed-cutover.err"

LEGACY_BEFORE="$(find "$PROJECT/.adapter/wiki" -type f -print0 | sort -z | xargs -0 shasum -a 256)"
python3 "$MIGRATOR" cutover --project-root "$PROJECT" --manifest "$MANIFEST" --confirmed > "$TMP/cutover.json"
LEGACY_AFTER="$(find "$PROJECT/.adapter/wiki" -type f -print0 | sort -z | xargs -0 shasum -a 256)"
[[ "$LEGACY_BEFORE" == "$LEGACY_AFTER" ]] || { printf 'Cutover modified the legacy archive\n' >&2; exit 1; }
python3 - "$TMP/cutover.json" "$PROJECT/.shared-adapter/settings.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
settings = json.load(open(sys.argv[2], encoding="utf-8"))
assert result["state"] == "cutover"
assert settings["wiki"]["provider"] == "obsidian"
archive = settings["wiki"]["legacyRuntime"]
assert archive["mode"] == "read-only-archive"
assert archive["roots"] == [".adapter/wiki"]
assert archive["migrationManifest"].endswith(".obsidian-migration.json")
PY

"$ROOT/doctor.sh" "$PROJECT" > "$TMP/doctor-cutover.out"
grep -Fq 'adoptionState: cutover-complete' "$TMP/doctor-cutover.out"
grep -Fq 'read-only legacy archives: .adapter/wiki' "$TMP/doctor-cutover.out"
grep -Fq 'Obsidian runtime healthy: yes' "$TMP/doctor-cutover.out"

printf 'obsidian wiki migration apply/verify/cutover smoke complete\n'
