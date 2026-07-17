#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the ticket roster — the host-agnostic boundary between a host's tracker and the
# Carry/Bind engine. Proves:
#   1. the shipped contract documents the shape AND how each host fills it,
#   2. the engine fingerprints exactly the text it is handed (independent oracle),
#   3. a malformed roster fails closed rather than silently binding wiki to the wrong tasks,
#   4. --scaffold stamps the feature identity without needing a plan file to exist.
# The engine must never read a tracker, a plan document, or the network to build the roster.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPT="${TARGET_INPUT}/scripts/wiki_context_render.py"
ROSTER_EXAMPLE="${TARGET_INPUT}/contracts/ticket-roster-v1.example.jsonc"

for f in "$SCRIPT" "$ROSTER_EXAMPLE"; do
  if [[ ! -f "$f" ]]; then
    printf 'Missing required file: %s\n' "$f" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected %s to contain %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

# --- The shipped contract tells the agent how each host fills the roster. ---
EXAMPLE_TEXT="$(cat "$ROSTER_EXAMPLE")"
assert_contains "roster contract" 'featureSlug' "$EXAMPLE_TEXT"
assert_contains "roster contract" 'ticketSource' "$EXAMPLE_TEXT"
assert_contains "roster contract" '.scratch/<feature-slug>/issues/<NN>-<slug>.md' "$EXAMPLE_TEXT"
assert_contains "roster contract" 'gh issue view' "$EXAMPLE_TEXT"
assert_contains "roster contract" 'docs/agents/issue-tracker.md' "$EXAMPLE_TEXT"
# The roster is transient working state, never a committed deliverable.
assert_contains "roster contract" 'Nothing under .adapter/context/ is committed' "$EXAMPLE_TEXT"

# --- The engine fingerprints the handed text, verified against an independent oracle. ---
ROSTER="$TMP/feature.ticket-roster.json"
cat > "$ROSTER" <<'JSON'
{
  "featureSlug": "example-feature",
  "ticketSource": "grill-local-scratch",
  "tickets": [
    {"taskId": "01", "taskTitle": "Add schema", "text": "# 01 — Add schema\nCreate the users table."},
    {"taskId": "02", "taskTitle": "Wire API", "text": "# 02 — Wire API\nExpose POST /login."}
  ]
}
JSON

python3 - "$SCRIPT" "$ROSTER" <<'PY'
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

script, roster_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('wcr', script)
wcr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wcr)

tasks = wcr.load_ticket_roster(Path(roster_path))
assert sorted(tasks) == ['01', '02'], sorted(tasks)
assert tasks['01']['title'] == 'Add schema', tasks['01']['title']

# Independent oracle: sha256 over the normalized ticket text, recomputed here rather than trusting
# the engine's own digest, so a normalization change is caught instead of rubber-stamped.
def fingerprint(text):
    lines = [l.rstrip() for l in text.replace('\r\n', '\n').replace('\r', '\n').split('\n')]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return hashlib.sha256(('\n'.join(lines) + '\n').encode('utf-8')).hexdigest()

roster = json.loads(Path(roster_path).read_text(encoding='utf-8'))
for ticket in roster['tickets']:
    expected = fingerprint(ticket['text'])
    actual = tasks[ticket['taskId']]['hash']
    assert actual == expected, f"{ticket['taskId']}: engine {actual} != oracle {expected}"
print('roster load + fingerprint oracle ok')
PY

# --- A malformed roster fails closed. Each case would otherwise bind wiki to the wrong tasks. ---
python3 - "$SCRIPT" "$TMP" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

script, tmp = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('wcr', script)
wcr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wcr)

ok = {"taskId": "01", "taskTitle": "T", "text": "body"}
# A non-object roster is rejected by the shared JSON loader as ValidationError; everything the
# roster itself specifies raises FingerprintError. main() reports both identically.
cases = [
    ("not an object", [ok], 'must be an object', wcr.ValidationError),
    ("empty tickets", {"tickets": []}, 'no tickets'),
    ("missing tickets", {"featureSlug": "x"}, 'no tickets'),
    ("missing taskId", {"tickets": [{"taskTitle": "T", "text": "b"}]}, 'taskId'),
    ("blank taskId", {"tickets": [{"taskId": "  ", "taskTitle": "T", "text": "b"}]}, 'taskId'),
    ("duplicate taskId", {"tickets": [ok, dict(ok)]}, 'Duplicate taskId'),
    ("missing text", {"tickets": [{"taskId": "01", "taskTitle": "T"}]}, 'text'),
    ("blank text", {"tickets": [{"taskId": "01", "taskTitle": "T", "text": "   "}]}, 'text'),
    ("missing taskTitle", {"tickets": [{"taskId": "01", "text": "b"}]}, 'taskTitle'),
    ("unknown ticketSource", {"ticketSource": "jira", "tickets": [ok]}, 'ticketSource'),
]

for case in cases:
    label, payload, needle = case[0], case[1], case[2]
    expected_exc = case[3] if len(case) > 3 else wcr.FingerprintError
    path = tmp / 'bad.json'
    path.write_text(json.dumps(payload), encoding='utf-8')
    try:
        wcr.load_ticket_roster(path)
    except expected_exc as exc:
        assert needle in str(exc), f'{label}: expected {needle!r} in {exc!r}'
    else:
        raise AssertionError(f'{label}: expected a malformed roster to fail closed')
print(f'{len(cases)} malformed-roster cases fail closed ok')
PY

# --- --scaffold stamps the feature identity with no plan file anywhere. ---
SEL="$TMP/feature.wiki-selection.json"
CTX="$TMP/feature.wiki-context.json"
printf '{"status":"ok","phase":"plan","wikiPages":[],"caveats":[]}' > "$SEL"
python3 "$SCRIPT" "$CTX" --scaffold "$SEL" --feature-slug example-feature --ticket-source grill-local-scratch --strict >/dev/null
python3 - "$CTX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['featureSlug'] == 'example-feature', d.get('featureSlug')
assert d['ticketSource'] == 'grill-local-scratch', d.get('ticketSource')
assert 'planPath' not in d, 'planPath must not survive into a schemaVersion 5 sidecar'
assert d['taskRouting']['ticketRosterFormat'] == 'grill-adapter-ticket-roster-v1'
print('scaffold feature identity ok')
PY

# --- An unknown ticketSource is refused at scaffold time too, not just at roster load. ---
if python3 "$SCRIPT" "$TMP/bad-src.json" --scaffold "$SEL" --feature-slug x --ticket-source jira --strict >/tmp/roster-bad-src.out 2>&1; then
  printf 'Expected an unknown --ticket-source to be refused\n' >&2
  exit 1
fi

printf 'ticket-roster smoke test complete\n'
