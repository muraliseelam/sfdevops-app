#!/usr/bin/env bash
# run_tests.sh - run every sf-pipeline test: the Python unittest suite, then each test_*.sh.
# Exits non-zero when anything failed. Run from anywhere:
#   bash sf-pipeline/tests/run_tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "$here/../scripts/lib.sh"
PY="$(find_python)" || {
  echo "python 3.10+ is required" >&2
  exit 1
}

failed=()
echo "==> python unittest"
if ! (cd "$root" && "$PY" -m unittest discover -s sf-pipeline/tests -t sf-pipeline/tests); then
  failed+=("python unittest")
fi
for t in "$here"/test_*.sh; do
  echo "==> $(basename "$t")"
  if ! bash "$t"; then
    failed+=("$(basename "$t")")
  fi
done
echo
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "All sf-pipeline tests passed."
