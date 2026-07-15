#!/usr/bin/env bash
# grill-adapter self-test — run the smoke/regression suite under tests/.
#
# Each tests/*.sh receives the grill-adapter repo root as $1 and an optional project
# root as $2, so the suite exercises the engine + install without a live host.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-}"
TESTS_DIR="$SCRIPT_DIR/tests"

if [[ ! -d "$TESTS_DIR" ]]; then
  echo "No tests/ directory." >&2
  exit 1
fi

pass=0; fail=0; failed_names=()
shopt -s nullglob
for t in "$TESTS_DIR"/*.sh; do
  name="$(basename "$t")"
  if bash "$t" "$SCRIPT_DIR" "$PROJECT_ROOT" >/tmp/grill-selftest-$$.log 2>&1; then
    printf 'PASS  %s\n' "$name"
    pass=$((pass+1))
  else
    printf 'FAIL  %s\n' "$name"
    sed 's/^/      /' /tmp/grill-selftest-$$.log | tail -15
    fail=$((fail+1))
    failed_names+=("$name")
  fi
done
rm -f /tmp/grill-selftest-$$.log

echo ""
echo "self-test: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
  printf 'failed: %s\n' "${failed_names[*]}" >&2
  exit 1
fi
