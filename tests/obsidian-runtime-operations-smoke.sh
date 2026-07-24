#!/usr/bin/env bash
set -euo pipefail

# Public rollout contract for Issue #13: operator commands must distinguish legacy,
# shadow-validation, and completed cutover states without falling back to legacy reads.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
source "${SCRIPT_DIR}/_windows-compat.bash"
TMP="$(portable_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

PROJECT="$TMP/project"
FAKE_BIN="$TMP/bin"
FAKE_BIN_PATH="$FAKE_BIN"
if command -v cygpath >/dev/null 2>&1; then
  FAKE_BIN_PATH="$(cygpath -u "$FAKE_BIN")"
fi
mkdir -p "$PROJECT/.shared-adapter" "$PROJECT/.adapter/wiki" "$FAKE_BIN"
printf '# legacy content\n' > "$PROJECT/.adapter/wiki/index.md"

if "$ROOT/doctor.sh" "$TMP/missing-project" >"$TMP/doctor-missing.out" 2>&1; then
  fail "doctor accepted a missing project directory"
fi
need "$TMP/doctor-missing.out" 'project root is not a directory'

cat > "$PROJECT/.shared-adapter/settings.json" <<'JSON'
{
  "wiki": {
    "provider": "obsidian",
    "publishing": {"mode": "git-pr"},
    "obsidian": {
      "bindings": [
        {
          "sourceId": "project-source",
          "role": "project",
          "vaultRef": "main-vault",
          "repositoryRef": "project-wiki",
          "root": "sources/project",
          "access": {"read": true, "update": "confirm"}
        }
      ]
    }
  }
}
JSON

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  cat > "$FAKE_BIN/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_OBSIDIAN_STATUS:?}"
SH
  chmod +x "$FAKE_BIN/node"
  cat > "$FAKE_BIN/node.cmd" <<'CMD'
@echo off
echo %FAKE_OBSIDIAN_STATUS%
CMD
else
  cat > "$FAKE_BIN/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_OBSIDIAN_STATUS:?}"
SH
  chmod +x "$FAKE_BIN/node"
fi
hash -r

if "$ROOT/bootstrap-wiki.sh" "$PROJECT" --template standard >"$TMP/bootstrap.out" 2>"$TMP/bootstrap.err"; then
  fail "bootstrap-wiki accepted an active Obsidian provider"
fi
need "$TMP/bootstrap.err" 'legacy Wiki bootstrap is disabled while wiki.provider is obsidian'
need "$TMP/bootstrap.err" 'migrate-wiki'

HEALTHY='{"healthy":true,"provider":"obsidian","bindings":[{"sourceId":"project-source"}],"errors":[],"warnings":[]}'
PATH="$FAKE_BIN_PATH:$PATH" FAKE_OBSIDIAN_STATUS="$HEALTHY" \
  "$ROOT/doctor.sh" "$PROJECT" >"$TMP/doctor-shadow.out"
need "$TMP/doctor-shadow.out" 'adoptionState: shadow-validation'
need "$TMP/doctor-shadow.out" 'Obsidian runtime healthy: yes'
need "$TMP/doctor-shadow.out" 'legacy runtime fallback: disabled'

python3 - "$PROJECT/.shared-adapter/settings.json" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text(encoding="utf-8"))
settings["wiki"]["legacyRuntime"] = {
    "mode": "read-only-archive",
    "roots": [".adapter/wiki"],
    "migrationManifest": ".adapter/context/migration.json",
}
path.write_text(json.dumps(settings), encoding="utf-8")
PY

if PATH="$FAKE_BIN_PATH:$PATH" FAKE_OBSIDIAN_STATUS="$HEALTHY" \
  "$ROOT/doctor.sh" "$PROJECT" >"$TMP/doctor-forged-cutover.out" 2>&1; then
  fail "doctor accepted cutover settings without a completed migration receipt"
fi
need "$TMP/doctor-forged-cutover.out" 'migrationManifest does not exist'

mkdir -p "$PROJECT/.adapter/context"
cat > "$PROJECT/.adapter/context/migration.json" <<'JSON'
{
  "schemaVersion": 1,
  "kind": "grill-adapter.obsidian-migration",
  "state": "published",
  "checks": {
    "mergedPullRequests": true,
    "baseSynchronized": true,
    "mappingCoverage": true,
    "uniqueWikiIds": true,
    "schemaAndPolicy": true,
    "sourceIsolation": true,
    "search": true,
    "hardNoteReread": true,
    "typedEdges": true
  },
  "cutover": {
    "settingsPath": ".shared-adapter/settings.json",
    "legacyRuntime": {
      "mode": "read-only-archive",
      "roots": [".adapter/wiki"],
      "migrationManifest": ".adapter/context/migration.json"
    }
  }
}
JSON

cp "$PROJECT/.adapter/context/migration.json" "$TMP/migration-before-doctor.json"
if PATH="$FAKE_BIN_PATH:$PATH" FAKE_OBSIDIAN_STATUS="$HEALTHY" \
  "$ROOT/doctor.sh" "$PROJECT" >"$TMP/doctor-incomplete-receipt.out" 2>&1; then
  fail "doctor accepted an incomplete migration receipt"
fi
need "$TMP/doctor-incomplete-receipt.out" 'not a completed Obsidian migration cutover receipt'
cmp -s "$TMP/migration-before-doctor.json" "$PROJECT/.adapter/context/migration.json" \
  || fail "doctor mutated an incomplete migration receipt"

python3 - "$PROJECT/.adapter/context/migration.json" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["state"] = "cutover"
path.write_text(json.dumps(manifest), encoding="utf-8")
PY

if PATH="$FAKE_BIN_PATH:$PATH" FAKE_OBSIDIAN_STATUS="$HEALTHY" \
  "$ROOT/doctor.sh" "$PROJECT" >"$TMP/doctor-forged-receipt.out" 2>&1; then
  fail "doctor accepted a hand-written migration receipt"
fi
need "$TMP/doctor-forged-receipt.out" 'migration verify failed'

python3 - "$PROJECT/.shared-adapter/settings.json" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text(encoding="utf-8"))
settings["wiki"].pop("legacyRuntime")
path.write_text(json.dumps(settings), encoding="utf-8")
PY

UNHEALTHY='{"healthy":false,"provider":"obsidian","bindings":[],"errors":["repository base is stale"],"warnings":[]}'
if PATH="$FAKE_BIN_PATH:$PATH" FAKE_OBSIDIAN_STATUS="$UNHEALTHY" \
  "$ROOT/doctor.sh" "$PROJECT" >"$TMP/doctor-unhealthy.out" 2>&1; then
  fail "doctor accepted an unhealthy active Obsidian provider"
fi
need "$TMP/doctor-unhealthy.out" 'Obsidian runtime healthy: no'
need "$TMP/doctor-unhealthy.out" 'repository base is stale'

python3 - "$PROJECT/.shared-adapter/settings.json" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text(encoding="utf-8"))
settings["wiki"]["provider"] = "unknown-provider"
path.write_text(json.dumps(settings), encoding="utf-8")
PY
if PATH="$FAKE_BIN_PATH:$PATH" FAKE_OBSIDIAN_STATUS="$HEALTHY" \
  "$ROOT/doctor.sh" "$PROJECT" >"$TMP/doctor-provider.out" 2>&1; then
  fail "doctor accepted an unsupported Wiki provider"
fi
need "$TMP/doctor-provider.out" 'unsupported wiki.provider: unknown-provider'

if ! grep -Fq 'doctor.sh" "$PROJECT_ROOT"' "$ROOT/release-check.sh"; then
  fail "release-check still ignores doctor failures"
fi

need "$ROOT/skills/init-wiki/SKILL.md" 'wiki.provider: obsidian'
need "$ROOT/skills/init-wiki/SKILL.md" 'stop without writing legacy Wiki content'

for host in \
  "$ROOT/host-adapters/grill/CLAUDE.md" \
  "$ROOT/host-adapters/grill/AGENTS.md" \
  "$ROOT/host-adapters/plain/CLAUDE.md" \
  "$ROOT/host-adapters/plain/AGENTS.md"; do
  need "$host" 'shadow-validation'
  need "$host" 'migration verify'
  need "$host" 'rerun the same publish step'
done

for manifest in "$ROOT/.codex-plugin/plugin.json" "$ROOT/.claude-plugin/plugin.json" "$ROOT/manifest.json"; do
  need "$manifest" 'Obsidian atomic Notes'
done

ACCEPTANCE="$ROOT/docs/OBSIDIAN_ACCEPTANCE_CN.md"
need "$ROOT/README.md" 'OBSIDIAN_ACCEPTANCE_CN.md'
need "$ACCEPTANCE" 'Obsidian Desktop'
need "$ACCEPTANCE" 'installed Claude Code'
need "$ACCEPTANCE" 'installed Codex'
need "$ACCEPTANCE" 'shadow-validation'
need "$ACCEPTANCE" 'no legacy runtime fallback'

printf 'obsidian runtime operations smoke complete\n'
