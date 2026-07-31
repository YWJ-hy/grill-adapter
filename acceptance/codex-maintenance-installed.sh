#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

if [[ "${GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE:-}" != "1" ]]; then
  printf 'codex maintenance installed acceptance SKIP (set GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1)\n'
  exit 0
fi

command -v codex >/dev/null || { printf 'codex CLI not found\n' >&2; exit 1; }

SANDBOX="$(mktemp -d)"
cleanup() {
  status="$?"
  if [[ "$status" == "0" ]]; then
    rm -rf "$SANDBOX"
  else
    printf 'acceptance sandbox preserved: %s\n' "$SANDBOX" >&2
  fi
}
trap cleanup EXIT
PROJECT="$SANDBOX/project"
VAULT="$SANDBOX/vault"
CODEX_SANDBOX_HOME="$SANDBOX/codex-home"
REGISTRY="$SANDBOX/obsidian-wiki.json"
OBSIDIAN_CLI="$SANDBOX/obsidian"
LAST_MESSAGE="$SANDBOX/last-message.txt"
EVENT_LOG="$SANDBOX/codex-events.jsonl"
PRIVATE_MARKER='ISSUE_32_PRIVATE_NOTE_BODY_MUST_NOT_ESCAPE'

mkdir -p \
  "$PROJECT/.grill-adapter" \
  "$VAULT/Projects/example/_meta" \
  "$CODEX_SANDBOX_HOME"

cat > "$VAULT/Projects/example/_meta/wiki-source.md" <<'EOF'
---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: project
scope: project
agent_visible: true
update_existing: ask
create_note: ask
---

# Project Source
EOF

cat > "$VAULT/Projects/example/Runtime.md" <<'EOF'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project/runtime
type: constraint
status: active
agent_visible: true
summary: Runtime lifecycle rules
constraint_strength: hard
verified_at: 2026-06-01T00:00:00Z
review_after: 2026-07-01T00:00:00Z
expires_at: 2027-01-01T00:00:00Z
---

# Runtime

ISSUE_32_PRIVATE_NOTE_BODY_MUST_NOT_ESCAPE

Initialization and shutdown use independent triggers, failure modes, and validation paths.
EOF

cat > "$VAULT/Projects/example/Stable.md" <<'EOF'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project/stable
type: constraint
status: active
agent_visible: true
summary: Stable build rule
constraint_strength: hard
verified_at: 2026-07-01T00:00:00Z
review_after: 2026-12-01T00:00:00Z
expires_at: 2027-01-01T00:00:00Z
---

# Stable

Build artifacts must be reproducible.
EOF

cat > "$PROJECT/.grill-adapter/settings.json" <<'EOF'
{
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
          "access": {"read": true, "update": "ask"}
        }
      ]
    }
  }
}
EOF

cat > "$REGISTRY" <<EOF
{
  "version": 1,
  "vaults": {"knowledge": {"selector": "Knowledge"}},
  "repositories": {
    "wiki": {
      "worktreeRoot": "$VAULT",
      "remote": "origin",
      "expectedRemote": "github.com/acme/knowledge",
      "baseBranch": "main",
      "syncBeforeResearch": false,
      "allowStaleRead": true
    }
  }
}
EOF

cat > "$OBSIDIAN_CLI" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "vaults" ]]; then
  printf 'Knowledge\n'
  exit 0
fi
operation=''
note_path=''
for argument in "$@"; do
  [[ "$argument" == "read" ]] && operation='read'
  [[ "$argument" == path=* ]] && note_path="${argument#path=}"
done
[[ "$operation" == 'read' && -n "$note_path" ]] || exit 2
[[ "$note_path" != /* && "$note_path" != *'..'* ]] || exit 2
cat "$FAKE_OBSIDIAN_VAULT_ROOT/$note_path"
EOF
chmod +x "$OBSIDIAN_CLI"

git -C "$PROJECT" init -q
git -C "$VAULT" init -q --initial-branch=main
git -C "$VAULT" config user.name 'Acceptance Test'
git -C "$VAULT" config user.email 'acceptance@example.invalid'
git -C "$VAULT" remote add origin https://github.com/acme/knowledge.git
git -C "$VAULT" add .
git -C "$VAULT" commit -qm fixture

"$ROOT/manage.sh" install "$PROJECT" --host plain --runtime codex >/dev/null

SOURCE_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
if [[ -f "$SOURCE_CODEX_HOME/auth.json" ]]; then
  cp "$SOURCE_CODEX_HOME/auth.json" "$CODEX_SANDBOX_HOME/auth.json"
fi

export CODEX_HOME="$CODEX_SANDBOX_HOME"
export OBSIDIAN_WIKI_CONFIG="$REGISTRY"
export OBSIDIAN_WIKI_OBSIDIAN_CLI="$OBSIDIAN_CLI"
export FAKE_OBSIDIAN_VAULT_ROOT="$VAULT"

codex plugin marketplace add "$ROOT" --json >/dev/null
codex plugin add grill-adapter@grill-adapter --json >/dev/null

codex exec \
  --cd "$PROJECT" \
  --enable multi_agent_v2 \
  --sandbox workspace-write \
  --dangerously-bypass-hook-trust \
  --json \
  --output-last-message "$LAST_MESSAGE" \
  -c 'approval_policy="never"' \
  -c 'multi_agent_v2.hide_spawn_agent_metadata=false' \
  -c 'multi_agent_v2.max_concurrent_threads_per_session=4' \
  'Invoke $grill-adapter:wiki-maintenance audit issue-32 with asOf 2026-07-31T12:00:00Z, identityLimit 10, and noteReadLimit 4. Follow the installed skill exactly. Do not implement or modify product code. Return only its compact summary.' \
  > "$EVENT_LOG"

REPORT="$PROJECT/.grill-adapter/context/issue-32/wiki-maintenance-audit.json"
[[ -f "$REPORT" ]] || { printf 'installed audit did not create its report\n' >&2; exit 1; }
python3 "$ROOT/scripts/wiki_maintenance_report.py" validate "$REPORT" >/dev/null

if grep -Fq "$PRIVATE_MARKER" "$REPORT" || grep -Fq "$PRIVATE_MARKER" "$LAST_MESSAGE"; then
  printf 'private Note body escaped the maintenance agent\n' >&2
  exit 1
fi

python3 - "$REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding='utf-8'))
assert report['kind'] == 'grill-adapter.wiki-maintenance-report'
assert report['mode'] == 'audit'
assert report['authoritative'] is False
assert report['scanned']['noteBodiesRead'] <= report['limits']['noteReadLimit'] == 4
assert report['snapshotIdentity']['auditedNoteSnapshots']
PY

printf 'codex maintenance installed acceptance OK\n'
