#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/.adapter" "$TMP_DIR/src/services/generated" "$TMP_DIR/openapi" "$TMP_DIR/src/mocks" "$TMP_DIR/dist"

grep_json() {
  local text="$1"
  local file="$2"
  if ! grep -Fq -- "$text" "$file"; then
    printf 'Expected %s to contain: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

reject_json() {
  local text="$1"
  local file="$2"
  if grep -Fq -- "$text" "$file"; then
    printf 'Expected %s to omit: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy >"$TMP_DIR/no-config.json"
grep_json '"status": "not_configured"' "$TMP_DIR/no-config.json"
grep_json '"heuristics": false' "$TMP_DIR/no-config.json"
python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --render-prompt spec-pre >"$TMP_DIR/no-config-prompt.md"
if [[ -s "$TMP_DIR/no-config-prompt.md" ]]; then
  printf 'Expected unconfigured prompt render to be silent\n' >&2
  exit 1
fi
python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --lint-changed --changed-path src/app.ts --format json >"$TMP_DIR/no-config-lint.json"
grep_json '"status": "pass"' "$TMP_DIR/no-config-lint.json"

cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{
  "sourceOfTruth": {
    "sources": [
      {"paths": ["src/services/generated/**"], "role": "truth", "edit": "never"},
      {"paths": ["/openapi/**", "!openapi/draft/**"], "role": "truth", "edit": "ask"},
      {"paths": ["src/mocks/**", "**/*.mock.ts", "**/*.fixture.ts"], "role": "evidence"},
      {"paths": ["dist/", "node_modules/**"], "role": "ignore"},
      {"paths": ["src/services/generated/experimental/**"], "role": "evidence"}
    ]
  }
}
JSON
python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy \
  --classify src/services/generated/client.ts \
  --classify src/services/generated/experimental/client.ts \
  --classify openapi/current.yaml \
  --classify openapi/draft/current.yaml \
  --classify src/mocks/user.mock.ts \
  --classify dist/app.js >"$TMP_DIR/classified.json"
grep_json '"status": "configured"' "$TMP_DIR/classified.json"
grep_json '"heuristics": false' "$TMP_DIR/classified.json"
grep_json '"role": "truth"' "$TMP_DIR/classified.json"
grep_json '"edit": "never"' "$TMP_DIR/classified.json"
grep_json '"edit": "ask"' "$TMP_DIR/classified.json"
grep_json '"role": "evidence"' "$TMP_DIR/classified.json"
grep_json '"role": "ignore"' "$TMP_DIR/classified.json"
grep_json '"role": "unconfigured"' "$TMP_DIR/classified.json"

printf 'src/services/generated/client.ts\nopenapi/current.yaml\nsrc/mocks/user.mock.ts\ndist/app.js\nsrc/other.ts\n' | \
  python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --classify-from-stdin >"$TMP_DIR/stdin-classified.json"
grep_json '"path": "src/services/generated/client.ts"' "$TMP_DIR/stdin-classified.json"

for prompt_kind in spec-pre spec-review plan-pre plan-review execution-reminder; do
  python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --render-prompt "$prompt_kind" >"$TMP_DIR/${prompt_kind}.md"
  grep_json 'Adapter Source-of-Truth' "$TMP_DIR/${prompt_kind}.md"
  grep_json 'src/services/generated/**' "$TMP_DIR/${prompt_kind}.md"
  grep_json 'openapi/**' "$TMP_DIR/${prompt_kind}.md"
  reject_json '"sources"' "$TMP_DIR/${prompt_kind}.md"
  reject_json 'client file content sentinel' "$TMP_DIR/${prompt_kind}.md"
  # `!openapi/draft/**` is a gitignore-style carve-out: it must render under the
  # carve-out group with the `!` stripped, never as a `!`-prefixed truth line.
  grep_json 'Carved-out sub-paths' "$TMP_DIR/${prompt_kind}.md"
  grep_json 'openapi/draft/**' "$TMP_DIR/${prompt_kind}.md"
  reject_json '!openapi/draft/**' "$TMP_DIR/${prompt_kind}.md"
done
grep_json 'Evidence-only paths' "$TMP_DIR/spec-pre.md"
grep_json 'Ignored for source-of-truth' "$TMP_DIR/spec-pre.md"
grep_json 'edit: never' "$TMP_DIR/plan-pre.md"
grep_json 'truth/edit: ask' "$TMP_DIR/plan-review.md"

python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --lint-changed \
  --changed-path src/services/generated/client.ts \
  --changed-path openapi/current.yaml \
  --changed-path src/mocks/user.mock.ts \
  --changed-path dist/app.js \
  --changed-path src/other.ts \
  --format json >"$TMP_DIR/lint-block.json"
grep_json '"status": "block"' "$TMP_DIR/lint-block.json"
grep_json 'SOT_TRUTH_EDIT_FORBIDDEN' "$TMP_DIR/lint-block.json"
grep_json 'SOT_TRUTH_EDIT_AUTH_MISSING' "$TMP_DIR/lint-block.json"
grep_json 'SOT_EVIDENCE_CHANGED' "$TMP_DIR/lint-block.json"

python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --lint-changed \
  --changed-path openapi/current.yaml \
  --authorized-truth-edit openapi/current.yaml \
  --format json >"$TMP_DIR/lint-ask-authorized.json"
grep_json '"status": "pass"' "$TMP_DIR/lint-ask-authorized.json"

python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --lint-changed \
  --changed-path openapi/current.yaml \
  --format text >"$TMP_DIR/lint-ask.txt"
grep_json 'sourceOfTruth changed-path lint: ask' "$TMP_DIR/lint-ask.txt"

printf 'src/mocks/user.mock.ts\nsrc/other.ts\n' >"$TMP_DIR/changed-paths.txt"
python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --lint-changed \
  --changed-paths-file "$TMP_DIR/changed-paths.txt" \
  --format json >"$TMP_DIR/lint-warn.json"
grep_json '"status": "warn"' "$TMP_DIR/lint-warn.json"

# Inline `!` negation inside a single truth/edit: never rule: the carved sub-path
# must render as an explicit carve-out (not under the truth heading) and must
# classify as unconfigured so the changed-path lint does not block it.
cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{
  "sourceOfTruth": {
    "sources": [
      {"paths": ["src/service2/", "!src/service2/**/*.adapter.ts"], "role": "truth", "edit": "never"}
    ]
  }
}
JSON
for prompt_kind in spec-pre plan-pre execution-reminder; do
  python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --render-prompt "$prompt_kind" >"$TMP_DIR/carveout-${prompt_kind}.md"
  grep_json 'Carved-out sub-paths' "$TMP_DIR/carveout-${prompt_kind}.md"
  grep_json 'src/service2/**/*.adapter.ts' "$TMP_DIR/carveout-${prompt_kind}.md"
  reject_json '!src/service2/**/*.adapter.ts' "$TMP_DIR/carveout-${prompt_kind}.md"
done
python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --lint-changed \
  --changed-path src/service2/widget/widget.ts \
  --changed-path src/service2/widget/widget.adapter.ts \
  --format json >"$TMP_DIR/carveout-lint.json"
grep_json '"status": "block"' "$TMP_DIR/carveout-lint.json"
grep_json '"path": "src/service2/widget/widget.adapter.ts"' "$TMP_DIR/carveout-lint.json"
grep_json '"role": "unconfigured"' "$TMP_DIR/carveout-lint.json"

cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{"sourceOfTruth": {"sources": [{"paths": ["src/**"], "role": "contract", "edit": "never"}]}}
JSON
if python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy >"$TMP_DIR/invalid-role.out" 2>&1; then
  printf 'Expected invalid role to fail\n' >&2
  exit 1
fi
grep_json 'expected one of' "$TMP_DIR/invalid-role.out"

cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{"sourceOfTruth": {"sources": [{"paths": ["src/**"], "role": "truth"}]}}
JSON
if python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy >"$TMP_DIR/missing-edit.out" 2>&1; then
  printf 'Expected truth without edit to fail\n' >&2
  exit 1
fi
grep_json "edit is required for role 'truth'" "$TMP_DIR/missing-edit.out"

cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{"sourceOfTruth": {"sources": [{"paths": ["src/mocks/**"], "role": "evidence", "edit": "ask"}]}}
JSON
if python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy >"$TMP_DIR/non-truth-edit.out" 2>&1; then
  printf 'Expected non-truth edit to fail\n' >&2
  exit 1
fi
grep_json 'edit is only allowed when role is' "$TMP_DIR/non-truth-edit.out"

cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{"sourceOfTruth": {"sources": [{"paths": ["../secret"], "role": "truth", "edit": "never"}]}}
JSON
if python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy >"$TMP_DIR/bad-pattern.out" 2>&1; then
  printf 'Expected unsafe pattern to fail\n' >&2
  exit 1
fi
grep_json "must not contain '..'" "$TMP_DIR/bad-pattern.out"

cat >"$TMP_DIR/.adapter/settings.json" <<'JSON'
{"sourceOfTruth": {"heuristics": true, "sources": [{"paths": ["src/mocks/**"], "role": "evidence"}, {"paths": ["dist/**"], "role": "ignore"}]}}
JSON
python3 "$ROOT/scripts/source_truth_settings.py" "$TMP_DIR" --show-policy >"$TMP_DIR/evidence-ignore.json"
grep_json '"heuristics": true' "$TMP_DIR/evidence-ignore.json"
grep_json '"role": "evidence"' "$TMP_DIR/evidence-ignore.json"
grep_json '"role": "ignore"' "$TMP_DIR/evidence-ignore.json"

printf 'source-truth settings smoke OK\n'
