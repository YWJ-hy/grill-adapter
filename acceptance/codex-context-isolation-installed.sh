#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
MODE="${2:-run}"

print_contract() {
  python3 - <<'PY'
import json

print(json.dumps({
    "schemaVersion": 1,
    "kind": "grill-adapter.codex-context-isolation-acceptance",
    "installedHost": "grill",
    "hostStages": [
        "grill-with-docs",
        "to-spec",
        "to-tickets",
        "implement",
        "code-review",
        "diagnosing-bugs",
    ],
    "workflowStages": [
        "discovery-planning",
        "task-readiness",
        "direct-implementation",
        "agent-implementation",
        "code-review",
        "capture",
        "maintenance-audit",
        "maintenance-consolidation",
    ],
    "roleContracts": [
        "researcher-child-side-loader",
        "implementer",
        "reviewer-standards",
        "reviewer-spec",
        "main-session-direct-implementation",
    ],
    "failurePaths": [
        "researcher-dispatch",
        "researcher-role-load",
        "maintenance-dispatch",
        "researcher-malformed-output",
        "maintenance-stale-report",
        "binding-drift",
        "host-fail-open",
    ],
    "isolationChecks": [
        "unselected-note-body",
        "expired-note-body",
        "catalog-inventory",
        "journal-transcript",
        "agent-reasoning",
        "parent-transcript-inheritance",
        "researcher-role-private-in-coordinator",
        "researcher-role-loaded-by-child",
        "role-contract-mismatch",
        "proposal-side-effects",
    ],
    "evaluationMetrics": [
        "hardConstraintMisses",
        "irrelevantSelections",
        "expiredInjections",
        "correctionRecurrences",
        "noteBodyReads",
        "endToEndLatencyMs",
    ],
}, separators=(",", ":")))
PY
}

if [[ "$MODE" == "--contract-check" ]]; then
  print_contract
  exit 0
fi

if [[ "$MODE" != "run" ]]; then
  printf 'usage: %s [grill-adapter-root] [--contract-check]\n' "$0" >&2
  exit 2
fi

if [[ "${GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE:-}" != "1" ]]; then
  printf 'codex context isolation installed acceptance SKIP (set GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1)\n'
  exit 0
fi

CODEX_BIN="${GRILL_ADAPTER_CODEX_BIN:-}"
CODEX_MODEL="${GRILL_ADAPTER_CODEX_MODEL:-}"
CODEX_ACCEPTANCE_TIMEOUT_SECONDS="${GRILL_ADAPTER_CODEX_ACCEPTANCE_TIMEOUT_SECONDS:-900}"
CODEX_CAPTURE_TIMEOUT_SECONDS="${GRILL_ADAPTER_CODEX_CAPTURE_TIMEOUT_SECONDS:-240}"
CODEX_CAPTURE_MCP_STALL_SECONDS="${GRILL_ADAPTER_CODEX_CAPTURE_MCP_STALL_SECONDS:-45}"
for timeout_value in \
  "$CODEX_ACCEPTANCE_TIMEOUT_SECONDS" \
  "$CODEX_CAPTURE_TIMEOUT_SECONDS" \
  "$CODEX_CAPTURE_MCP_STALL_SECONDS"; do
  [[ "$timeout_value" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Codex acceptance timeouts must be positive integer seconds: %s\n' "$timeout_value" >&2
    exit 2
  }
done
if [[ -z "$CODEX_BIN" && -x "${HOME}/.npm-global/bin/codex" ]]; then
  CODEX_BIN="${HOME}/.npm-global/bin/codex"
elif [[ -z "$CODEX_BIN" ]]; then
  CODEX_BIN="$(command -v codex || true)"
fi
[[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]] || {
  printf 'working Codex CLI not found; set GRILL_ADAPTER_CODEX_BIN\n' >&2
  exit 1
}
command -v expect >/dev/null || {
  printf 'expect is required for interactive Codex acceptance\n' >&2
  exit 1
}

SANDBOX="$(mktemp -d)"
cleanup() {
  status="$?"
  if [[ "$status" == "0" ]]; then
    rm -rf "$SANDBOX"
  else
    printf 'context isolation acceptance sandbox preserved: %s\n' "$SANDBOX" >&2
  fi
}
trap cleanup EXIT

PROJECT="$SANDBOX/project"
VAULT="$SANDBOX/vault"
CODEX_SANDBOX_HOME="$SANDBOX/codex-home"
REGISTRY="$SANDBOX/obsidian-wiki.json"
OUTBOX_ROOT="$SANDBOX/outbox"
OBSIDIAN_CLI="$SANDBOX/obsidian"
OBSIDIAN_READ_LOG="$SANDBOX/obsidian-reads.log"
REPORT_OUTPUT="${GRILL_ADAPTER_CODEX_ACCEPTANCE_REPORT:-${TMPDIR:-/tmp}/grill-adapter-codex-context-isolation-evaluation.json}"
CONTEXT_DIR="$PROJECT/.grill-adapter/context/issue-35"
SELECTION="$CONTEXT_DIR/obsidian-wiki-selection.json"
CONTEXT="$CONTEXT_DIR/wiki-context.json"
ROSTER="$CONTEXT_DIR/ticket-roster.json"
RECEIPT="$CONTEXT_DIR/wiki-readiness.json"
IMPLEMENT_SNAPSHOT="$CONTEXT_DIR/manual.wiki-implement.md"
REVIEW_SNAPSHOT="$CONTEXT_DIR/manual.wiki-review.md"
REVIEW_HANDOFF="$CONTEXT_DIR/manual.wiki-review-handoff.md"
TASK_BRIEF="$PROJECT/task-brief.md"
DISCOVERY_LOG="$SANDBOX/codex-discovery.log"
SPEC_LOG="$SANDBOX/codex-spec.log"
RESEARCH_LOG="$SANDBOX/codex-research.log"
MALFORMED_RESEARCH_LOG="$SANDBOX/codex-malformed-research.log"
READINESS_LOG="$SANDBOX/codex-readiness.log"
DIRECT_IMPLEMENT_LOG="$SANDBOX/codex-direct-implement.log"
IMPLEMENT_LOG="$SANDBOX/codex-agent-implement.log"
REVIEW_LOG="$SANDBOX/codex-review.log"
CAPTURE_LOG="$SANDBOX/codex-capture.log"
DEBUG_LOG="$SANDBOX/codex-debug.log"
RESEARCH_DISPATCH_FAILURE_LOG="$SANDBOX/codex-research-dispatch-failure.log"
ROLE_LOAD_FAILURE_LOG="$SANDBOX/codex-research-role-load-failure.log"
HOST_FAIL_OPEN_LOG="$SANDBOX/codex-host-fail-open.log"
MAINTENANCE_DISPATCH_FAILURE_LOG="$SANDBOX/codex-maintenance-dispatch-failure.log"

SELECTED_MARKER='ISSUE_35_SELECTED_HARD_CONSTRAINT'
UNSELECTED_MARKER='ISSUE_35_UNSELECTED_NOTE_BODY_MUST_NOT_ESCAPE'
EXPIRED_MARKER='ISSUE_35_EXPIRED_NOTE_BODY_MUST_NOT_ESCAPE'
CATALOG_MARKER='ISSUE_35_CATALOG_INVENTORY_MUST_NOT_ESCAPE'
CORRECTION_MARKER='ISSUE_35_CORRECTION_CONSTRAINT'

snapshot_tree() {
  local root="$1"
  local ignored_relative="${2:-}"
  if [[ ! -e "$root" ]]; then
    printf '<absent>\n'
    return
  fi

  (
    cd "$root"
    if [[ -n "$ignored_relative" ]]; then
      find . -path './.git' -prune -o -path "$ignored_relative" -prune -o -print
    else
      find . -path './.git' -prune -o -print
    fi | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then
        printf 'symlink %s %s\n' "$path" "$(readlink "$path")"
      elif [[ -d "$path" ]]; then
        printf 'directory %s\n' "$path"
      elif [[ -f "$path" ]]; then
        printf 'file %s ' "$path"
        shasum -a 256 "$path"
      else
        printf 'other %s\n' "$path"
      fi
    done
  )
}

snapshot_repository_state() {
  local root="$1"
  local ignored_relative="${2:-}"
  local ignored_path="${ignored_relative#./}"

  snapshot_tree "$root" "$ignored_relative"
  printf '%s\n' '-- git status --'
  git -C "$root" status --porcelain=v1 --untracked-files=all | while IFS= read -r line; do
    if [[ -n "$ignored_path" && "$line" == *" $ignored_path" ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done
  printf '%s\n' '-- git diff --'
  git -C "$root" diff --binary
  printf '%s\n' '-- git cached diff --'
  git -C "$root" diff --cached --binary
}

mkdir -p \
  "$CONTEXT_DIR" \
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

cat > "$VAULT/Projects/example/Formatter.md" <<'EOF'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project/formatter
type: constraint
status: active
agent_visible: true
summary: Formatter output must use square brackets
constraint_strength: hard
verified_at: 2026-07-01T00:00:00Z
review_after: 2026-12-01T00:00:00Z
expires_at: 2027-01-01T00:00:00Z
---

# Formatter

ISSUE_35_SELECTED_HARD_CONSTRAINT

ISSUE_35_CORRECTION_CONSTRAINT

Every formatter entry point must emit exactly one value wrapped in square brackets, followed by one
newline. Angle-bracket output was previously rejected and must not recur.
EOF

cat > "$VAULT/Projects/example/Deployment.md" <<'EOF'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project/deployment
type: constraint
status: active
agent_visible: true
summary: ISSUE_35_CATALOG_INVENTORY_MUST_NOT_ESCAPE
constraint_strength: hard
verified_at: 2026-07-01T00:00:00Z
review_after: 2026-12-01T00:00:00Z
expires_at: 2027-01-01T00:00:00Z
---

# Deployment

ISSUE_35_UNSELECTED_NOTE_BODY_MUST_NOT_ESCAPE

Deployment packaging uses an unrelated archive convention.
EOF

cat > "$VAULT/Projects/example/Expired.md" <<'EOF'
---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: project/expired-formatter
type: constraint
status: active
agent_visible: true
summary: Historical formatter guidance
constraint_strength: hard
verified_at: 2026-01-01T00:00:00Z
review_after: 2026-02-01T00:00:00Z
expires_at: 2026-07-31T00:00:00Z
---

# Historical formatter

ISSUE_35_EXPIRED_NOTE_BODY_MUST_NOT_ESCAPE

The obsolete formatter used angle brackets.
EOF

cat > "$TASK_BRIEF" <<'EOF'
Implement `format-value.sh` in the main session and `format-value-agent.sh` in an isolated implementer.
Each accepts exactly one positional value and writes the formatted value to stdout. Keep both changes
local to the formatter and make `./test-format.sh` plus `./test-format-agent.sh` pass.
EOF

cat > "$PROJECT/test-format.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

actual="$(./format-value.sh sample)"
[[ "$actual" == '[sample]' ]] || {
  printf 'unexpected formatter output: %s\n' "$actual" >&2
  exit 1
}
if ./format-value.sh >/dev/null 2>&1 || ./format-value.sh first second >/dev/null 2>&1; then
  printf 'formatter accepted an argument count other than one\n' >&2
  exit 1
fi
EOF
chmod +x "$PROJECT/test-format.sh"

cat > "$PROJECT/test-format-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

actual="$(./format-value-agent.sh sample)"
[[ "$actual" == '[sample]' ]] || {
  printf 'unexpected agent formatter output: %s\n' "$actual" >&2
  exit 1
}
if ./format-value-agent.sh >/dev/null 2>&1 \
  || ./format-value-agent.sh first second >/dev/null 2>&1; then
  printf 'agent formatter accepted an argument count other than one\n' >&2
  exit 1
fi
EOF
chmod +x "$PROJECT/test-format-agent.sh"

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
          "access": {"read": true, "update": "confirm"}
        }
      ]
    },
    "roots": {
      "project": {
        "updateAuthorization": {
          "updateExistingPage": "skip",
          "createNewDocument": "ask"
        }
      },
      "shared": {
        "updateAuthorization": {
          "updateExistingPage": "skip",
          "createNewDocument": "ask"
        },
        "sharedNeutrality": {
          "blockedTerms": [],
          "blockedPatterns": []
        }
      }
    }
  },
  "sourceOfTruth": {
    "heuristics": false,
    "sources": [
      {
        "paths": ["generated/**"],
        "role": "truth",
        "edit": "never"
      }
    ]
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
  [[ "$argument" == "search" ]] && operation='search'
  [[ "$argument" == "read" ]] && operation='read'
  [[ "$argument" == path=* ]] && note_path="${argument#path=}"
done
if [[ "$operation" == 'search' ]]; then
  printf '["Projects/example/Deployment.md","Projects/example/Expired.md","Projects/example/Formatter.md"]\n'
  exit 0
fi
[[ "$operation" == 'read' && -n "$note_path" ]] || exit 2
[[ "$note_path" != /* && "$note_path" != *'..'* ]] || exit 2
printf '%s\n' "$note_path" >> "$FAKE_OBSIDIAN_READ_LOG"
cat "$FAKE_OBSIDIAN_VAULT_ROOT/$note_path"
EOF
chmod +x "$OBSIDIAN_CLI"
: > "$OBSIDIAN_READ_LOG"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Acceptance Test'
git -C "$PROJECT" config user.email 'acceptance@example.invalid'
git -C "$VAULT" init -q --initial-branch=main
git -C "$VAULT" config user.name 'Acceptance Test'
git -C "$VAULT" config user.email 'acceptance@example.invalid'
git -C "$VAULT" remote add origin https://github.com/acme/knowledge.git
git -C "$VAULT" add .
git -C "$VAULT" commit -qm fixture

"$ROOT/manage.sh" install "$PROJECT" --host grill --runtime codex >/dev/null
grep -Fq '<!-- grill-adapter:host:grill:start -->' "$PROJECT/AGENTS.md" || {
  printf 'installed Codex grill host block is missing\n' >&2
  exit 1
}
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm fixture
PROJECT_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
VAULT_HEAD="$(git -C "$VAULT" rev-parse HEAD)"

SOURCE_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
MATTPOCOCK_SKILLS_ROOT="${GRILL_ADAPTER_MATTPOCOCK_SKILLS_ROOT:-}"
is_plugin_root() {
  [[ -f "$1/.claude-plugin/plugin.json" || -f "$1/.codex-plugin/plugin.json" ]]
}
if [[ -z "$MATTPOCOCK_SKILLS_ROOT" ]]; then
  for codex_home in "$SOURCE_CODEX_HOME" "${HOME}/.codex"; do
    for candidate in "$codex_home"/plugins/cache/mattpocock/mattpocock-skills/*; do
      is_plugin_root "$candidate" || continue
      MATTPOCOCK_SKILLS_ROOT="$candidate"
    done
  done
fi
if [[ -z "$MATTPOCOCK_SKILLS_ROOT" ]]; then
  MATTPOCOCK_SKILLS_ROOT="$(
    CODEX_HOME="$SOURCE_CODEX_HOME" "$CODEX_BIN" plugin marketplace list --json \
      | python3 -c '
import json
import sys

for marketplace in json.load(sys.stdin).get("marketplaces", []):
    if marketplace.get("name") == "mattpocock" and isinstance(marketplace.get("root"), str):
        print(marketplace["root"])
        break
'
  )"
fi
[[ -n "$MATTPOCOCK_SKILLS_ROOT" ]] && is_plugin_root "$MATTPOCOCK_SKILLS_ROOT" || {
  printf 'mattpocock-skills plugin source not found; set GRILL_ADAPTER_MATTPOCOCK_SKILLS_ROOT\n' >&2
  exit 1
}
if [[ -f "$SOURCE_CODEX_HOME/auth.json" ]]; then
  cp "$SOURCE_CODEX_HOME/auth.json" "$CODEX_SANDBOX_HOME/auth.json"
fi
[[ -f "$CODEX_SANDBOX_HOME/auth.json" ]] || {
  printf 'Codex authentication not found at %s/auth.json\n' "$SOURCE_CODEX_HOME" >&2
  exit 1
}
MODEL="$CODEX_MODEL"
MODEL_PROVIDER=''
if [[ -f "$SOURCE_CODEX_HOME/config.toml" ]]; then
  if [[ -z "$MODEL" ]]; then
    MODEL="$(sed -nE 's/^model[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$SOURCE_CODEX_HOME/config.toml" | head -1)"
  fi
  MODEL_PROVIDER="$(sed -nE 's/^model_provider[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$SOURCE_CODEX_HOME/config.toml" | head -1)"
  awk -v provider_section="[model_providers.${MODEL_PROVIDER}]" '
    /^\[/ { in_provider = ($0 == provider_section) }
    in_provider { print; next }
    /^(model_provider|model|disable_response_storage|model_reasoning_effort|service_tier)[[:space:]]*=/ { print }
  ' "$SOURCE_CODEX_HOME/config.toml" > "$CODEX_SANDBOX_HOME/config.toml"
fi
export CODEX_HOME="$CODEX_SANDBOX_HOME"
"$CODEX_BIN" plugin marketplace add "$ROOT" --json >/dev/null
"$CODEX_BIN" plugin add grill-adapter@grill-adapter --json >/dev/null
"$CODEX_BIN" plugin marketplace add "$MATTPOCOCK_SKILLS_ROOT" --json >/dev/null
"$CODEX_BIN" plugin add mattpocock-skills@mattpocock --json >/dev/null

PLUGIN_ROOT="$(find "$CODEX_SANDBOX_HOME/plugins/cache/grill-adapter/grill-adapter" \
  -path '*/.codex-plugin/plugin.json' -type f -print -quit | xargs dirname | xargs dirname)"
[[ -n "$PLUGIN_ROOT" && -d "$PLUGIN_ROOT" ]] || {
  printf 'installed grill-adapter plugin root not found\n' >&2
  exit 1
}
MCP_BUNDLE="$PLUGIN_ROOT/mcp/obsidian-wiki/dist/index.js"
INSTALLED_RENDER="$PLUGIN_ROOT/scripts/wiki_context_render.py"
INSTALLED_READINESS="$PLUGIN_ROOT/scripts/wiki_readiness.py"
INSTALLED_ROLE_LOADER="$PLUGIN_ROOT/scripts/child_role_loader.py"
INSTALLED_RESEARCHER_ROLE="$PLUGIN_ROOT/agents/wiki-researcher.md"
for installed_file in "$MCP_BUNDLE" "$INSTALLED_RENDER" "$INSTALLED_READINESS" \
  "$INSTALLED_ROLE_LOADER" "$INSTALLED_RESEARCHER_ROLE"; do
  [[ -f "$installed_file" ]] || {
    printf 'installed acceptance dependency missing: %s\n' "$installed_file" >&2
    exit 1
  }
done

export ACCEPTANCE_CODEX_BIN="$CODEX_BIN"
export ACCEPTANCE_CODEX_MODEL="$CODEX_MODEL"
export ACCEPTANCE_PROJECT="$PROJECT"
export ACCEPTANCE_MCP_BUNDLE="$MCP_BUNDLE"
export ACCEPTANCE_REGISTRY="$REGISTRY"
export ACCEPTANCE_OBSIDIAN_CLI="$OBSIDIAN_CLI"
export ACCEPTANCE_VAULT="$VAULT"
export ACCEPTANCE_READ_LOG="$OBSIDIAN_READ_LOG"
export ACCEPTANCE_SESSIONS="$CODEX_SANDBOX_HOME/sessions"
export ACCEPTANCE_RUN_TIMEOUT_SECONDS="$CODEX_ACCEPTANCE_TIMEOUT_SECONDS"
export ACCEPTANCE_CAPTURE_MCP_STALL_SECONDS="$CODEX_CAPTURE_MCP_STALL_SECONDS"
export OBSIDIAN_WIKI_CONFIG="$REGISTRY"
export OBSIDIAN_WIKI_OBSIDIAN_CLI="$OBSIDIAN_CLI"
export FAKE_OBSIDIAN_VAULT_ROOT="$VAULT"
export FAKE_OBSIDIAN_READ_LOG="$OBSIDIAN_READ_LOG"

run_codex_acceptance() {
expect <<'EXPECT'
log_file -noappend $env(ACCEPTANCE_TERMINAL_LOG)
log_user 0
set env(TERM) xterm-256color
set env(COLUMNS) 120
set env(LINES) 40
set mcp_args [format {mcp_servers.obsidian-wiki.args=["%s"]} $env(ACCEPTANCE_MCP_BUNDLE)]
set mcp_env "mcp_servers.obsidian-wiki.env={OBSIDIAN_WIKI_CONFIG=\"$env(ACCEPTANCE_REGISTRY)\",OBSIDIAN_WIKI_OBSIDIAN_CLI=\"$env(ACCEPTANCE_OBSIDIAN_CLI)\",FAKE_OBSIDIAN_VAULT_ROOT=\"$env(ACCEPTANCE_VAULT)\",FAKE_OBSIDIAN_READ_LOG=\"$env(ACCEPTANCE_READ_LOG)\"}"
set project_trust [format {projects."%s".trust_level="trusted"} $env(ACCEPTANCE_PROJECT)]
set model_args {}
if {[info exists env(ACCEPTANCE_CODEX_MODEL)] && $env(ACCEPTANCE_CODEX_MODEL) ne ""} {
  lappend model_args --model $env(ACCEPTANCE_CODEX_MODEL)
}
set feature_args {}
if {[info exists env(ACCEPTANCE_DISABLE_MULTI_AGENT)] && $env(ACCEPTANCE_DISABLE_MULTI_AGENT) == "1"} {
  lappend feature_args --disable multi_agent
}
set capture_approval_args {}
if {[info exists env(ACCEPTANCE_AUTO_APPROVE_CAPTURE)] && $env(ACCEPTANCE_AUTO_APPROVE_CAPTURE) == "1"} {
  lappend capture_approval_args -c {mcp_servers.obsidian-wiki.tools.obsidian_wiki_stage_capture_plan.approval_mode="approve"}
}

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

proc capture_stage_pending {} {
  global env
  foreach rollout [glob -nocomplain [file join $env(ACCEPTANCE_SESSIONS) * * * rollout-*.jsonl]] {
    set handle [open $rollout r]
    set pending 0
    while {[gets $handle line] >= 0} {
      if {[regexp {"type":"custom_tool_call".*"input":.*obsidian_wiki_stage_capture_plan} $line]} {
        set pending 1
      }
      if {[regexp {"type":"mcp_tool_call_end".*"tool":"obsidian_wiki_stage_capture_plan"} $line]} {
        set pending 0
      }
    }
    close $handle
    if {$pending} {
      return 1
    }
  }
  return 0
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
  {*}$capture_approval_args \
  {*}$model_args \
  {*}$feature_args \
  $env(ACCEPTANCE_PROMPT)
catch {exec stty rows 40 columns 120 < $spawn_out(slave,name)}
catch {exec kill -WINCH [exp_pid]}

set deadline [expr {[clock seconds] + $env(ACCEPTANCE_RUN_TIMEOUT_SECONDS)}]
set finished 0
set child_closed 0
set capture_pending_since 0
while {[clock seconds] < $deadline} {
  set timeout 1
  expect {
    -re {\x1b\[6n} { send -- "\033\[1;1R" }
    -re {\x1b\]10;\?\x1b\\} { send -- "\033\]10;rgb:ffff/ffff/ffff\033\\" }
    -re {\x1b\]11;\?\x1b\\} { send -- "\033\]11;rgb:0000/0000/0000\033\\" }
    -re {\x1b\[\?u} { send -- "\033\[?0u" }
    -re {\x1b\[c} { send -- "\033\[?1;2c" }
    -re {Continue anyway.*\[y/N\]} { send -- "y\r" }
    -re {Yes, continue} { send -- "\r" }
    -re {Approaching rate limits} { send -- "\033\[B\033\[B\r" }
    eof {
      set child_closed 1
      if {[parent_complete]} {
        set finished 1
      }
      if {!$finished} {
        exit 1
      }
    }
    timeout {}
  }
  if {[parent_complete]} {
    set finished 1
    break
  }
  if {[info exists env(ACCEPTANCE_MONITOR_CAPTURE_MCP)] && $env(ACCEPTANCE_MONITOR_CAPTURE_MCP) == "1"} {
    if {[capture_stage_pending]} {
      if {$capture_pending_since == 0} {
        set capture_pending_since [clock seconds]
      } elseif {[clock seconds] - $capture_pending_since >= $env(ACCEPTANCE_CAPTURE_MCP_STALL_SECONDS)} {
        puts stderr "Capture MCP staging remained unresolved for $env(ACCEPTANCE_CAPTURE_MCP_STALL_SECONDS)s; check the preserved Codex logs for a pending mcp_tool_call_approval elicitation"
        send -- "\003"
        after 800
        send -- "\003"
        exit 125
      }
    } else {
      set capture_pending_since 0
    }
  }
}
if {!$finished} {
  puts stderr "Codex acceptance stage timed out after $env(ACCEPTANCE_RUN_TIMEOUT_SECONDS)s"
  send -- "\003"
  after 800
  send -- "\003"
  exit 124
}
if {!$child_closed} {
  after 1000
  send -- "\003"
  after 800
  send -- "\003"
  expect eof
}
EXPECT
}

export ACCEPTANCE_TERMINAL_LOG="$DISCOVERY_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=0
export ACCEPTANCE_PROMPT='ISSUE39_STAGE_GRILL_WITH_DOCS. Invoke $mattpocock-skills:grill-with-docs for the already-confirmed formatter change in ./task-brief.md. This installed test exercises the host router: before any design discussion, follow the router-disclosed Wiki context for this stage. Do not call a grill-adapter skill by name, create or publish a document, modify tickets, or edit product files. The requirements are already confirmed; return once the discovery-stage work has reached its normal user-facing handoff.'
unset ACCEPTANCE_DISABLE_MULTI_AGENT
run_codex_acceptance

export ACCEPTANCE_TERMINAL_LOG="$SPEC_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=1
export ACCEPTANCE_PROMPT='ISSUE39_STAGE_TO_SPEC. Invoke $mattpocock-skills:to-spec for the already-confirmed formatter change in ./task-brief.md. This installed test exercises the host router: run the source-of-truth spec policy before drafting. Do not call a grill-adapter skill by name, create or publish an issue, modify tickets, or edit product files. Return once the spec-stage work has reached its normal user-facing handoff.'
run_codex_acceptance

export ACCEPTANCE_TERMINAL_LOG="$RESEARCH_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=2
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_RESEARCH_SUCCESS. Invoke $mattpocock-skills:to-tickets for this already-approved single-ticket plan. This is an installed integration test, so do not publish or modify tracker tickets; complete only the planning-stage preparation for featureSlug issue-35. The complete task is: Implement format-value.sh in the main session and format-value-agent.sh in an isolated implementer. Each accepts exactly one positional value and writes the formatted value to stdout. Keep both changes local to the formatter and make ./test-format.sh plus ./test-format-agent.sh pass. Return the planning result when ready.'
unset ACCEPTANCE_DISABLE_MULTI_AGENT
run_codex_acceptance

if [[ ! -f "$SELECTION" ]]; then
  python3 - "$CODEX_SANDBOX_HOME/sessions" "$CONTEXT" "$SELECTION" <<'PY'
import json
import pathlib
import sys

sessions = pathlib.Path(sys.argv[1])
context_path = pathlib.Path(sys.argv[2])
selection_path = pathlib.Path(sys.argv[3])
if context_path.is_file():
    context = json.loads(context_path.read_text(encoding="utf-8"))
    note_fields = {
        "sourceId", "role", "path", "wikiId", "type", "constraintStrength", "summary",
        "contentHash", "bindingDigest", "verifiedAt", "reviewAfter", "expiresAt",
        "adrSourceId", "adrSourcePath", "adrSourceContentHash",
    }
    skill_fields = {
        "sourceId", "role", "path", "wikiId", "type", "summary", "contentHash",
        "bindingDigest", "skillName", "skillVersion", "skillContractHash", "skillTriggers",
        "discoveryState", "requiredFor", "verifiedAt", "reviewAfter", "expiresAt",
    }
    selection = {
        "status": "ok",
        "phase": "plan",
        "snapshotHash": context["snapshotHash"],
        "wikiBindings": context["wikiBindings"],
        "wikiNotes": [
            {key: value for key, value in note.items() if key in note_fields}
            for note in context["wikiNotes"]
        ],
        "requiredSkills": [
            {key: value for key, value in skill.items() if key in skill_fields}
            for skill in context["requiredSkills"]
        ],
        "caveats": context["caveats"],
        "maintenanceWarnings": context["maintenanceWarnings"],
    }
    selection_path.parent.mkdir(parents=True, exist_ok=True)
    selection_path.write_text(json.dumps(selection, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0)

rollouts = []
for path in sessions.rglob("rollout-*.jsonl"):
    events = [json.loads(line) for line in path.open(encoding="utf-8") if line.strip()]
    if events and events[0].get("payload", {}).get("thread_source") == "subagent":
        rollouts.append(events)

terminal = []
for events in rollouts:
    for event in events:
        payload = event.get("payload", {})
        if event.get("type") == "event_msg" and payload.get("type") == "task_complete":
            try:
                result = json.loads(payload["last_agent_message"])
            except (KeyError, TypeError, json.JSONDecodeError):
                continue
            if result.get("phase") == "plan" and result.get("selectionPath") == (
                ".grill-adapter/context/issue-35/obsidian-wiki-selection.json"
            ):
                terminal.append(result)

assert len(terminal) == 1, "researcher produced neither a selection file nor one inline fallback"
selection = terminal[0].get("selection")
assert isinstance(selection, dict), "inline researcher fallback omitted the selection object"
selection_path.parent.mkdir(parents=True, exist_ok=True)
selection_path.write_text(json.dumps(selection, indent=2) + "\n", encoding="utf-8")
PY
fi

[[ -f "$SELECTION" ]] || {
  printf 'installed researcher did not write the plan selection\n' >&2
  exit 1
}

# `to-tickets` is allowed to Carry and consume the transient selection itself. The remaining
# stages exercise a separate manual task, so retain only the recovered metadata selection.
find "$CONTEXT_DIR" -maxdepth 1 -type f ! -name "$(basename "$SELECTION")" -delete

# Carry rejects malformed researcher output before it can become formal context.
MALFORMED_SELECTION="$CONTEXT_DIR/malformed-selection.json"
MALFORMED_CONTEXT="$CONTEXT_DIR/malformed-context.json"
printf '%s\n' '{"status":"ok","phase":"plan","wikiNotes":"not-an-array"}' > "$MALFORMED_SELECTION"
export ACCEPTANCE_TERMINAL_LOG="$MALFORMED_RESEARCH_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=3
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_MALFORMED_RESEARCHER_OUTPUT. Resume $grill-adapter:wiki-research immediately after a terminal researcher wrote the malformed plan selection fixture at .grill-adapter/context/issue-35/malformed-selection.json. Do not dispatch another researcher or call Wiki MCP. Run the installed Carry scaffold validation into .grill-adapter/context/issue-35/malformed-context.json with featureSlug malformed-output and ticketSource manual. Treat validator rejection as broken, leave no partial context, and return only {"acceptanceStage":"malformed-researcher-output","status":"broken","caveat":"selection-validation-failed"}.'
run_codex_acceptance
[[ ! -e "$MALFORMED_CONTEXT" ]] || {
  printf 'malformed researcher output left a partial context\n' >&2
  exit 1
}
rm "$MALFORMED_SELECTION"

# Use a disposable finalized context to prove engine-level binding drift is fail-closed. The real
# issue-35 context remains absent so the next installed Codex parent must perform Carry and freeze.
FAILURE_SELECTION="$CONTEXT_DIR/binding-drift-selection.json"
FAILURE_CONTEXT="$CONTEXT_DIR/binding-drift.wiki-context.json"
FAILURE_ROSTER="$CONTEXT_DIR/binding-drift.ticket-roster.json"
cp "$SELECTION" "$FAILURE_SELECTION"
OBSIDIAN_WIKI_CONFIG="$REGISTRY" \
OBSIDIAN_WIKI_OBSIDIAN_CLI="$OBSIDIAN_CLI" \
FAKE_OBSIDIAN_VAULT_ROOT="$VAULT" \
FAKE_OBSIDIAN_READ_LOG="$OBSIDIAN_READ_LOG" \
  python3 "$INSTALLED_RENDER" "$FAILURE_CONTEXT" \
    --scaffold "$FAILURE_SELECTION" --strict --project-root "$PROJECT" \
    --feature-slug binding-drift --ticket-source manual >/dev/null
cat > "$FAILURE_ROSTER" <<EOF
{
  "featureSlug": "binding-drift",
  "ticketSource": "manual",
  "tickets": [{"taskId":"binding-drift","taskTitle":"Binding drift fixture","text":"binding drift fixture"}]
}
EOF
python3 - "$FAILURE_CONTEXT" <<'PY'
import json
import sys

path = sys.argv[1]
context = json.load(open(path, encoding="utf-8"))
for note in context["wikiNotes"]:
    note["destination"].update({
        "kind": "task-bound",
        "reason": "Exercise binding drift before role snapshot creation.",
        "tasks": ["binding-drift"],
    })
context["taskRouting"].update({"status": "confirmed", "selectedSectionsFrozen": True})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(context, handle, indent=2)
    handle.write("\n")
PY
python3 "$INSTALLED_RENDER" "$FAILURE_CONTEXT" \
  --finalize --strict --project-root "$PROJECT" --ticket-roster "$FAILURE_ROSTER" >/dev/null

cp "$PROJECT/.grill-adapter/settings.json" "$SANDBOX/settings-before-drift.json"
python3 - "$PROJECT/.grill-adapter/settings.json" <<'PY'
import json
import sys

path = sys.argv[1]
settings = json.load(open(path, encoding="utf-8"))
settings["wiki"]["obsidian"]["bindings"][0]["root"] = "Projects/missing"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY
if OBSIDIAN_WIKI_CONFIG="$REGISTRY" \
  OBSIDIAN_WIKI_OBSIDIAN_CLI="$OBSIDIAN_CLI" \
  FAKE_OBSIDIAN_VAULT_ROOT="$VAULT" \
  FAKE_OBSIDIAN_READ_LOG="$OBSIDIAN_READ_LOG" \
  python3 "$INSTALLED_READINESS" freeze \
    --context "$FAILURE_CONTEXT" --roster "$FAILURE_ROSTER" --all --project-root "$PROJECT" \
    --obsidian-wiki-cmd "node $MCP_BUNDLE" >/dev/null 2>&1; then
  printf 'installed freeze accepted binding drift\n' >&2
  exit 1
fi
[[ ! -e "$CONTEXT_DIR/binding-drift.wiki-implement.md" \
  && ! -e "$CONTEXT_DIR/binding-drift.wiki-review.md" ]] || {
  printf 'failed binding-drift freeze left an approved role snapshot\n' >&2
  exit 1
}
cp "$SANDBOX/settings-before-drift.json" "$PROJECT/.grill-adapter/settings.json"

# Installed task readiness performs the actual Carry, routing, finalize, freeze, and Bind path.
export ACCEPTANCE_TERMINAL_LOG="$READINESS_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=4
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_TASK_READINESS. Invoke $mattpocock-skills:implement for the confirmed conversational task in ./task-brief.md. This installed test exercises the host router: before any product edit, establish task readiness for featureSlug issue-35 and taskId manual. Reuse the existing plan selection at .grill-adapter/context/issue-35/obsidian-wiki-selection.json without dispatching another researcher: prepare the manual roster from the complete brief, scaffold wiki-context.json with --keep-selection, route project/formatter as task-bound to manual, confirm routing, finalize, freeze both role contracts, and Bind the implementer contract into the main session. Do not call a grill-adapter skill by name. Return only {"acceptanceStage":"task-readiness","status":"ready"} after the receipt is ready.'
run_codex_acceptance

[[ -f "$CONTEXT" && -f "$ROSTER" && -f "$RECEIPT" \
  && -f "$IMPLEMENT_SNAPSHOT" && -f "$REVIEW_SNAPSHOT" ]] || {
  printf 'installed task readiness did not create its complete formal artifact set\n' >&2
  exit 1
}
python3 "$INSTALLED_READINESS" validate \
  --receipt "$RECEIPT" --task-id manual --project-root "$PROJECT" >/dev/null

# The direct host path must consume the same implementer contract without an implementation child.
export ACCEPTANCE_TERMINAL_LOG="$DIRECT_IMPLEMENT_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=5
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_DIRECT_IMPLEMENTATION. Validate the existing issue-35/manual readiness receipt and read the exact .grill-adapter/context/issue-35/manual.wiki-implement.md contract into this main session. Do not spawn an agent, read the reviewer snapshot, or call the live Wiki. Implement only format-value.sh and run ./test-format.sh. Return only {"acceptanceStage":"direct-implementation","status":"pass"}.'
run_codex_acceptance

[[ -x "$PROJECT/format-value.sh" ]] || {
  printf 'installed direct implementation did not create executable format-value.sh\n' >&2
  exit 1
}
(cd "$PROJECT" && ./test-format.sh)

# The isolated role path independently consumes the frozen implementer contract.
export ACCEPTANCE_TERMINAL_LOG="$IMPLEMENT_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=6
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_AGENT_IMPLEMENTATION. Validate the existing issue-35/manual readiness receipt, then read the entire .grill-adapter/context/issue-35/manual.wiki-implement.md contract into this parent main session before dispatch. Spawn exactly one implementer subagent named issue35_implementer with fork_turns none; tell it to read only ./task-brief.md, ./test-format-agent.sh, and ./.grill-adapter/context/issue-35/manual.wiki-implement.md as task inputs, implement only format-value-agent.sh, and run ./test-format-agent.sh. Immediately wait on only that exact child until terminal. Do not read the reviewer snapshot or live Wiki. Return only {"acceptanceStage":"agent-implementation","status":"pass","childStatus":"completed"}.'
run_codex_acceptance

[[ -x "$PROJECT/format-value-agent.sh" ]] || {
  printf 'installed implementer child did not create executable format-value-agent.sh\n' >&2
  exit 1
}
(cd "$PROJECT" && ./test-format-agent.sh)

export ACCEPTANCE_TERMINAL_LOG="$REVIEW_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=7
REVIEW_ROUTER_PRODUCT_BEFORE="$(snapshot_repository_state "$PROJECT" "./.grill-adapter/context/issue-35/manual.wiki-review-handoff.md")"
REVIEW_ROUTER_VAULT_BEFORE="$(snapshot_repository_state "$VAULT")"
REVIEW_ROUTER_OUTBOX_BEFORE="$(snapshot_tree "$OUTBOX_ROOT")"
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_CODE_REVIEW. Invoke $mattpocock-skills:code-review since HEAD for the current task manual after implementation. This installed test exercises the host router: prepare reviewer context before spawning reviewers, then after an accepted review run the post-review Capture route for feature issue-35. Do not call a grill-adapter skill by name. Create .grill-adapter/context/issue-35/manual.wiki-review-handoff.md from the existing receipt before spawning reviewers. Then spawn exactly two subagents in parallel: task_name standards_review for Standards and task_name spec_review for Spec, both with fork_turns none. Each must read that same handoff file plus the git diff; the Spec reviewer must also read the exact project-root path ./task-brief.md. Neither may read manual.wiki-implement.md, the live Wiki, or any other task contract. This formatter-only fixture has no durable candidate, so the required post-review Capture route must still run its single isolated child, named issue35_capture, and leave product and Vault state unchanged. Wait for every exact child. Return only {"acceptanceStage":"code-review","status":"pass","standardsCompleted":true,"specCompleted":true,"captureStatus":"skipped"}.'
export ACCEPTANCE_AUTO_APPROVE_CAPTURE=1
run_codex_acceptance
unset ACCEPTANCE_AUTO_APPROVE_CAPTURE

[[ -f "$REVIEW_HANDOFF" ]] || {
  printf 'installed code-review stage did not create the reviewer handoff\n' >&2
  exit 1
}
grep -Fq 'Status: ready' "$REVIEW_HANDOFF" || {
  printf 'installed reviewer handoff was not ready\n' >&2
  exit 1
}
[[ "$(snapshot_repository_state "$PROJECT" "./.grill-adapter/context/issue-35/manual.wiki-review-handoff.md")" == "$REVIEW_ROUTER_PRODUCT_BEFORE" ]] || {
  printf 'router-driven review Capture changed project state beyond its reviewer handoff\n' >&2
  exit 1
}
[[ "$(snapshot_repository_state "$VAULT")" == "$REVIEW_ROUTER_VAULT_BEFORE" ]] || {
  printf 'router-driven review Capture changed the Vault\n' >&2
  exit 1
}
[[ "$(snapshot_tree "$OUTBOX_ROOT")" == "$REVIEW_ROUTER_OUTBOX_BEFORE" ]] || {
  printf 'router-driven review Capture changed the Outbox despite no durable candidate\n' >&2
  exit 1
}

CAPTURE_PRODUCT_BEFORE="$(snapshot_repository_state "$PROJECT")"
CAPTURE_VAULT_BEFORE="$(snapshot_repository_state "$VAULT")"
CAPTURE_OUTBOX_BEFORE="$(snapshot_tree "$OUTBOX_ROOT")"
export ACCEPTANCE_TERMINAL_LOG="$CAPTURE_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=8
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_CAPTURE. Invoke $grill-adapter:update-wiki for feature issue-35 after the accepted review. Apply its durable-knowledge gate. This formatter-only fixture has no candidate journal and no durable cross-project knowledge, so a no-update conclusion is expected, but it must be the installed skill own conclusion. Do not propose, apply, publish, edit the Vault, append a journal, or change product files. Return only {"acceptanceStage":"capture","status":"skipped","reason":"no-durable-candidate"}.'
export ACCEPTANCE_RUN_TIMEOUT_SECONDS="$CODEX_CAPTURE_TIMEOUT_SECONDS"
export ACCEPTANCE_AUTO_APPROVE_CAPTURE=1
export ACCEPTANCE_MONITOR_CAPTURE_MCP=1
run_codex_acceptance
export ACCEPTANCE_RUN_TIMEOUT_SECONDS="$CODEX_ACCEPTANCE_TIMEOUT_SECONDS"
unset ACCEPTANCE_AUTO_APPROVE_CAPTURE ACCEPTANCE_MONITOR_CAPTURE_MCP

[[ "$(snapshot_repository_state "$PROJECT")" == "$CAPTURE_PRODUCT_BEFORE" ]] || {
  printf 'Capture changed project state despite a no-update conclusion\n' >&2
  exit 1
}
[[ "$(snapshot_repository_state "$VAULT")" == "$CAPTURE_VAULT_BEFORE" ]] || {
  printf 'Capture changed the Vault despite a no-update conclusion\n' >&2
  exit 1
}
[[ "$(snapshot_tree "$OUTBOX_ROOT")" == "$CAPTURE_OUTBOX_BEFORE" ]] || {
  printf 'Capture changed the Outbox despite a no-update conclusion\n' >&2
  exit 1
}

# The debug branch is a separate grill stage. Its historical symptom, root cause, and verified fix
# are deliberately supplied so the router can reach both its post-cause disclosure and post-fix
# retrospective moments without reopening the product change.
export ACCEPTANCE_TERMINAL_LOG="$DEBUG_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=9
export ACCEPTANCE_PROMPT='ISSUE39_STAGE_DIAGNOSING_BUGS. Invoke $mattpocock-skills:diagnosing-bugs for the formatter regression that was already reproduced, fixed, and verified. The former symptom was angle-bracket output; the tight feedback loop is ./test-format.sh, the confirmed root cause was an implementation that used angle brackets, and the verified fix now emits square brackets. This installed test exercises the host router: after the cause is narrowed, disclose targeted Wiki context; after the verified fix, run the debugging retrospective and emit its prescribed analysis with its no-update conclusion. Do not call a grill-adapter skill by name, change product files, edit the Vault, publish anything, or create a durable candidate. Return once the debugging-stage work has reached its normal user-facing handoff.'
run_codex_acceptance

# The manifest retains the released digest while the installed role drifts. The child loader must
# reject that mismatch before it can call any Wiki tool or write a selection.
printf '\nacceptance role content drift\n' >> "$INSTALLED_RESEARCHER_ROLE"
export ACCEPTANCE_TERMINAL_LOG="$ROLE_LOAD_FAILURE_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=10
export ACCEPTANCE_PROMPT='ISSUE40_STAGE_RESEARCH_ROLE_LOAD_FAILURE. Invoke $grill-adapter:wiki-research for phase plan and featureSlug role-load-failure. The installed researcher role was changed after its trusted descriptor was shipped. The isolated child must reject the digest mismatch before any Wiki call. Do not read, reconstruct, or inline the role in the coordinator; do not create a selection or sidecar. Return only {"acceptanceStage":"research-role-load-failure","status":"broken","caveat":"role-load-failed"}.'
run_codex_acceptance
[[ ! -e "$PROJECT/.grill-adapter/context/role-load-failure/obsidian-wiki-selection.json" ]] || {
  printf 'research role-load failure wrote a selection\n' >&2
  exit 1
}

export ACCEPTANCE_TERMINAL_LOG="$RESEARCH_DISPATCH_FAILURE_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=11
export ACCEPTANCE_DISABLE_MULTI_AGENT=1
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_RESEARCH_DISPATCH_FAILURE. Invoke $grill-adapter:wiki-research for phase plan and featureSlug dispatch-failure. Multi-agent dispatch is unavailable in this run. Follow the installed skill failure contract: do not research inline, do not call Wiki MCP from the coordinator, do not create a selection or sidecar, and report a broken dispatch caveat rather than no relevant knowledge. Return only {"acceptanceStage":"research-dispatch-failure","status":"broken","caveat":"dispatch-unavailable"}.'
run_codex_acceptance
unset ACCEPTANCE_DISABLE_MULTI_AGENT

[[ ! -e "$PROJECT/.grill-adapter/context/dispatch-failure/obsidian-wiki-selection.json" ]] || {
  printf 'research dispatch failure created a selection\n' >&2
  exit 1
}

# A configured Wiki failure remains content-fail-closed while the host honors the user's explicit
# choice to continue without Wiki context.
BROKEN_DIR="$PROJECT/.grill-adapter/context/broken-binding"
mkdir -p "$BROKEN_DIR"
cat > "$BROKEN_DIR/task-brief.md" <<'EOF'
Create broken-path.txt containing exactly `continued without wiki` after readiness records broken.
EOF
cp "$PROJECT/.grill-adapter/settings.json" "$SANDBOX/settings-before-host-failure.json"
python3 - "$PROJECT/.grill-adapter/settings.json" <<'PY'
import json
import sys

path = sys.argv[1]
settings = json.load(open(path, encoding="utf-8"))
settings["wiki"]["obsidian"]["bindings"][0]["root"] = "Projects/missing"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY
export ACCEPTANCE_TERMINAL_LOG="$HOST_FAIL_OPEN_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=12
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_HOST_FAIL_OPEN. Invoke $grill-adapter:wiki-readiness for the confirmed manual task at .grill-adapter/context/broken-binding/task-brief.md with featureSlug broken-binding. The configured Wiki binding is broken. My explicit user decision is to continue without Wiki context: record readiness status broken, discard every partial selection/context/snapshot, then create ./broken-path.txt from only the task brief with exactly `continued without wiki`. Do not spawn an agent. Return only {"acceptanceStage":"host-fail-open","status":"pass","readinessStatus":"broken","userDecision":"continue-without-wiki"}.'
run_codex_acceptance
cp "$SANDBOX/settings-before-host-failure.json" "$PROJECT/.grill-adapter/settings.json"

[[ "$(cat "$PROJECT/broken-path.txt")" == 'continued without wiki' ]] || {
  printf 'host fail-open path did not complete the task-only implementation\n' >&2
  exit 1
}
python3 - "$BROKEN_DIR/wiki-readiness.json" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
task = receipt["tasks"][0]
assert task["status"] == "broken", receipt
assert task["contextDisposition"] == "discarded", receipt
assert "contextFile" not in task, receipt
PY
[[ ! -e "$BROKEN_DIR/wiki-context.json" \
  && ! -e "$BROKEN_DIR/manual.wiki-implement.md" \
  && ! -e "$BROKEN_DIR/manual.wiki-review.md" ]] || {
  printf 'host fail-open retained partial Wiki context\n' >&2
  exit 1
}

# Maintenance dispatch failure is also an installed skill path and must never fall back inline.
export ACCEPTANCE_TERMINAL_LOG="$MAINTENANCE_DISPATCH_FAILURE_LOG"
export ACCEPTANCE_COMPLETED_PARENTS=13
export ACCEPTANCE_DISABLE_MULTI_AGENT=1
export ACCEPTANCE_PROMPT='ISSUE35_STAGE_MAINTENANCE_DISPATCH_FAILURE. Invoke $grill-adapter:wiki-maintenance audit maintenance-dispatch-failure with asOf 2026-08-01T12:00:00Z, identityLimit 10, and noteReadLimit 1. Multi-agent dispatch is unavailable. Do not audit inline, call Wiki MCP, or write a report. Return only {"acceptanceStage":"maintenance-dispatch-failure","status":"broken","mode":"audit","caveat":"dispatch-unavailable"}.'
run_codex_acceptance
unset ACCEPTANCE_DISABLE_MULTI_AGENT
[[ ! -e "$PROJECT/.grill-adapter/context/maintenance-dispatch-failure/wiki-maintenance-audit.json" ]] || {
  printf 'maintenance dispatch failure wrote a report\n' >&2
  exit 1
}

# The existing installed maintenance gate proves audit/consolidation isolation, proposal-only
# behavior, stale-report preservation, and journal/binding drift handling with real Codex children.
GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1 \
GRILL_ADAPTER_CODEX_BIN="$CODEX_BIN" \
GRILL_ADAPTER_CODEX_MODEL="$CODEX_MODEL" \
CODEX_HOME="$CODEX_SANDBOX_HOME" \
  bash "$ROOT/acceptance/codex-maintenance-installed.sh" "$ROOT"

python3 - \
  "$PROJECT" \
  "$VAULT" \
  "$CODEX_SANDBOX_HOME/sessions" \
  "$REPORT_OUTPUT" \
  "$OBSIDIAN_READ_LOG" \
  "$PLUGIN_ROOT/agents/wiki-researcher.md" \
  "$SELECTED_MARKER" \
  "$UNSELECTED_MARKER" \
  "$EXPIRED_MARKER" \
  "$CATALOG_MARKER" \
  "$CORRECTION_MARKER" \
  "$MODEL" \
  "$MODEL_PROVIDER" \
  "$PROJECT_HEAD" \
  "$VAULT_HEAD" <<'PY'
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys

(
    project_arg,
    vault_arg,
    sessions_arg,
    report_arg,
    read_log_arg,
    researcher_role_arg,
    selected_marker,
    unselected_marker,
    expired_marker,
    catalog_marker,
    correction_marker,
    model,
    provider,
    project_head,
    vault_head,
) = sys.argv[1:]

project = pathlib.Path(project_arg)
vault = pathlib.Path(vault_arg)
sessions = pathlib.Path(sessions_arg)
report_path = pathlib.Path(report_arg)


def load_rollout(path):
    events = [json.loads(line) for line in path.open(encoding="utf-8") if line.strip()]
    assert events and events[0]["type"] == "session_meta", path
    return events[0]["payload"], events


rollouts = [load_rollout(path) for path in sessions.rglob("rollout-*.jsonl")]
parents = [item for item in rollouts if item[0].get("thread_source") == "user"]
children = [item for item in rollouts if item[0].get("thread_source") == "subagent"]


def event_text(events):
    return "\n".join(json.dumps(event, ensure_ascii=False) for event in events)


def parent_for(marker):
    matches = [
        (meta, events) for meta, events in parents
        if any(
            marker in str(event.get("payload", {}).get("message", ""))
            for event in events
            if event.get("type") == "event_msg"
            and event.get("payload", {}).get("type") == "user_message"
        )
    ]
    assert len(matches) == 1, (marker, [meta.get("id") for meta, _ in matches])
    return matches[0]


def calls(events, name=None):
    values = [
        event["payload"] for event in events
        if event.get("type") == "response_item"
        and event.get("payload", {}).get("type") in {"function_call", "custom_tool_call"}
    ]
    if name is not None:
        values = [value for value in values if value.get("name") == name]
    return values


def terminal_result(events):
    return json.loads(terminal_message(events))


def terminal_message(events):
    messages = [
        event.get("payload", {}).get("last_agent_message")
        for event in events
        if event.get("type") == "event_msg"
        and event.get("payload", {}).get("type") == "task_complete"
    ]
    assert len(messages) == 1 and isinstance(messages[0], str), messages
    return messages[0]


def call_arguments(call):
    value = call.get("arguments")
    assert isinstance(value, str), call
    return json.loads(value)


def indexed_calls(events):
    return [
        (index, event["payload"])
        for index, event in enumerate(events)
        if event.get("type") == "response_item"
        and event.get("payload", {}).get("type") in {"function_call", "custom_tool_call"}
    ]


discovery_meta, discovery_events = parent_for("ISSUE39_STAGE_GRILL_WITH_DOCS")
spec_meta, spec_events = parent_for("ISSUE39_STAGE_TO_SPEC")
research_meta, research_events = parent_for("ISSUE35_STAGE_RESEARCH_SUCCESS")
malformed_meta, malformed_events = parent_for("ISSUE35_STAGE_MALFORMED_RESEARCHER_OUTPUT")
readiness_meta, readiness_events = parent_for("ISSUE35_STAGE_TASK_READINESS")
direct_meta, direct_events = parent_for("ISSUE35_STAGE_DIRECT_IMPLEMENTATION")
implement_meta, implement_events = parent_for("ISSUE35_STAGE_AGENT_IMPLEMENTATION")
review_meta, review_events = parent_for("ISSUE35_STAGE_CODE_REVIEW")
capture_meta, capture_events = parent_for("ISSUE35_STAGE_CAPTURE")
debug_meta, debug_events = parent_for("ISSUE39_STAGE_DIAGNOSING_BUGS")
role_load_failure_meta, role_load_failure_events = parent_for(
    "ISSUE40_STAGE_RESEARCH_ROLE_LOAD_FAILURE"
)
research_dispatch_meta, research_dispatch_events = parent_for("ISSUE35_STAGE_RESEARCH_DISPATCH_FAILURE")
host_fail_open_meta, host_fail_open_events = parent_for("ISSUE35_STAGE_HOST_FAIL_OPEN")
maintenance_dispatch_meta, maintenance_dispatch_events = parent_for(
    "ISSUE35_STAGE_MAINTENANCE_DISPATCH_FAILURE"
)

def user_message(events):
    messages = [
        event.get("payload", {}).get("message")
        for event in events
        if event.get("type") == "event_msg"
        and event.get("payload", {}).get("type") == "user_message"
    ]
    assert len(messages) == 1 and isinstance(messages[0], str), messages
    return messages[0]


discovery_user_message = user_message(discovery_events)
spec_user_message = user_message(spec_events)
research_user_message = user_message(research_events)
readiness_user_message = user_message(readiness_events)
review_user_message = user_message(review_events)
debug_user_message = user_message(debug_events)
for stage, message in (
    ("grill-with-docs", discovery_user_message),
    ("to-spec", spec_user_message),
    ("to-tickets", research_user_message),
    ("implement", readiness_user_message),
    ("code-review", review_user_message),
    ("diagnosing-bugs", debug_user_message),
):
    assert f"$mattpocock-skills:{stage}" in message, (stage, message)
    assert "$grill-adapter:" not in message, (stage, message)

stage_parents = (
    (discovery_meta, discovery_events),
    (spec_meta, spec_events),
    (research_meta, research_events),
    (malformed_meta, malformed_events),
    (readiness_meta, readiness_events),
    (direct_meta, direct_events),
    (implement_meta, implement_events),
    (review_meta, review_events),
    (capture_meta, capture_events),
    (debug_meta, debug_events),
    (role_load_failure_meta, role_load_failure_events),
    (research_dispatch_meta, research_dispatch_events),
    (host_fail_open_meta, host_fail_open_events),
    (maintenance_dispatch_meta, maintenance_dispatch_events),
)
actual_providers = {meta.get("model_provider") for meta, _ in stage_parents}
assert len(actual_providers) == 1 and None not in actual_providers, actual_providers
actual_provider = next(iter(actual_providers))
if provider:
    assert actual_provider == provider, (actual_provider, provider)

actual_models = set()
for meta, events in stage_parents:
    turn_models = {
        event.get("payload", {}).get("model")
        for event in events
        if event.get("type") == "turn_context"
    }
    assert len(turn_models) == 1 and None not in turn_models, (meta.get("id"), turn_models)
    actual_models.update(turn_models)
assert len(actual_models) == 1, actual_models
actual_model = next(iter(actual_models))
if model:
    assert actual_model == model, (actual_model, model)

research_result = terminal_result(research_events)
assert {key: value for key, value in research_result.items() if key not in {"caveats", "maintenanceWarnings"}} == {
    "status": "ok",
    "phase": "plan",
    "selectionPath": ".grill-adapter/context/issue-35/obsidian-wiki-selection.json",
    "counts": {"notes": 1, "requiredSkills": 0},
    "sources": ["project"],
}
for field in ("caveats", "maintenanceWarnings"):
    values = research_result.get(field)
    assert isinstance(values, list) and len(values) <= 20, (field, values)
    assert all(isinstance(value, str) and value.strip() for value in values), (field, values)
assert terminal_result(malformed_events) == {
    "acceptanceStage": "malformed-researcher-output",
    "status": "broken",
    "caveat": "selection-validation-failed",
}
assert terminal_result(readiness_events) == {"acceptanceStage": "task-readiness", "status": "ready"}
assert terminal_result(direct_events) == {"acceptanceStage": "direct-implementation", "status": "pass"}
assert terminal_result(implement_events) == {
    "acceptanceStage": "agent-implementation",
    "status": "pass",
    "childStatus": "completed",
}
assert terminal_result(review_events) == {
    "acceptanceStage": "code-review",
    "status": "pass",
    "standardsCompleted": True,
    "specCompleted": True,
    "captureStatus": "skipped",
}
assert terminal_result(capture_events) == {
    "acceptanceStage": "capture",
    "status": "skipped",
    "reason": "no-durable-candidate",
}
assert terminal_result(role_load_failure_events) == {
    "acceptanceStage": "research-role-load-failure",
    "status": "broken",
    "caveat": "role-load-failed",
}
assert terminal_result(research_dispatch_events) == {
    "acceptanceStage": "research-dispatch-failure",
    "status": "broken",
    "caveat": "dispatch-unavailable",
}
assert terminal_result(host_fail_open_events) == {
    "acceptanceStage": "host-fail-open",
    "status": "pass",
    "readinessStatus": "broken",
    "userDecision": "continue-without-wiki",
}
assert terminal_result(maintenance_dispatch_events) == {
    "acceptanceStage": "maintenance-dispatch-failure",
    "status": "broken",
    "mode": "audit",
    "caveat": "dispatch-unavailable",
}

discovery_children = [item for item in children if item[0].get("parent_thread_id") == discovery_meta["id"]]
research_children = [item for item in children if item[0].get("parent_thread_id") == research_meta["id"]]
role_load_failure_children = [
    item for item in children if item[0].get("parent_thread_id") == role_load_failure_meta["id"]
]
malformed_children = [item for item in children if item[0].get("parent_thread_id") == malformed_meta["id"]]
readiness_children = [item for item in children if item[0].get("parent_thread_id") == readiness_meta["id"]]
direct_children = [item for item in children if item[0].get("parent_thread_id") == direct_meta["id"]]
implement_children = [item for item in children if item[0].get("parent_thread_id") == implement_meta["id"]]
review_children = [item for item in children if item[0].get("parent_thread_id") == review_meta["id"]]
debug_children = [item for item in children if item[0].get("parent_thread_id") == debug_meta["id"]]
review_capture_children = [
    item
    for item in review_children
    if item[0].get("agent_path", "").rsplit("/", 1)[-1] == "issue35_capture"
]
reviewer_children = [item for item in review_children if item not in review_capture_children]
assert len(research_children) == 1
assert len(role_load_failure_children) == 1
assert discovery_children
assert not malformed_children
assert not readiness_children
assert not direct_children
assert len(implement_children) == 1
assert len(review_capture_children) == 1
assert len(reviewer_children) == 2
for meta in (research_dispatch_meta, host_fail_open_meta, maintenance_dispatch_meta):
    assert not [item for item in children if item[0].get("parent_thread_id") == meta["id"]]
assert "ISSUE35_STAGE_RESEARCH_SUCCESS" not in event_text(research_children[0][1])


def child_call_text(items):
    return "\n".join(
        json.dumps(call, ensure_ascii=False)
        for _, events in items
        for call in calls(events)
    )


discovery_child_calls = child_call_text(discovery_children)
for required in ("obsidian_wiki_status", "obsidian_wiki_catalog", "obsidian_wiki_search"):
    assert required in discovery_child_calls, (required, discovery_child_calls)

debug_child_calls = child_call_text(debug_children)
for required in ("obsidian_wiki_status", "obsidian_wiki_catalog", "obsidian_wiki_search"):
    assert required in debug_child_calls, (required, debug_child_calls)

review_capture_calls = child_call_text(review_capture_children)
for required in (
    "obsidian_wiki_status",
    "obsidian_wiki_sources",
    "obsidian_wiki_consolidation_candidates",
    "obsidian_wiki_capture_draft_view",
    "obsidian_wiki_stage_capture_plan",
):
    assert required in review_capture_calls, (required, review_capture_calls)

selection = json.loads((project / ".grill-adapter/context/issue-35/obsidian-wiki-selection.json").read_text(encoding="utf-8"))
selected_ids = [note["wikiId"] for note in selection["wikiNotes"]]
irrelevant_selections = len([wiki_id for wiki_id in selected_ids if wiki_id != "project/formatter"])
assert selected_ids == ["project/formatter"], selected_ids

formal_paths = [
    project / ".grill-adapter/context/issue-35/obsidian-wiki-selection.json",
    project / ".grill-adapter/context/issue-35/wiki-context.json",
    project / ".grill-adapter/context/issue-35/ticket-roster.json",
    project / ".grill-adapter/context/issue-35/wiki-readiness.json",
    project / ".grill-adapter/context/issue-35/manual.wiki-implement.md",
    project / ".grill-adapter/context/issue-35/manual.wiki-review.md",
    project / ".grill-adapter/context/issue-35/manual.wiki-review-handoff.md",
]
formal_text = "\n".join(path.read_text(encoding="utf-8") for path in formal_paths)
parent_text = "\n".join(event_text(events) for _, events in (
    (discovery_meta, discovery_events),
    (spec_meta, spec_events),
    (research_meta, research_events),
    (malformed_meta, malformed_events),
    (readiness_meta, readiness_events),
    (direct_meta, direct_events),
    (implement_meta, implement_events),
    (review_meta, review_events),
    (capture_meta, capture_events),
    (debug_meta, debug_events),
    (research_dispatch_meta, research_dispatch_events),
    (host_fail_open_meta, host_fail_open_events),
    (maintenance_dispatch_meta, maintenance_dispatch_events),
))
for forbidden in (unselected_marker, catalog_marker):
    assert forbidden not in formal_text
    assert forbidden not in parent_text
expired_injections = sum(text.count(expired_marker) for text in (formal_text, parent_text))
assert expired_injections == 0

assert selected_marker in (project / ".grill-adapter/context/issue-35/manual.wiki-implement.md").read_text(encoding="utf-8")
assert selected_marker in (project / ".grill-adapter/context/issue-35/manual.wiki-review.md").read_text(encoding="utf-8")
assert correction_marker in formal_text
assert selected_marker in event_text(direct_events), "direct main session never received the implementer contract"
assert selected_marker in event_text(implement_events), "main session never received the implementer contract"

research_calls = "\n".join(json.dumps(call, ensure_ascii=False) for call in calls(research_events))
for required in ("source_truth_settings.py", "--render-prompt", "plan-pre"):
    assert required in research_calls, (required, research_calls)

spec_calls = "\n".join(json.dumps(call, ensure_ascii=False) for call in calls(spec_events))
for required in ("source_truth_settings.py", "--render-prompt", "spec-pre"):
    assert required in spec_calls, (required, spec_calls)

readiness_calls = "\n".join(json.dumps(call, ensure_ascii=False) for call in calls(readiness_events))
for required in ("wiki_context_render.py", "--scaffold", "--finalize", "wiki_readiness.py", "freeze", "bind"):
    assert required in readiness_calls, (required, readiness_calls)

debug_skill_events = event_text(debug_events)
assert "<name>grill-adapter:break-loop</name>" in debug_skill_events, debug_skill_events
debug_terminal = terminal_message(debug_events)
for required in ("## Bug Loop Analysis:", "### 6. Update-Wiki Handoff"):
    assert required in debug_terminal, (required, debug_terminal)
assert re.search(
    r"^\s*-\s+\*\*Decision\*\*:\s*skip update-wiki\s*$",
    debug_terminal,
    flags=re.MULTILINE | re.IGNORECASE,
), debug_terminal

malformed_calls = "\n".join(json.dumps(call, ensure_ascii=False) for call in calls(malformed_events))
for required in ("wiki_context_render.py", "--scaffold", "malformed-selection.json", "malformed-context.json"):
    assert required in malformed_calls, (required, malformed_calls)
assert "obsidian_wiki_" not in malformed_calls.lower()

role_load_failure_parent_calls = "\n".join(
    json.dumps(call, ensure_ascii=False) for call in calls(role_load_failure_events)
)
assert "obsidian_wiki_" not in role_load_failure_parent_calls.lower()
role_load_failure_child_meta, role_load_failure_child_events = role_load_failure_children[0]
role_load_failure_child_calls = "\n".join(
    json.dumps(call, ensure_ascii=False) for call in calls(role_load_failure_child_events)
)
assert "child_role_loader.py load" in role_load_failure_child_calls
assert "obsidian_wiki_" not in role_load_failure_child_calls.lower()
assert terminal_result(role_load_failure_child_events) == {
    "status": "broken",
    "phase": "plan",
    "caveats": ["role-load-failed"],
}

research_spawns = calls(research_events, "spawn_agent")
implement_spawns = calls(implement_events, "spawn_agent")
review_spawns = calls(review_events, "spawn_agent")
assert len(research_spawns) == 1
assert len(implement_spawns) == 1
assert len(review_spawns) == 3
research_spawn_call = research_spawns[0]
research_spawn = call_arguments(research_spawn_call)
implement_spawn = call_arguments(implement_spawns[0])
review_spawn_args = [call_arguments(call) for call in review_spawns]
reviewer_spawn_args = [
    value for value in review_spawn_args if value["task_name"] in {"standards_review", "spec_review"}
]
capture_spawn_args = [value for value in review_spawn_args if value["task_name"] == "issue35_capture"]
assert research_spawn["fork_turns"] == "none"
assert research_spawn["task_name"] == "issue35_wiki_researcher"
assert implement_spawn["fork_turns"] == "none"
assert implement_spawn["task_name"] == "issue35_implementer"
assert {value["task_name"] for value in reviewer_spawn_args} == {"standards_review", "spec_review"}
assert len(capture_spawn_args) == 1
assert all(value["fork_turns"] == "none" for value in review_spawn_args)

research_parent_calls = indexed_calls(research_events)
research_child_meta, research_child_events = research_children[0]
research_child_path = research_child_meta["agent_path"]
research_spawn_outputs = [
    event["payload"]
    for event in research_events
    if event.get("type") == "response_item"
    and event.get("payload", {}).get("type") == "function_call_output"
    and event.get("payload", {}).get("call_id") == research_spawn_call["call_id"]
]
assert len(research_spawn_outputs) == 1
assert json.loads(research_spawn_outputs[0]["output"])["task_name"] == research_child_path
research_spawn_call_position = next(
    index for index, (_, call) in enumerate(research_parent_calls) if call is research_spawn_call
)
assert research_spawn_call_position + 1 < len(research_parent_calls)
research_wait_event_index, research_wait = research_parent_calls[research_spawn_call_position + 1]
assert research_wait.get("name") == "wait_agent"
research_child_terminal_messages = [
    (index, event["payload"])
    for index, event in enumerate(research_events)
    if event.get("type") == "response_item"
    and event.get("payload", {}).get("type") == "agent_message"
    and event.get("payload", {}).get("author") == research_child_path
]
assert len(research_child_terminal_messages) == 1
research_waits_until_terminal = [
    (index, call)
    for index, call in research_parent_calls
    if research_wait_event_index <= index < research_child_terminal_messages[0][0]
]
assert research_waits_until_terminal
assert research_waits_until_terminal[0][0] == research_wait_event_index
assert all(call.get("name") == "wait_agent" for _, call in research_waits_until_terminal)

review_parent_calls = indexed_calls(review_events)
review_capture_spawns = [
    (index, call)
    for index, call in review_parent_calls
    if call.get("name") == "spawn_agent"
    and call_arguments(call).get("task_name") == "issue35_capture"
]
assert len(review_capture_spawns) == 1
review_capture_spawn_event_index, review_capture_spawn = review_capture_spawns[0]
review_capture_call_position = next(
    index
    for index, (_, call) in enumerate(review_parent_calls)
    if call is review_capture_spawn
)
assert review_capture_call_position + 1 < len(review_parent_calls)
review_capture_wait_event_index, review_capture_wait = review_parent_calls[review_capture_call_position + 1]
assert review_capture_wait.get("name") == "wait_agent"

review_capture_child_meta, review_capture_child_events = review_capture_children[0]
review_capture_child_path = review_capture_child_meta["agent_path"]
reviewer_child_paths = {child_meta["agent_path"] for child_meta, _ in reviewer_children}
review_capture_spawn_outputs = [
    event["payload"]
    for event in review_events
    if event.get("type") == "response_item"
    and event.get("payload", {}).get("type") == "function_call_output"
    and event.get("payload", {}).get("call_id") == review_capture_spawn["call_id"]
]
assert len(review_capture_spawn_outputs) == 1
assert json.loads(review_capture_spawn_outputs[0]["output"])["task_name"] == review_capture_child_path

review_child_terminal_messages = [
    (index, event["payload"])
    for index, event in enumerate(review_events)
    if event.get("type") == "response_item"
    and event.get("payload", {}).get("type") == "agent_message"
    and event.get("payload", {}).get("author") in (reviewer_child_paths | {review_capture_child_path})
]
reviewer_terminal_messages = [
    item for item in review_child_terminal_messages if item[1].get("author") in reviewer_child_paths
]
assert len(reviewer_terminal_messages) == 2
assert all(index < review_capture_spawn_event_index for index, _ in reviewer_terminal_messages)
review_capture_terminal_messages = [
    item for item in review_child_terminal_messages if item[1].get("author") == review_capture_child_path
]
assert len(review_capture_terminal_messages) == 1
assert review_capture_terminal_messages[0][1].get("author") == review_capture_child_path
waits_until_capture_terminal = [
    (index, call)
    for index, call in review_parent_calls
    if review_capture_spawn_event_index < index < review_capture_terminal_messages[0][0]
]
assert waits_until_capture_terminal
assert waits_until_capture_terminal[0][0] == review_capture_wait_event_index
assert all(call.get("name") == "wait_agent" for _, call in waits_until_capture_terminal)
review_capture_wait_call_ids = {call["call_id"] for _, call in waits_until_capture_terminal}
review_capture_wait_outputs = [
    (index, event["payload"])
    for index, event in enumerate(review_events)
    if event.get("type") == "response_item"
    and event.get("payload", {}).get("type") == "function_call_output"
    and event.get("payload", {}).get("call_id") in review_capture_wait_call_ids
]
assert len(review_capture_wait_outputs) == len(waits_until_capture_terminal)
review_capture_wait_results = [
    json.loads(payload["output"])
    for _, payload in review_capture_wait_outputs
]
assert all(result in ({"message": "Wait timed out.", "timed_out": True}, {
    "message": "Wait completed.", "timed_out": False,
}) for result in review_capture_wait_results)
assert review_capture_wait_results[-1] == {"message": "Wait completed.", "timed_out": False}
assert review_capture_terminal_messages[0][0] > review_capture_wait_outputs[-1][0]
review_capture_result = terminal_result(review_capture_child_events)
assert review_capture_result["kind"] == "grill-adapter.wiki-capture-result"
assert review_capture_result["status"] == "ok"
assert review_capture_result["counts"] == {"queued": 0, "skipped": 0, "needsDecision": 0}


def assert_sealed_message(arguments, minimum_length):
    # Codex encrypts spawn messages in persisted rollouts. The child rollout and formal artifacts
    # below prove the decrypted contract inputs that were actually consumed.
    message = arguments.get("message")
    assert isinstance(message, str) and message.startswith("gAAAA"), arguments
    assert len(message) >= minimum_length, len(message)
    return message


researcher_role = pathlib.Path(researcher_role_arg).read_text(encoding="utf-8")
researcher_role_marker = "ROLE-LOADER-PRIVATE-MARKER"
researcher_role_manifest = json.loads(
    (pathlib.Path(researcher_role_arg).parent.parent / "contracts" / "child-role-loader-v1.json")
    .read_text(encoding="utf-8")
)
researcher_role_digest = researcher_role_manifest["roles"]["grill-adapter:wiki-researcher"]["digest"]
assert researcher_role_marker in researcher_role
sealed_messages = [
    assert_sealed_message(research_spawn, 200),
    assert_sealed_message(implement_spawn, 200),
    *(assert_sealed_message(value, 200) for value in review_spawn_args),
]
assert len(set(sealed_messages)) == len(sealed_messages)
assert len(sealed_messages[0]) < len(researcher_role), "research spawn embedded the role body"

research_parent_calls = indexed_calls(research_events)
research_loader_calls = [
    (index, call)
    for index, call in research_parent_calls
    if "child_role_loader.py" in json.dumps(call, ensure_ascii=False)
]
assert len(research_loader_calls) == 1, research_loader_calls
_, research_loader_call = research_loader_calls[0]
research_loader_arguments = call_arguments(research_loader_call)
assert "child_role_loader.py resolve" in research_loader_arguments.get("cmd", "")
assert researcher_role_digest in event_text(research_events)
assert researcher_role_marker not in event_text(research_events)

research_child_meta, research_child_events = research_children[0]
research_child_indexed_calls = indexed_calls(research_child_events)
assert research_child_indexed_calls
research_loader_first_call = research_child_indexed_calls[0]
assert research_loader_first_call[1].get("name") == "exec_command", research_loader_first_call
research_loader_arguments = call_arguments(research_loader_first_call[1])
research_loader_command = research_loader_arguments.get("cmd", "")
assert "child_role_loader.py load" in research_loader_command
assert "--role grill-adapter:wiki-researcher" in research_loader_command
assert researcher_role_digest in research_loader_command
assert "/agents/wiki-researcher.md" in research_loader_command
assert researcher_role_marker in event_text(research_child_events)
assert "Each accepts exactly one positional value" in event_text(research_child_events)

research_child_calls = "\n".join(
    json.dumps(call, ensure_ascii=False) for call in calls(research_child_events)
)
for index, call in research_child_indexed_calls[1:]:
    if "obsidian_wiki_" in json.dumps(call, ensure_ascii=False):
        assert index > research_loader_first_call[0]
for required in (
    "obsidian_wiki_status",
    "obsidian_wiki_sources",
    "obsidian_wiki_catalog",
    "obsidian_wiki_search",
    "obsidian_wiki_read_notes",
    "obsidian_wiki_graph_neighbors",
):
    assert required in research_child_calls, (required, research_child_calls)
assert "obsidian_wiki_propose_note_change" not in research_child_calls
assert "obsidian_wiki_apply_note_change" not in research_child_calls

roster = json.loads((project / ".grill-adapter/context/issue-35/ticket-roster.json").read_text(encoding="utf-8"))
task_brief = (project / "task-brief.md").read_text(encoding="utf-8").strip()
assert len(roster["tickets"]) == 1
assert roster["tickets"][0]["taskId"] == "manual"
assert roster["tickets"][0]["text"].strip() == task_brief

implement_child_text = event_text(implement_children[0][1])
assert selected_marker in implement_child_text
assert "ISSUE35_STAGE_AGENT_IMPLEMENTATION" not in implement_child_text
implement_child_calls = "\n".join(
    json.dumps(call, ensure_ascii=False) for call in calls(implement_children[0][1])
)
assert "manual.wiki-implement.md" in implement_child_calls
assert "task-brief.md" in implement_child_calls
assert "./test-format-agent.sh" in implement_child_calls
assert "manual.wiki-review.md" not in implement_child_calls
assert "manual.wiki-review-handoff.md" not in implement_child_calls

review_children_by_name = {
    child_meta.get("agent_path", "").rsplit("/", 1)[-1]: (child_meta, child_events)
    for child_meta, child_events in reviewer_children
}
assert set(review_children_by_name) == {"standards_review", "spec_review"}, review_children_by_name
for role_name, (child_meta, child_events) in review_children_by_name.items():
    child_text = event_text(child_events)
    assert selected_marker in child_text
    assert "ISSUE35_STAGE_CODE_REVIEW" not in child_text
    child_calls = "\n".join(
        json.dumps(call, ensure_ascii=False) for call in calls(child_events)
    )
    assert "manual.wiki-review-handoff.md" in child_calls
    assert "git diff" in child_calls
    assert "manual.wiki-implement.md" not in child_calls
    assert not re.search(r"manual\.wiki-review\.md(?!-handoff)", child_calls)
    assert "obsidian_wiki_" not in child_calls.lower()
    if role_name == "spec_review":
        assert "task-brief.md" in child_calls
        assert ".grill-adapter/context/issue-35/task-brief.md" not in child_calls

# Child reasoning stays in child rollouts; the parent receives only authored terminal messages.
for events in (research_events, implement_events, review_events):
    for event in events:
        payload = event.get("payload", {})
        if payload.get("author") in {meta.get("agent_path") for meta, _ in children}:
            assert payload.get("type") == "agent_message"

for events in (role_load_failure_events, research_dispatch_events, maintenance_dispatch_events):
    for call in calls(events):
        call_text = json.dumps(call, ensure_ascii=False).lower()
        assert "obsidian_wiki_" not in call_text

host_fail_open_calls = "\n".join(
    json.dumps(call, ensure_ascii=False) for call in calls(host_fail_open_events)
)
assert "wiki_readiness.py" in host_fail_open_calls
assert "broken" in host_fail_open_calls.lower()

test_results = [
    subprocess.run(
        ["bash", "-lc", command],
        cwd=project,
        check=False,
        capture_output=True,
        text=True,
    )
    for command in ("./test-format.sh", "./test-format-agent.sh")
]
hard_constraint_misses = sum(result.returncode != 0 for result in test_results)
assert hard_constraint_misses == 0, [result.stderr for result in test_results]

formatter_outputs = [
    subprocess.check_output([str(project / script), "sample"], text=True)
    for script in ("format-value.sh", "format-value-agent.sh")
]
correction_recurrences = sum(output.strip() == "<sample>" for output in formatter_outputs)
assert correction_recurrences == 0, formatter_outputs

read_log = pathlib.Path(read_log_arg).read_text(encoding="utf-8").splitlines()
note_body_reads = len([line for line in read_log if line.strip()])
assert note_body_reads > 0


def parse_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


workflow_events = (
    discovery_events
    + spec_events
    + research_events
    + readiness_events
    + direct_events
    + implement_events
    + review_events
    + capture_events
    + debug_events
)
timestamps = [parse_timestamp(event.get("timestamp")) for event in workflow_events]
timestamps = [value for value in timestamps if value is not None]
assert timestamps
latency_ms = int((max(timestamps) - min(timestamps)).total_seconds() * 1000)
assert latency_ms > 0

assert subprocess.check_output(["git", "-C", str(project), "rev-parse", "HEAD"], text=True).strip() == project_head
assert subprocess.check_output(["git", "-C", str(vault), "rev-parse", "HEAD"], text=True).strip() == vault_head
assert subprocess.run(["git", "-C", str(vault), "diff", "--quiet"]).returncode == 0
assert not subprocess.check_output(
    ["git", "-C", str(vault), "status", "--porcelain", "--untracked-files=all"],
    text=True,
).strip()

report = {
    "schemaVersion": 1,
    "kind": "grill-adapter.codex-context-isolation-evaluation",
    "status": "pass",
    "environment": {
        "model": actual_model,
        "provider": actual_provider,
    },
    "workflowStages": {
        "grillWithDocs": "pass",
        "toSpec": "pass",
        "toTickets": "pass",
        "discoveryPlanning": "pass",
        "taskReadiness": "pass",
        "directImplementation": "pass",
        "agentImplementation": "pass",
        "codeReview": "pass",
        "capture": "pass",
        "diagnosingBugs": "pass",
        "maintenanceAudit": "pass",
        "maintenanceConsolidation": "pass",
    },
    "failurePaths": {
        "researcherDispatch": "broken-caveat",
        "researcherRoleLoad": "broken-before-wiki-call",
        "maintenanceDispatch": "broken-caveat",
        "researcherMalformedOutput": "rejected-without-partial-context",
        "maintenanceStaleReport": "preserved-previous-report",
        "bindingDrift": "broken-user-continued-without-wiki",
        "hostFailOpen": "continued-without-wiki-context",
    },
    "isolation": {
        "researchAndMaintenanceCoordinatorMetadataOnly": True,
        "researcherRolePrivateInCoordinator": True,
        "researcherRoleLoadedByChild": True,
        "directImplementationConsumedImplementerContract": True,
        "directImplementationContractVisible": True,
        "implementerContractMatched": True,
        "reviewerContractsMatched": True,
        "agentReasoningPrivate": True,
        "parentTranscriptsExcluded": True,
        "maintenanceProposalOnly": True,
    },
    "metrics": {
        "hardConstraintMisses": hard_constraint_misses,
        "irrelevantSelections": irrelevant_selections,
        "expiredInjections": expired_injections,
        "correctionRecurrences": correction_recurrences,
        "noteBodyReads": note_body_reads,
        "endToEndLatencyMs": latency_ms,
    },
}
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, separators=(",", ":")))
PY

printf 'evaluation report: %s\n' "$REPORT_OUTPUT"
printf 'codex context isolation installed acceptance OK\n'
