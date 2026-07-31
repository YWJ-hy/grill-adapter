#!/usr/bin/env bash
set -euo pipefail

# Covers the feature-level continuation hint independently from the authoritative readiness path.
# The hint only projects local digests and a selected task; SessionStart must tell the next session
# to re-enter wiki-readiness rather than consuming the state as context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
FEATURE="$PROJECT/.grill-adapter/context/resume-feature"
mkdir -p "$FEATURE"
( cd "$PROJECT" && git init -q )
printf '%s\n' '<!-- grill-adapter:host:grill:start -->' > "$PROJECT/AGENTS.md"

printf '%s\n' \
  '{"featureSlug":"resume-feature","ticketSource":"manual","tickets":[{"taskId":"01","taskTitle":"Resume task","text":"Implement resumable state."}]}' \
  > "$FEATURE/ticket-roster.json"
printf '%s\n' \
  '{"schemaVersion":6,"kind":"grill-adapter.wiki-context","featureSlug":"resume-feature","ticketSource":"manual"}' \
  > "$FEATURE/wiki-context.json"
printf '%s\n' 'implementer snapshot' > "$FEATURE/01.wiki-implement.md"
printf '%s\n' 'reviewer snapshot' > "$FEATURE/01.wiki-review.md"
printf '%s\n' \
  '{"schemaVersion":1,"kind":"grill-adapter.wiki-readiness","generatedBy":"grill-adapter","featureSlug":"resume-feature","ticketSource":"manual","rosterFile":"ticket-roster.json","tasks":[{"taskId":"01","status":"ready"}]}' \
  > "$FEATURE/wiki-readiness.json"

JOURNAL="$FEATURE/wiki-candidates.jsonl"
python3 "$ROOT/scripts/wiki_candidate_journal.py" append \
  --journal "$JOURNAL" --feature-slug resume-feature --event-id candidate-1 --candidate-id candidate-1 \
  --stage implementation --candidate-type wiki_note --kind decision \
  --claim 'Keep continuation state advisory.' --why 'Readiness remains authoritative.' --source-ref 'issue:#1' \
  >/dev/null

python3 "$ROOT/scripts/wiki_session_state.py" update \
  --feature-dir "$FEATURE" --task-id 01 \
  --next-command '$grill-adapter:wiki-readiness 01' \
  >/dev/null

python3 - "$FEATURE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

feature = Path(sys.argv[1])
state = json.loads((feature / "wiki-session-state.json").read_text(encoding="utf-8"))
assert set(state) == {
    "schemaVersion", "kind", "generatedBy", "featureSlug", "lastSelectedTask",
    "rosterDigest", "contextDigest", "snapshotDigest", "readinessStatus",
    "candidateCount", "nextCommand",
}
assert state["featureSlug"] == "resume-feature"
assert state["lastSelectedTask"] == "01"
assert state["readinessStatus"] == "ready"
assert state["candidateCount"] == 1
assert state["nextCommand"] == "$grill-adapter:wiki-readiness 01"
assert state["rosterDigest"] == "sha256:" + hashlib.sha256((feature / "ticket-roster.json").read_bytes()).hexdigest()
assert state["contextDigest"] == "sha256:" + hashlib.sha256((feature / "wiki-context.json").read_bytes()).hexdigest()
assert state["snapshotDigest"].startswith("sha256:")
assert "Implement resumable state." not in json.dumps(state)
PY

# Journal refreshes preserve the explicit selected task while updating its advisory count.
python3 "$ROOT/scripts/wiki_candidate_journal.py" outcome \
  --journal "$JOURNAL" --feature-slug resume-feature --event-id outcome-1 --candidate-id candidate-1 \
  --status skipped --reason 'not durable after review' \
  >/dev/null
python3 - "$FEATURE/wiki-session-state.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["lastSelectedTask"] == "01"
assert state["candidateCount"] == 1
PY

OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$PROJECT" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$ROOT/hooks/wiki-reread.sh")"
printf '%s' "$OUT" | grep -q 'Continuation hint for feature' || fail "SessionStart did not use continuation summary"
printf '%s' "$OUT" | grep -q 'last explicitly selected task' || fail "continuation hint did not identify the task"
printf '%s' "$OUT" | grep -q 'resume-feature' || fail "continuation hint did not identify the feature"
printf '%s' "$OUT" | grep -q 'wiki-readiness 01' || fail "continuation hint omitted the next command"
printf '%s' "$OUT" | grep -q 'non-authoritative' || fail "continuation hint did not preserve authority boundary"

# An unsafe summary is not consumed; the hook falls back to its existing sidecar behavior.
printf '%s\n' \
  '{"schemaVersion":1,"kind":"grill-adapter.wiki-session-state","generatedBy":"grill-adapter","featureSlug":"resume-feature","lastSelectedTask":"../bad","rosterDigest":null,"contextDigest":null,"snapshotDigest":null,"readinessStatus":"ready","candidateCount":0,"nextCommand":"$grill-adapter:wiki-readiness"}' \
  > "$FEATURE/wiki-session-state.json"
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$PROJECT" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$ROOT/hooks/wiki-reread.sh")"
if printf '%s' "$OUT" | grep -q 'Continuation hint'; then
  fail "unsafe continuation task identifier was accepted"
fi

# A newer malformed state cannot hide an older valid feature-level continuation hint.
OLDER="$PROJECT/.grill-adapter/context/older-feature"
mkdir -p "$OLDER"
printf '%s\n' \
  '{"featureSlug":"older-feature","ticketSource":"manual","tickets":[{"taskId":"03","taskTitle":"older task","text":"older task"}]}' \
  > "$OLDER/ticket-roster.json"
python3 "$ROOT/scripts/wiki_session_state.py" update \
  --feature-dir "$OLDER" --task-id 03 \
  --next-command '$grill-adapter:wiki-readiness 03' \
  >/dev/null
python3 - "$OLDER/wiki-session-state.json" <<'PY'
import os
import sys

path = sys.argv[1]
os.utime(path, (1, 1))
PY
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$PROJECT" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$ROOT/hooks/wiki-reread.sh")"
printf '%s' "$OUT" | grep -q 'older-feature' || fail "hook did not select the newest valid continuation state"
printf '%s' "$OUT" | grep -q 'wiki-readiness 03' || fail "fallback valid continuation command was omitted"

# A malformed prior projection is replaceable, not a gate on the next explicit selection.
REPAIR="$PROJECT/.grill-adapter/context/repair-feature"
mkdir -p "$REPAIR"
printf '%s\n' \
  '{"featureSlug":"repair-feature","ticketSource":"manual","tickets":[{"taskId":"04","taskTitle":"repair task","text":"repair task"}]}' \
  > "$REPAIR/ticket-roster.json"
printf '%s\n' \
  '{"schemaVersion":1,"kind":"grill-adapter.wiki-session-state","generatedBy":"grill-adapter","featureSlug":"wrong-feature","lastSelectedTask":"04","rosterDigest":null,"contextDigest":null,"snapshotDigest":null,"readinessStatus":"unrecorded","candidateCount":0,"nextCommand":"$grill-adapter:wiki-readiness 04"}' \
  > "$REPAIR/wiki-session-state.json"
python3 "$ROOT/scripts/wiki_session_state.py" update --feature-dir "$REPAIR" --task-id 04 >/dev/null
python3 - "$REPAIR/wiki-session-state.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["featureSlug"] == "repair-feature"
assert state["lastSelectedTask"] == "04"
PY

# A newly explicit task must replace, rather than inherit, the prior task's next command.
SWITCH="$PROJECT/.grill-adapter/context/switch-feature"
mkdir -p "$SWITCH"
printf '%s\n' \
  '{"featureSlug":"switch-feature","ticketSource":"manual","tickets":[{"taskId":"01","taskTitle":"first","text":"first"},{"taskId":"02","taskTitle":"second","text":"second"}]}' \
  > "$SWITCH/ticket-roster.json"
python3 "$ROOT/scripts/wiki_session_state.py" update \
  --feature-dir "$SWITCH" --task-id 01 --next-command 'custom-first-command' \
  >/dev/null
python3 "$ROOT/scripts/wiki_session_state.py" update --feature-dir "$SWITCH" --task-id 02 >/dev/null
python3 - "$SWITCH/wiki-session-state.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["lastSelectedTask"] == "02"
assert state["nextCommand"] == "$grill-adapter:wiki-readiness 02"
PY
CLAUDE_PROJECT_DIR="$PROJECT" python3 "$ROOT/scripts/wiki_session_state.py" update \
  --feature-dir "$SWITCH" --task-id 01 >/dev/null
python3 - "$SWITCH/wiki-session-state.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["nextCommand"] == "/grill-adapter:wiki-readiness 01"
PY

# Direct-task preparation and readiness recording refresh the same summary automatically.
DIRECT="$PROJECT/.grill-adapter/context/direct-resume"
mkdir -p "$DIRECT"
printf '%s\n' 'Complete direct task brief.' > "$DIRECT/task-brief.md"
python3 "$ROOT/scripts/wiki_readiness.py" prepare-manual \
  --feature-slug direct-resume --task-title 'Direct resume task' \
  --task-text-file "$DIRECT/task-brief.md" --roster "$DIRECT/ticket-roster.json" \
  >/dev/null
python3 "$ROOT/scripts/wiki_readiness.py" record \
  --receipt "$DIRECT/wiki-readiness.json" --roster "$DIRECT/ticket-roster.json" \
  --task-id manual --status disabled --reason 'No Wiki provider is enabled.' \
  >/dev/null
python3 - "$DIRECT/wiki-session-state.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["featureSlug"] == "direct-resume"
assert state["lastSelectedTask"] == "manual"
assert state["readinessStatus"] == "disabled"
assert state["nextCommand"] == "$grill-adapter:wiki-readiness manual"
PY

printf 'wiki session state smoke OK\n'
