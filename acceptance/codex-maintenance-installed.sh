#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

if [[ "${GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE:-}" != "1" ]]; then
  printf 'codex maintenance installed acceptance SKIP (set GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1)\n'
  exit 0
fi

CODEX_BIN="${GRILL_ADAPTER_CODEX_BIN:-}"
if [[ -z "$CODEX_BIN" && -x "${HOME}/.npm-global/bin/codex" ]]; then
  CODEX_BIN="${HOME}/.npm-global/bin/codex"
elif [[ -z "$CODEX_BIN" ]]; then
  CODEX_BIN="$(command -v codex || true)"
fi
[[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]] || {
  printf 'working Codex CLI not found; set GRILL_ADAPTER_CODEX_BIN\n' >&2
  exit 1
}
command -v expect >/dev/null || { printf 'expect is required for interactive Codex acceptance\n' >&2; exit 1; }

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
TERMINAL_LOG="$SANDBOX/codex-audit-terminal.log"
CONSOLIDATION_TERMINAL_LOG="$SANDBOX/codex-consolidation-terminal.log"
PRIVATE_MARKER='ISSUE_32_PRIVATE_NOTE_BODY_MUST_NOT_ESCAPE'
UNSELECTED_MARKER='ISSUE_32_UNSELECTED_NOTE_BODY_MUST_NOT_ESCAPE'
EQUIVALENT_MARKER='ISSUE_33_EQUIVALENT_CANDIDATE_PROSE_MUST_NOT_ESCAPE'
CONTRADICTORY_MARKER='ISSUE_33_CONTRADICTORY_CANDIDATE_PROSE_MUST_NOT_ESCAPE'
INDEPENDENT_MARKER='ISSUE_33_INDEPENDENT_CANDIDATE_PROSE_MUST_NOT_ESCAPE'

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

ISSUE_32_UNSELECTED_NOTE_BODY_MUST_NOT_ESCAPE

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

mkdir -p \
  "$PROJECT/.grill-adapter/context/retry-a" \
  "$PROJECT/.grill-adapter/context/retry-b" \
  "$PROJECT/.grill-adapter/context/cache-policy" \
  "$PROJECT/.grill-adapter/context/cache-recovery" \
  "$PROJECT/.grill-adapter/context/cache-startup"

cat > "$PROJECT/.grill-adapter/context/retry-a/wiki-candidates.jsonl" <<'EOF'
{"schemaVersion":1,"eventType":"candidate","eventId":"event-a","featureSlug":"retry-a","recordedAt":"2026-07-31T00:00:00Z","candidateId":"candidate-a","stage":"implementation","candidateType":"wiki_note","kind":"decision","claim":"All outbound request attempts must share one total retry budget across transport layers.","why":"ISSUE_33_EQUIVALENT_CANDIDATE_PROSE_MUST_NOT_ESCAPE","sourceRefs":["tests/retry-a"]}
EOF

cat > "$PROJECT/.grill-adapter/context/retry-b/wiki-candidates.jsonl" <<'EOF'
{"schemaVersion":1,"eventType":"candidate","eventId":"event-b","featureSlug":"retry-b","recordedAt":"2026-07-31T00:01:00Z","candidateId":"candidate-b","stage":"implementation","candidateType":"wiki_note","kind":"correction","claim":"Use one shared retry budget for an outbound operation, including every transport layer.","why":"ISSUE_33_EQUIVALENT_CANDIDATE_PROSE_MUST_NOT_ESCAPE","sourceRefs":["tests/retry-b"],"correction":{"affectedWikiIdentity":{"sourceId":"project","wikiId":"project/runtime"},"claim":"Use one shared retry budget for an outbound operation, including every transport layer.","evidenceRefs":["tests/retry-b"],"observedImpact":"Nested retries multiplied attempts."}}
EOF

cat > "$PROJECT/.grill-adapter/context/cache-policy/wiki-candidates.jsonl" <<'EOF'
{"schemaVersion":1,"eventType":"candidate","eventId":"event-c","featureSlug":"cache-policy","recordedAt":"2026-07-31T00:02:00Z","candidateId":"candidate-c","stage":"implementation","candidateType":"wiki_note","kind":"decision","claim":"A cache decode failure must fail closed and must never serve stale data.","why":"ISSUE_33_CONTRADICTORY_CANDIDATE_PROSE_MUST_NOT_ESCAPE","sourceRefs":["tests/cache-policy"]}
EOF

cat > "$PROJECT/.grill-adapter/context/cache-recovery/wiki-candidates.jsonl" <<'EOF'
{"schemaVersion":1,"eventType":"candidate","eventId":"event-d","featureSlug":"cache-recovery","recordedAt":"2026-07-31T00:03:00Z","candidateId":"candidate-d","stage":"implementation","candidateType":"wiki_note","kind":"decision","claim":"A cache decode failure may serve stale data when the origin is unavailable.","why":"ISSUE_33_CONTRADICTORY_CANDIDATE_PROSE_MUST_NOT_ESCAPE","sourceRefs":["tests/cache-recovery"]}
EOF

cat > "$PROJECT/.grill-adapter/context/cache-startup/wiki-candidates.jsonl" <<'EOF'
{"schemaVersion":1,"eventType":"candidate","eventId":"event-e","featureSlug":"cache-startup","recordedAt":"2026-07-31T00:04:00Z","candidateId":"candidate-e","stage":"implementation","candidateType":"wiki_note","kind":"decision","claim":"At process startup, validate the cache schema version before loading entries.","why":"ISSUE_33_INDEPENDENT_CANDIDATE_PROSE_MUST_NOT_ESCAPE","sourceRefs":["tests/cache-startup"]}
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
  [[ "$argument" == "search" ]] && operation='search'
  [[ "$argument" == "read" ]] && operation='read'
  [[ "$argument" == path=* ]] && note_path="${argument#path=}"
done
if [[ "$operation" == 'search' ]]; then
  printf '["Projects/example/Runtime.md","Projects/example/Stable.md"]\n'
  exit 0
fi
[[ "$operation" == 'read' && -n "$note_path" ]] || exit 2
[[ "$note_path" != /* && "$note_path" != *'..'* ]] || exit 2
cat "$FAKE_OBSIDIAN_VAULT_ROOT/$note_path"
EOF
chmod +x "$OBSIDIAN_CLI"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Acceptance Test'
git -C "$PROJECT" config user.email 'acceptance@example.invalid'
git -C "$VAULT" init -q --initial-branch=main
git -C "$VAULT" config user.name 'Acceptance Test'
git -C "$VAULT" config user.email 'acceptance@example.invalid'
git -C "$VAULT" remote add origin https://github.com/acme/knowledge.git
git -C "$VAULT" add .
git -C "$VAULT" commit -qm fixture

"$ROOT/manage.sh" install "$PROJECT" --host plain --runtime codex >/dev/null
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm fixture
PROJECT_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
VAULT_HEAD="$(git -C "$VAULT" rev-parse HEAD)"

SOURCE_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
if [[ -f "$SOURCE_CODEX_HOME/auth.json" ]]; then
  cp "$SOURCE_CODEX_HOME/auth.json" "$CODEX_SANDBOX_HOME/auth.json"
fi
[[ -f "$CODEX_SANDBOX_HOME/auth.json" ]] || {
  printf 'Codex authentication not found at %s/auth.json\n' "$SOURCE_CODEX_HOME" >&2
  exit 1
}
if [[ -f "$SOURCE_CODEX_HOME/config.toml" ]]; then
  model_provider="$(sed -nE 's/^model_provider[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$SOURCE_CODEX_HOME/config.toml" | head -1)"
  awk -v provider_section="[model_providers.${model_provider}]" '
    /^\[/ { in_provider = ($0 == provider_section) }
    in_provider { print; next }
    /^(model_provider|model|disable_response_storage|model_reasoning_effort|service_tier)[[:space:]]*=/ { print }
  ' "$SOURCE_CODEX_HOME/config.toml" > "$CODEX_SANDBOX_HOME/config.toml"
fi

export CODEX_HOME="$CODEX_SANDBOX_HOME"
"$CODEX_BIN" plugin marketplace add "$ROOT" --json >/dev/null
"$CODEX_BIN" plugin add grill-adapter@grill-adapter --json >/dev/null

MCP_BUNDLE="$(find "$CODEX_SANDBOX_HOME/plugins/cache/grill-adapter/grill-adapter" \
  -path '*/mcp/obsidian-wiki/dist/index.js' -type f -print -quit)"
[[ -n "$MCP_BUNDLE" ]] || { printf 'installed Obsidian MCP bundle not found\n' >&2; exit 1; }

export ACCEPTANCE_CODEX_BIN="$CODEX_BIN"
export ACCEPTANCE_PROJECT="$PROJECT"
export ACCEPTANCE_MCP_BUNDLE="$MCP_BUNDLE"
export ACCEPTANCE_REGISTRY="$REGISTRY"
export ACCEPTANCE_OBSIDIAN_CLI="$OBSIDIAN_CLI"
export ACCEPTANCE_VAULT="$VAULT"
export ACCEPTANCE_SESSIONS="$CODEX_SANDBOX_HOME/sessions"

run_codex_acceptance() {
expect <<'EXPECT'
log_file -noappend $env(ACCEPTANCE_TERMINAL_LOG)
set env(TERM) xterm-256color
set mcp_args [format {mcp_servers.obsidian-wiki.args=["%s"]} $env(ACCEPTANCE_MCP_BUNDLE)]
set mcp_env "mcp_servers.obsidian-wiki.env={OBSIDIAN_WIKI_CONFIG=\"$env(ACCEPTANCE_REGISTRY)\",OBSIDIAN_WIKI_OBSIDIAN_CLI=\"$env(ACCEPTANCE_OBSIDIAN_CLI)\",FAKE_OBSIDIAN_VAULT_ROOT=\"$env(ACCEPTANCE_VAULT)\"}"
set project_trust [format {projects."%s".trust_level="trusted"} $env(ACCEPTANCE_PROJECT)]

proc parent_complete {} {
  global env
  set completed 0
  foreach rollout [glob -nocomplain [file join $env(ACCEPTANCE_SESSIONS) * * * rollout-*.jsonl]] {
    set handle [open $rollout r]
    set first_line [gets $handle]
    set remainder [read $handle]
    close $handle
    if {[regexp {"thread_source"\s*:\s*"user"} $first_line] && [regexp {"type"\s*:\s*"task_complete"} $remainder]} {
      incr completed
    }
  }
  return [expr {$completed > $env(ACCEPTANCE_COMPLETED_PARENTS)}]
}

spawn -noecho $env(ACCEPTANCE_CODEX_BIN) \
  --no-alt-screen \
  --dangerously-bypass-hook-trust \
  --cd $env(ACCEPTANCE_PROJECT) \
  --sandbox workspace-write \
  --ask-for-approval never \
  -c {model_reasoning_effort="low"} \
  -c {mcp_servers.obsidian-wiki.command="node"} \
  -c $mcp_args \
  -c $mcp_env \
  -c $project_trust \
  $env(ACCEPTANCE_PROMPT)

set deadline [expr {[clock seconds] + 900}]
set finished 0
while {[clock seconds] < $deadline} {
  set timeout 1
  expect {
    -re {Continue anyway.*\[y/N\]} { send -- "y\r" }
    -re {Yes, continue} { send -- "\r" }
    -re {Approaching rate limits} { send -- "\033\[B\033\[B\r" }
    eof { exit 1 }
    timeout {}
  }
  if {[parent_complete]} {
    set finished 1
    break
  }
}
if {!$finished} {
  send -- "\003"
  after 800
  send -- "\003"
  exit 124
}
after 1000
send -- "\003"
after 800
send -- "\003"
expect eof
EXPECT
}

export ACCEPTANCE_TERMINAL_LOG="$TERMINAL_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=0
export ACCEPTANCE_PROMPT='Invoke $grill-adapter:wiki-maintenance audit issue-32 with asOf 2026-07-31T12:00:00Z, identityLimit 10, and noteReadLimit 1. Follow the installed skill exactly: spawn with fork_turns none and embed the complete role file contents verbatim in the spawn message, use a 300000 millisecond wait_agent timeout, and use only another wait_agent after any timeout. Do not implement or modify product code. Return only its compact summary.'
run_codex_acceptance

REPORT="$PROJECT/.grill-adapter/context/issue-32/wiki-maintenance-audit.json"
[[ -f "$REPORT" ]] || { printf 'installed audit did not create its report\n' >&2; exit 1; }
python3 "$ROOT/scripts/wiki_maintenance_report.py" validate "$REPORT" >/dev/null

if grep -Fq "$PRIVATE_MARKER" "$REPORT" \
  || grep -Fq "$PRIVATE_MARKER" "$TERMINAL_LOG" \
  || grep -Fq "$UNSELECTED_MARKER" "$REPORT" \
  || grep -Fq "$UNSELECTED_MARKER" "$TERMINAL_LOG"; then
  printf 'private Note body escaped the maintenance agent\n' >&2
  exit 1
fi

[[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$PROJECT_HEAD" ]]
[[ "$(git -C "$VAULT" rev-parse HEAD)" == "$VAULT_HEAD" ]]
git -C "$PROJECT" diff --quiet
git -C "$VAULT" diff --quiet
[[ -z "$(git -C "$VAULT" status --porcelain --untracked-files=all)" ]]
project_status="$(git -C "$PROJECT" status --porcelain --untracked-files=all)"
[[ "$project_status" == '?? .grill-adapter/context/issue-32/wiki-maintenance-audit.json' ]] || {
  printf 'maintenance audit changed unexpected project files:\n%s\n' "$project_status" >&2
  exit 1
}

python3 - "$REPORT" "$CODEX_SANDBOX_HOME/sessions" "$TERMINAL_LOG" "$PRIVATE_MARKER" "$UNSELECTED_MARKER" <<'PY'
import json
import pathlib
import re
import sys

report_path, sessions_path, terminal_log_path, private_marker, unselected_marker = sys.argv[1:]
report = json.load(open(report_path, encoding='utf-8'))
assert report['kind'] == 'grill-adapter.wiki-maintenance-report'
assert report['mode'] == 'audit'
assert report['authoritative'] is False
assert report['asOf'] == '2026-07-31T12:00:00Z'
assert report['limits'] == {'identityLimit': 10, 'noteReadLimit': 1}
assert report['scanned']['noteBodiesRead'] <= report['limits']['noteReadLimit'] == 1
assert report['snapshotIdentity']['auditedNoteSnapshots']

expected_summary = {
    'status': report['status'],
    'mode': 'audit',
    'reportPath': '.grill-adapter/context/issue-32/wiki-maintenance-audit.json',
    'counts': {
        'sources': report['scanned']['sources'],
        'noteBodiesRead': report['scanned']['noteBodiesRead'],
        'findings': len(report['findings']),
    },
    'findingCounts': {},
    'caveats': report['caveats'],
}
for finding in report['findings']:
    category = finding['category']
    expected_summary['findingCounts'][category] = (
        expected_summary['findingCounts'].get(category, 0) + 1
    )
expected_summary['findingCounts'] = dict(sorted(expected_summary['findingCounts'].items()))


def load_rollout(path):
    events = [json.loads(line) for line in path.open(encoding='utf-8') if line.strip()]
    assert events and events[0]['type'] == 'session_meta', path
    return events[0]['payload'], events


rollouts = [load_rollout(path) for path in pathlib.Path(sessions_path).rglob('rollout-*.jsonl')]
parents = [item for item in rollouts if item[0].get('thread_source') == 'user']
children = [item for item in rollouts if item[0].get('thread_source') == 'subagent']
assert len(parents) == 1, [item[0].get('id') for item in parents]
assert len(children) == 1, [item[0].get('id') for item in children]
parent_meta, parent_events = parents[0]
child_meta, child_events = children[0]
assert child_meta['parent_thread_id'] == parent_meta['id']
child_path = child_meta['agent_path']

parent_text = '\n'.join(json.dumps(event, ensure_ascii=False) for event in parent_events)
assert private_marker not in parent_text
assert unselected_marker not in parent_text
assert private_marker not in pathlib.Path(terminal_log_path).read_text(encoding='utf-8')

task_completions = [
    event['payload'] for event in parent_events
    if event.get('type') == 'event_msg'
    and event.get('payload', {}).get('type') == 'task_complete'
]
assert len(task_completions) == 1
assert json.loads(task_completions[0]['last_agent_message']) == expected_summary

parent_calls = [
    (index, event['payload']) for index, event in enumerate(parent_events)
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') in {'function_call', 'custom_tool_call'}
]
spawn_calls = [(index, call) for index, call in parent_calls if call.get('name') == 'spawn_agent']
wait_calls = [(index, call) for index, call in parent_calls if call.get('name') == 'wait_agent']
assert len(spawn_calls) == 1
assert wait_calls and all(index > spawn_calls[0][0] for index, _ in wait_calls)
assert parent_calls[parent_calls.index(spawn_calls[0]) + 1][1]['name'] == 'wait_agent'

spawn_call_id = spawn_calls[0][1]['call_id']
spawn_outputs = [
    event['payload'] for event in parent_events
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') == 'function_call_output'
    and event['payload'].get('call_id') == spawn_call_id
]
assert len(spawn_outputs) == 1
assert json.loads(spawn_outputs[0]['output'])['task_name'] == child_path
terminal_child_messages = [
    event['payload'] for event in parent_events
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') == 'agent_message'
    and event['payload'].get('author') == child_path
]
assert len(terminal_child_messages) == 1

child_calls = [
    event['payload'] for event in child_events
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') in {'function_call', 'custom_tool_call'}
]
child_tool_code = '\n'.join(str(call.get('input') or call.get('arguments') or '') for call in child_calls)
read_calls = [
    code for code in re.findall(
        r'tools\.mcp__obsidian_wiki__obsidian_wiki_read_notes_by_wiki_ids\((\{.*?\})\)',
        child_tool_code,
        re.DOTALL,
    )
]
assert len(read_calls) == 1
assert '"project/runtime"' in read_calls[0]
assert '"project/stable"' not in read_calls[0]
assert 'wikiIds:["runtime"' not in read_calls[0]

for call in parent_calls + [(0, call) for call in child_calls]:
    payload = call[1]
    tool_text = str(payload.get('name') or '') + '\n' + str(payload.get('input') or payload.get('arguments') or '')
    lowered = tool_text.lower()
    for forbidden in (
        'obsidian_wiki_propose_note_change',
        'obsidian_wiki_apply_note_change',
        'wiki_candidate_journal',
        'git commit',
        'git push',
    ):
        assert forbidden not in lowered
PY

export ACCEPTANCE_TERMINAL_LOG="$CONSOLIDATION_TERMINAL_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=1
export ACCEPTANCE_PROMPT='Invoke $grill-adapter:wiki-maintenance consolidation issue-33 with asOf 2026-08-01T12:00:00Z and candidateLimit 20. Follow the installed skill exactly: spawn with fork_turns none and embed the complete role file contents verbatim in the spawn message, use a 300000 millisecond wait_agent timeout, and use only another wait_agent after any timeout. Do not implement or modify product code. Return only the validator compact summary.'
run_codex_acceptance

CONSOLIDATION_REPORT="$PROJECT/.grill-adapter/context/issue-33/wiki-maintenance-consolidation.json"
[[ -f "$CONSOLIDATION_REPORT" ]] || {
  printf 'installed consolidation did not create its report\n' >&2
  exit 1
}
OBSIDIAN_WIKI_CONFIG="$REGISTRY" \
OBSIDIAN_WIKI_OBSIDIAN_CLI="$OBSIDIAN_CLI" \
FAKE_OBSIDIAN_VAULT_ROOT="$VAULT" \
  python3 "$ROOT/scripts/wiki_maintenance_consolidation_report.py" validate \
    "$CONSOLIDATION_REPORT" --project-root "$PROJECT" >/dev/null

for marker in "$EQUIVALENT_MARKER" "$CONTRADICTORY_MARKER" "$INDEPENDENT_MARKER"; do
  if grep -Fq "$marker" "$CONSOLIDATION_REPORT" \
    || grep -Fq "$marker" "$CONSOLIDATION_TERMINAL_LOG"; then
    printf 'private candidate prose escaped the maintenance agent\n' >&2
    exit 1
  fi
done

INSTALLED_VALIDATOR="$(find "$CODEX_SANDBOX_HOME/plugins/cache/grill-adapter/grill-adapter" \
  -path '*/scripts/wiki_maintenance_consolidation_report.py' -type f -print -quit)"
[[ -n "$INSTALLED_VALIDATOR" ]] || { printf 'installed consolidation validator not found\n' >&2; exit 1; }
REPORT_DIGEST_BEFORE="$(shasum -a 256 "$CONSOLIDATION_REPORT" | awk '{print $1}')"
RACING_JOURNAL="$PROJECT/.grill-adapter/context/retry-a/wiki-candidates.jsonl"
cp "$RACING_JOURNAL" "$SANDBOX/retry-a-before.jsonl"
printf '%s\n' '{"schemaVersion":1,"eventType":"candidate","eventId":"event-race","featureSlug":"retry-a","recordedAt":"2026-08-01T12:01:00Z","candidateId":"candidate-race","stage":"implementation","candidateType":"wiki_note","kind":"decision","claim":"A concurrent candidate must invalidate the snapshot.","why":"Acceptance drift fixture.","sourceRefs":["tests/race"]}' >> "$RACING_JOURNAL"
if OBSIDIAN_WIKI_CONFIG="$REGISTRY" \
  OBSIDIAN_WIKI_OBSIDIAN_CLI="$OBSIDIAN_CLI" \
  FAKE_OBSIDIAN_VAULT_ROOT="$VAULT" \
  python3 "$INSTALLED_VALIDATOR" write \
    --output .grill-adapter/context/issue-33/wiki-maintenance-consolidation.json \
    --expected-as-of 2026-08-01T12:00:00Z \
    --expected-candidate-limit 20 \
    --project-root "$PROJECT" < "$CONSOLIDATION_REPORT" >/dev/null 2>&1; then
  printf 'installed validator accepted a drifting journal\n' >&2
  exit 1
fi
cp "$SANDBOX/retry-a-before.jsonl" "$RACING_JOURNAL"
[[ "$(shasum -a 256 "$CONSOLIDATION_REPORT" | awk '{print $1}')" == "$REPORT_DIGEST_BEFORE" ]] || {
  printf 'failed consolidation validation replaced the previous report\n' >&2
  exit 1
}

[[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$PROJECT_HEAD" ]]
[[ "$(git -C "$VAULT" rev-parse HEAD)" == "$VAULT_HEAD" ]]
git -C "$PROJECT" diff --quiet
git -C "$VAULT" diff --quiet
[[ -z "$(git -C "$VAULT" status --porcelain --untracked-files=all)" ]]
project_status="$(git -C "$PROJECT" status --porcelain --untracked-files=all)"
expected_status=$'?? .grill-adapter/context/issue-32/wiki-maintenance-audit.json\n?? .grill-adapter/context/issue-33/wiki-maintenance-consolidation.json'
[[ "$project_status" == "$expected_status" ]] || {
  printf 'maintenance consolidation changed unexpected project files:\n%s\n' "$project_status" >&2
  exit 1
}

python3 - "$CONSOLIDATION_REPORT" "$CODEX_SANDBOX_HOME/sessions" \
  "$CONSOLIDATION_TERMINAL_LOG" "$EQUIVALENT_MARKER" "$CONTRADICTORY_MARKER" \
  "$INDEPENDENT_MARKER" <<'PY'
import json
import pathlib
import sys

(
    report_path,
    sessions_path,
    terminal_log_path,
    equivalent_marker,
    contradictory_marker,
    independent_marker,
) = sys.argv[1:]
report = json.load(open(report_path, encoding='utf-8'))
assert report['kind'] == 'grill-adapter.wiki-maintenance-report'
assert report['mode'] == 'consolidation'
assert report['authoritative'] is False
assert report['status'] == 'ok'
assert report['asOf'] == '2026-08-01T12:00:00Z'
assert report['limits'] == {'candidateLimit': 20}


def identity_set(values):
    return {(value['featureSlug'], value['candidateId']) for value in values}


groups = {group['relationship']: group for group in report['proposalGroups']}
assert set(groups) == {'equivalent', 'contradictory'}
assert identity_set(groups['equivalent']['candidateIdentities']) == {
    ('retry-a', 'candidate-a'),
    ('retry-b', 'candidate-b'),
}
assert groups['equivalent']['recommendedAction'] == 'capture-replacement'
assert identity_set(groups['contradictory']['candidateIdentities']) == {
    ('cache-policy', 'candidate-c'),
    ('cache-recovery', 'candidate-d'),
}
assert groups['contradictory']['recommendedAction'] == 'request-user-decision'
assert identity_set(report['independentCandidateIdentities']) == {
    ('cache-startup', 'candidate-e'),
}
assert report['unresolvedCandidateIdentities'] == []

expected_summary = {
    'status': 'ok',
    'mode': 'consolidation',
    'reportPath': '.grill-adapter/context/issue-33/wiki-maintenance-consolidation.json',
    'counts': {
        'sources': report['scanned']['sources'],
        'featureJournals': report['scanned']['featureJournals'],
        'candidates': report['scanned']['candidates'],
        'proposalGroups': len(report['proposalGroups']),
        'independentCandidates': len(report['independentCandidateIdentities']),
        'unresolvedCandidates': len(report['unresolvedCandidateIdentities']),
    },
    'groupCounts': {'contradictory': 1, 'equivalent': 1},
    'caveats': [],
}


def load_rollout(path):
    events = [json.loads(line) for line in path.open(encoding='utf-8') if line.strip()]
    assert events and events[0]['type'] == 'session_meta', path
    return events[0]['payload'], events


rollouts = [load_rollout(path) for path in pathlib.Path(sessions_path).rglob('rollout-*.jsonl')]
parents = [item for item in rollouts if item[0].get('thread_source') == 'user']
children = [item for item in rollouts if item[0].get('thread_source') == 'subagent']
assert len(parents) == 2, [item[0].get('id') for item in parents]
assert len(children) == 2, [item[0].get('id') for item in children]


def completion(events):
    values = [
        event['payload'] for event in events
        if event.get('type') == 'event_msg'
        and event.get('payload', {}).get('type') == 'task_complete'
    ]
    assert len(values) == 1
    return json.loads(values[0]['last_agent_message'])


matches = [(meta, events) for meta, events in parents if completion(events).get('mode') == 'consolidation']
assert len(matches) == 1
parent_meta, parent_events = matches[0]
assert completion(parent_events) == expected_summary
child_matches = [item for item in children if item[0].get('parent_thread_id') == parent_meta['id']]
assert len(child_matches) == 1
child_meta, child_events = child_matches[0]
child_path = child_meta['agent_path']

parent_text = '\n'.join(json.dumps(event, ensure_ascii=False) for event in parent_events)
terminal_text = pathlib.Path(terminal_log_path).read_text(encoding='utf-8')
for marker in (equivalent_marker, contradictory_marker, independent_marker):
    assert marker not in parent_text
    assert marker not in terminal_text

parent_calls = [
    (index, event['payload']) for index, event in enumerate(parent_events)
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') in {'function_call', 'custom_tool_call'}
]
spawn_calls = [(index, call) for index, call in parent_calls if call.get('name') == 'spawn_agent']
wait_calls = [(index, call) for index, call in parent_calls if call.get('name') == 'wait_agent']
assert len(spawn_calls) == 1
assert wait_calls and all(index > spawn_calls[0][0] for index, _ in wait_calls)
assert parent_calls[parent_calls.index(spawn_calls[0]) + 1][1]['name'] == 'wait_agent'

spawn_call_id = spawn_calls[0][1]['call_id']
spawn_outputs = [
    event['payload'] for event in parent_events
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') == 'function_call_output'
    and event['payload'].get('call_id') == spawn_call_id
]
assert len(spawn_outputs) == 1
assert json.loads(spawn_outputs[0]['output'])['task_name'] == child_path
terminal_child_messages = [
    event['payload'] for event in parent_events
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') == 'agent_message'
    and event['payload'].get('author') == child_path
]
assert len(terminal_child_messages) == 1

child_calls = [
    event['payload'] for event in child_events
    if event.get('type') == 'response_item'
    and event.get('payload', {}).get('type') in {'function_call', 'custom_tool_call'}
]
child_tool_code = '\n'.join(
    str(call.get('name') or '') + '\n' + str(call.get('input') or call.get('arguments') or '')
    for call in child_calls
)
assert child_tool_code.count('obsidian_wiki_consolidation_candidates') == 1
for forbidden in (
    'obsidian_wiki_maintenance_summary',
    'obsidian_wiki_read_notes_by_wiki_ids',
    'obsidian_wiki_propose_note_change',
    'obsidian_wiki_apply_note_change',
    'wiki_candidate_journal',
    'git commit',
    'git push',
):
    assert forbidden not in child_tool_code.lower()
PY

printf 'codex maintenance installed acceptance OK\n'
