#!/usr/bin/env bash
# Tests for install-sf.sh with stub `sf` and `npm` (nothing is installed for real).
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
S="$T/stub"
mkdir -p "$S"
write_stub "$BIN" sf <<'EOF'
#!/usr/bin/env bash
# Stub sf: versions come from files the stub npm / plugin install update.
case "${1:-} ${2:-}" in
  "--version ") echo "@salesforce/cli/$(cat "$STUB/sf_version") linux-x64 node-v22.11.0" ;;
  "plugins ") [[ -s "$STUB/sgd_version" ]] && echo "sfdx-git-delta $(cat "$STUB/sgd_version") ($(cat "$STUB/sgd_version"))" ;;
  "plugins --json")
    if [[ -s "$STUB/sgd_version" ]]; then
      echo "[{\"name\": \"@salesforce/cli\", \"version\": \"x\"}, {\"name\": \"sfdx-git-delta\", \"version\": \"$(cat "$STUB/sgd_version")\"}]"
    else
      echo "[]"
    fi ;;
  "plugins install")
    read -r answer
    echo "plugins install $3 answer=$answer" >>"$STUB/calls"
    echo "${3#sfdx-git-delta@}" >"$STUB/sgd_version" ;;
esac
exit 0
EOF
write_stub "$BIN" npm <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >>"$STUB/calls"
pkg="${*: -1}"
echo "${pkg#@salesforce/cli@}" >"$STUB/sf_version"
EOF

run_install() {
  : >"$S/calls"
  OUTF="$T/out.$RANDOM"
  ENVF="$T/env.$RANDOM"
  : >"$OUTF"
  : >"$ENVF"
  RC=0
  OUT="$(env -u SF_CLI_VERSION -u SGD_VERSION PATH="$BIN:$PATH" STUB="$S" GITHUB_OUTPUT="$OUTF" GITHUB_ENV="$ENVF" \
    "$@" bash "$SCRIPTS_DIR/install-sf.sh" 2>&1)" || RC=$?
  CALLS="$(cat "$S/calls")"
}

section "install-sf.sh: already installed"
echo 2.153.5 >"$S/sf_version"
echo 6.45.1 >"$S/sgd_version"
run_install
assert_eq 0 "$RC" "exits 0"
assert_eq "" "$CALLS" "nothing is installed when the pinned versions are present"
assert_contains "$(cat "$ENVF")" "SF_AUTOUPDATE_DISABLE=true" "exports SF_AUTOUPDATE_DISABLE into GITHUB_ENV"
assert_contains "$(cat "$ENVF")" "SF_DISABLE_TELEMETRY=true" "exports SF_DISABLE_TELEMETRY into GITHUB_ENV"
assert_eq 2.153.5 "$(out_get "$OUTF" sf_version)" "sf_version output"
assert_eq 6.45.1 "$(out_get "$OUTF" sgd_version)" "sgd_version output"
assert_contains "$OUT" "@salesforce/cli/2.153.5" "prints the CLI version"

section "install-sf.sh: upgrade to the pins"
echo 2.100.0 >"$S/sf_version"
: >"$S/sgd_version"
run_install SF_CLI_VERSION=2.153.5 SGD_VERSION=6.45.1
assert_eq 0 "$RC" "exits 0 after installing"
assert_contains "$CALLS" "npm install --global --no-audit --no-fund @salesforce/cli@2.153.5" "installs the pinned CLI with npm"
assert_contains "$CALLS" "plugins install sfdx-git-delta@6.45.1 answer=y" "installs the pinned plugin and answers the prompt"

section "install-sf.sh: custom pins"
run_install SF_CLI_VERSION=2.160.1 SGD_VERSION=6.46.0
assert_contains "$CALLS" "@salesforce/cli@2.160.1" "honours SF_CLI_VERSION"
assert_contains "$CALLS" "sfdx-git-delta@6.46.0" "honours SGD_VERSION"

write_stub "$BIN" npm <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >>"$STUB/calls"
EOF
echo 2.100.0 >"$S/sf_version"
run_install
assert_eq 1 "$RC" "fails when sf still reports the wrong version after npm install"
assert_contains "$OUT" "after installing 2.153.5" "explains the version mismatch"

finish
