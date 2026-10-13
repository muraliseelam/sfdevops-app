# shellcheck shell=bash
# helpers.sh - assertions and fixtures shared by the bash tests (sourced, not run).
#
# Every test_*.sh sources this, runs its cases, and ends with `finish`, which exits non-zero
# when any assertion failed. Only fake values are used; nothing here touches a real org.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/../scripts" && pwd)"
# shellcheck source=../scripts/lib.sh
source "$SCRIPTS_DIR/lib.sh"

PYTHON="$(find_python)" || {
  echo "python 3.10+ is required to run the tests" >&2
  exit 1
}
export PYTHON

PASSES=0
FAILURES=0
pass() {
  PASSES=$((PASSES + 1))
  echo "  ok   - $*"
}
fail() {
  FAILURES=$((FAILURES + 1))
  echo "  FAIL - $*"
}
section() { echo "# $*"; }

assert_eq() { # expected actual message
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi
}
assert_contains() { # haystack needle message
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing '$2')"; fi
}
assert_not_contains() { # haystack needle message
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 (unexpected '$2')"; fi
}
assert_file() { # path message
  if [[ -f "$1" ]]; then pass "$2"; else fail "$2 (no file $1)"; fi
}
assert_no_file() { # path message
  if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2 ($1 exists)"; fi
}

# out_get FILE KEY - read one value from a $GITHUB_OUTPUT-format file (last occurrence wins).
out_get() {
  "$PYTHON" - "$1" "$2" <<'PY' | tr -d '\r'
import sys

values, lines, i = {}, open(sys.argv[1], encoding="utf-8").read().splitlines(), 0
while i < len(lines):
    line = lines[i]
    if "<<" in line and "=" not in line.split("<<", 1)[0]:
        key, delim = line.split("<<", 1)
        buf, i = [], i + 1
        while i < len(lines) and lines[i] != delim:
            buf.append(lines[i])
            i += 1
        values[key] = "\n".join(buf)
    elif "=" in line:
        key, value = line.split("=", 1)
        values[key] = value
    i += 1
sys.stdout.write(values.get(sys.argv[2], ""))
PY
}

# json_get FILE EXPR - evaluate a Python expression against the parsed JSON file as `d`.
json_get() {
  "$PYTHON" - "$1" "$2" <<'PY' | tr -d '\r'
import json
import sys

d = json.load(open(sys.argv[1], encoding="utf-8"))
value = eval(sys.argv[2], {"d": d})
sys.stdout.write(json.dumps(value) if isinstance(value, (dict, list, bool)) or value is None else str(value))
PY
}

# new_tmp - a fresh temp dir removed when the test exits.
TMP_DIRS=()
cleanup_tmp() {
  local d
  for d in "${TMP_DIRS[@]}"; do rm -rf "$d"; done
}
trap cleanup_tmp EXIT
new_tmp() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  printf '%s' "$d"
}

# write_stub DIR NAME - write an executable stub (body from stdin) to DIR/NAME.
write_stub() {
  mkdir -p "$1"
  cat >"$1/$2"
  chmod +x "$1/$2"
}

finish() {
  echo "# $(basename "$0"): $PASSES passed, $FAILURES failed"
  [[ "$FAILURES" -eq 0 ]]
}
