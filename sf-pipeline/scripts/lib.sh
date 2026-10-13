# shellcheck shell=bash
# lib.sh - helpers shared by the sf-pipeline bash scripts.
#
# Source it, do not run it:
#   here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$here/lib.sh"
#
# Nothing in here ever prints a secret. mask() only emits ::add-mask:: inside GitHub Actions,
# where the runner swallows the line; outside Actions it prints nothing.

# ---- logging --------------------------------------------------------------------------------
notice() { printf '::notice::%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
error() { printf '::error::%s\n' "$*"; }
die() {
  error "$*"
  exit 1
}

# mask VALUE - hide VALUE in the GitHub Actions log. A no-op outside Actions, so running a
# script on a laptop never prints the value it is trying to hide.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${1:-}" ]]; then
    printf '::add-mask::%s\n' "$1"
  fi
  return 0
}

# is_true VALUE - true for true/1/yes/on (any case).
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# strip_ref BRANCH - drop refs/heads/ and origin/ prefixes.
strip_ref() {
  local b="${1:-}"
  b="${b#refs/heads/}"
  b="${b#refs/remotes/}"
  b="${b#origin/}"
  printf '%s' "$b"
}

# ---- GitHub Actions plumbing ----------------------------------------------------------------
_sfp_delimiter() {
  printf 'SFP_EOF_%s%s%s' "$RANDOM" "$RANDOM" "$RANDOM"
}

# gh_output KEY VALUE - append a step output to $GITHUB_OUTPUT (heredoc form for multi-line
# values) and echo it to the log. Outside Actions it is only echoed.
gh_output() {
  local key="$1" value="${2-}" delim
  if [[ "$value" == *$'\n'* ]]; then
    delim="$(_sfp_delimiter)"
    while [[ "$value" == *"$delim"* ]]; do delim="$(_sfp_delimiter)"; done
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim" >>"$GITHUB_OUTPUT"
    fi
    printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim"
  else
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
    fi
    printf '%s=%s\n' "$key" "$value"
  fi
}

# gh_env KEY VALUE - export KEY for this script and, inside Actions, for every later step.
gh_env() {
  local key="$1" value="${2-}"
  export "$key=$value"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_ENV"
  fi
}

# ---- tools ----------------------------------------------------------------------------------
# find_python - print the first usable Python 3.10+ interpreter: $PYTHON, python3, python, py.
# The version probe also skips the Windows Store "python3" stub, which exists but cannot run.
find_python() {
  local c
  for c in "${PYTHON:-}" python3 python py; do
    [[ -n "$c" ]] || continue
    if command -v "$c" >/dev/null 2>&1 &&
      "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but was not found on PATH"
  done
}

# ---- Salesforce logins ----------------------------------------------------------------------
# Both helpers write their secret to a private temp file (umask 077) that is deleted on return
# and, through the EXIT trap, on any early exit. Neither ever echoes the secret.
keyfile=""
authurl_file=""
_sfp_secret_trap() {
  trap 'rm -f "$keyfile" "$authurl_file"' EXIT
}

# sf_jwt_login ALIAS CLIENT_ID USERNAME INSTANCE_URL KEY_B64 SET_DEFAULT KEY_VAR_NAME
# Decodes the base64 server.key into the temp file and runs `sf org login jwt`. KEY_VAR_NAME
# only names the secret in error messages.
sf_jwt_login() {
  local alias="$1" client_id="$2" username="$3" instance_url="$4" key_b64="$5"
  local set_default="$6" key_var="$7" rc=0
  _sfp_secret_trap
  keyfile="$(umask 077 && mktemp)"
  chmod 600 "$keyfile"
  if ! printf '%s' "$key_b64" | tr -d ' \r\n\t' | base64 -d >"$keyfile" 2>/dev/null; then
    rm -f "$keyfile"
    error "$key_var is not valid base64. It must be the base64 of server.key on one line: base64 -i server.key | tr -d '\\n'"
    return 1
  fi
  if ! grep -q 'PRIVATE KEY' "$keyfile"; then
    rm -f "$keyfile"
    error "$key_var decodes, but not to a PEM private key. It must be the base64 of server.key (the key, not the certificate)."
    return 1
  fi
  local args=(org login jwt
    --client-id "$client_id"
    --jwt-key-file "$keyfile"
    --username "$username"
    --instance-url "$instance_url"
    --alias "$alias")
  if [[ "$set_default" == "true" ]]; then
    args+=(--set-default)
  fi
  sf "${args[@]}" || rc=$?
  rm -f "$keyfile"
  return "$rc"
}

# sf_url_login ALIAS AUTH_URL SET_DEFAULT URL_VAR_NAME
# Writes the SFDX auth URL (force://<clientId>:<secret>:<refreshToken>@<instance>) to the temp
# file and runs `sf org login sfdx-url --sfdx-url-file <tmp>`. For orgs that cannot create a
# Connected App. URL_VAR_NAME only names the secret in error messages.
sf_url_login() {
  local alias="$1" auth_url="$2" set_default="$3" url_var="$4" rc=0
  auth_url="${auth_url//$'\r'/}"
  auth_url="${auth_url//$'\n'/}"
  if [[ "$auth_url" != force://* ]]; then
    error "$url_var does not look like an SFDX auth URL: it must start with force:// (get it with: sf org auth show-sfdx-auth-url --target-org <alias>)"
    return 1
  fi
  _sfp_secret_trap
  authurl_file="$(umask 077 && mktemp)"
  chmod 600 "$authurl_file"
  printf '%s\n' "$auth_url" >"$authurl_file"
  local args=(org login sfdx-url --sfdx-url-file "$authurl_file" --alias "$alias")
  if [[ "$set_default" == "true" ]]; then
    args+=(--set-default)
  fi
  sf "${args[@]}" || rc=$?
  rm -f "$authurl_file"
  return "$rc"
}
