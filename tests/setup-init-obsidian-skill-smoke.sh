#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SKILL="$ROOT/skills/setup-init-obsidian/SKILL.md"
UI="$ROOT/skills/setup-init-obsidian/agents/openai.yaml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

[[ -f "$SKILL" ]] || fail "setup-init-obsidian skill is missing"
[[ -f "$UI" ]] || fail "setup-init-obsidian UI metadata is missing"
need "$SKILL" 'name: setup-init-obsidian'
need "$SKILL" 'grill-adapter'
need "$SKILL" '@grill-adapter/obsidian-wiki'
need "$SKILL" 'npm list --global --depth=0 --json'
need "$SKILL" 'npm install --global grill-adapter @grill-adapter/obsidian-wiki'
need "$SKILL" 'obsidian-wiki init'
need "$SKILL" 'obsidian-wiki config upsert-vault'
need "$SKILL" 'obsidian-wiki config upsert-repository'
need "$SKILL" 'user-only permissions'
need "$SKILL" 'obsidian-wiki config validate'
need "$SKILL" 'grill-adapter doctor'
need "$SKILL" 'grill-adapter install'
need "$SKILL" 'Vault-relative root'
need "$SKILL" 'repositoryRef'
need "$SKILL" 'do not ask the user to invent internal IDs'
need "$SKILL" 'Which Obsidian Vault should hold this Wiki?'
need "$SKILL" "Where inside that Vault should this Wiki's Notes live?"
need "$SKILL" 'Which Git repository stores that Wiki folder?'
need "$SKILL" '这个项目需要连接几个 Wiki 库？'
need "$SKILL" 'Required multi-Wiki inventory'
need "$SKILL" '每个项目最多一个 project Wiki'
need "$SKILL" 'Treat each answer as a separate Source candidate'
need "$SKILL" '已发现这些 Wiki 库'
need "$SKILL" 'Wiki purpose | sourceId'
need "$SKILL" 'one complete row per Wiki'
need "$SKILL" 'Should any legacy Wiki content migrate into this Wiki?'
need "$SKILL" 'never infer a target when several Source'
need "$SKILL" 'Human choice'
need "$SKILL" 'Derived configuration'
need "$SKILL" '"publishing": { "mode": "git-pr" }'
need "$SKILL" '"access": { "read": true, "update": "confirm" }'
need "$SKILL" '"sharedNeutrality"'
need "$SKILL" '`publishing` accepts only `mode`'
need "$SKILL" 'doctor accepts the canonical shape'
need "$SKILL" 'single GitHub repository is supported'
need "$SKILL" 'Multiple GitHub repositories are supported'
need "$SKILL" 'legacy shared-wiki Git URL'
need "$SKILL" 'migrate-wiki'
need "$SKILL" 'read-only migration plan'
need "$SKILL" 'Ask explicitly whether the user authorizes'
need "$SKILL" 'legacy-shared-wiki-url'
need "$SKILL" '`migrate-wiki` verify'
need "$SKILL" '`migrate-wiki` cutover'
need "$SKILL" 'cutover confirmation'
need "$SKILL" 'wait'
need "$UI" 'display_name: "Setup Obsidian"'
need "$UI" '$setup-init-obsidian'
if grep -Fq '__GRILL_ADAPTER_ROOT__' "$SKILL"; then
  fail "obsolete placeholder remains in setup-init-obsidian"
fi

printf 'setup-init-obsidian skill smoke complete\n'
