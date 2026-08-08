#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
LOADER="$ROOT/scripts/child_role_loader.py"
ROLE="$ROOT/agents/wiki-researcher.md"
MARKER="ROLE-LOADER-PRIVATE-MARKER"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

python3 - "$ROOT" "$LOADER" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
loader = pathlib.Path(sys.argv[2])
expected_roles = {
    "grill-adapter:wiki-researcher": "agents/wiki-researcher.md",
    "grill-adapter:wiki-capture": "agents/wiki-capture.md",
    "grill-adapter:wiki-maintenance-audit": "agents/wiki-maintenance-audit.md",
    "grill-adapter:wiki-maintenance-consolidation": "agents/wiki-maintenance-consolidation.md",
    "grill-adapter:wiki-outbox-consolidation": "agents/wiki-outbox-consolidation.md",
}

manifest = json.loads((root / "contracts/child-role-loader-v1.json").read_text(encoding="utf-8"))
assert set(manifest["roles"]) == set(expected_roles)
for identity, relative_source in expected_roles.items():
    role_path = root / relative_source
    descriptor = json.loads(
        subprocess.check_output(
            [sys.executable, str(loader), "resolve", "--plugin-root", str(root), "--role", identity],
            text=True,
        )
    )
    assert descriptor["role"] == identity
    assert pathlib.Path(descriptor["source"]) == role_path.resolve()
    assert descriptor["expectedDigest"] == "sha256:" + hashlib.sha256(role_path.read_bytes()).hexdigest()
    loaded = subprocess.check_output(
        [
            sys.executable,
            str(loader),
            "load",
            "--role",
            identity,
            "--source",
            descriptor["source"],
            "--expected-digest",
            descriptor["expectedDigest"],
        ]
    )
    assert loaded == role_path.read_bytes()
PY

descriptor="$(python3 "$LOADER" resolve --plugin-root "$ROOT" --role grill-adapter:wiki-researcher)"
printf '%s\n' "$descriptor" > "$TMP/descriptor.json"

python3 - "$TMP/descriptor.json" "$ROOT" "$ROLE" "$MARKER" <<'PY'
import hashlib
import json
import pathlib
import sys

descriptor_path = pathlib.Path(sys.argv[1])
root_path = pathlib.Path(sys.argv[2])
role_path = pathlib.Path(sys.argv[3])
marker = sys.argv[4]
descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
role = role_path.read_bytes()

assert set(descriptor) == {"schemaVersion", "kind", "role", "source", "expectedDigest"}
assert descriptor["schemaVersion"] == 1
assert descriptor["kind"] == "grill-adapter.child-role-descriptor"
assert descriptor["role"] == "grill-adapter:wiki-researcher"
assert pathlib.Path(descriptor["source"]) == role_path.resolve()
assert descriptor["expectedDigest"] == "sha256:" + hashlib.sha256(role).hexdigest()
assert marker not in json.dumps(descriptor)
assert pathlib.Path(descriptor["source"]).is_relative_to(root_path.resolve())
PY

source="$(python3 - "$TMP/descriptor.json" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["source"])
PY
)"
digest="$(python3 - "$TMP/descriptor.json" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["expectedDigest"])
PY
)"

python3 "$LOADER" load \
  --role grill-adapter:wiki-researcher \
  --source "$source" \
  --expected-digest "$digest" > "$TMP/loaded-role.md"
cmp -s "$ROLE" "$TMP/loaded-role.md" || fail "loader did not return the verified complete role"

if python3 "$LOADER" load \
  --role grill-adapter:wiki-researcher \
  --source "$source" \
  --expected-digest "sha256:$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then
  fail "loader accepted a mismatched expected digest"
fi

printf 'outside role source\n' > "$TMP/outside.md"
if python3 "$LOADER" load \
  --role grill-adapter:wiki-researcher \
  --source "$TMP/outside.md" \
  --expected-digest "$digest" >/dev/null 2>&1; then
  fail "loader accepted an out-of-bounds source"
fi

DRIFT_PLUGIN="$TMP/drift-plugin"
mkdir -p "$DRIFT_PLUGIN/agents" "$DRIFT_PLUGIN/contracts" "$DRIFT_PLUGIN/scripts"
cp "$ROLE" "$DRIFT_PLUGIN/agents/wiki-researcher.md"
cp "$ROOT/contracts/child-role-loader-v1.json" "$DRIFT_PLUGIN/contracts/child-role-loader-v1.json"
cp "$LOADER" "$DRIFT_PLUGIN/scripts/child_role_loader.py"
printf '\nrole drift\n' >> "$DRIFT_PLUGIN/agents/wiki-researcher.md"
drift_descriptor="$(python3 "$LOADER" resolve --plugin-root "$DRIFT_PLUGIN" --role grill-adapter:wiki-researcher)"
drift_source="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["source"])' <<<"$drift_descriptor")"
drift_digest="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["expectedDigest"])' <<<"$drift_descriptor")"
if python3 "$LOADER" load \
  --role grill-adapter:wiki-researcher \
  --source "$drift_source" \
  --expected-digest "$drift_digest" >/dev/null 2>&1; then
  fail "loader accepted role content drift"
fi

printf 'child role loader smoke OK\n'
