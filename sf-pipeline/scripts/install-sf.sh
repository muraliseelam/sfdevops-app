#!/usr/bin/env bash
# install-sf.sh - install the pinned Salesforce CLI and the sfdx-git-delta plugin.
#
# Env
#   SF_CLI_VERSION   exact @salesforce/cli version (default 2.153.5)
#   SGD_VERSION      exact sfdx-git-delta version  (default 6.45.1)
#
# Skips the npm install when `sf --version` already reports SF_CLI_VERSION, and skips the
# plugin install when that exact plugin version is already installed. Exports
# SF_AUTOUPDATE_DISABLE=true and SF_DISABLE_TELEMETRY=true (into $GITHUB_ENV as well, so every
# later step inherits them). Outputs: sf_version, sgd_version.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

SF_CLI_VERSION="${SF_CLI_VERSION:-2.153.5}"
SGD_VERSION="${SGD_VERSION:-6.45.1}"

gh_env SF_AUTOUPDATE_DISABLE true
gh_env SF_DISABLE_TELEMETRY true
# The legacy names are still read by parts of the CLI.
gh_env SFDX_DISABLE_AUTOUPDATE true
gh_env SFDX_DISABLE_TELEMETRY true

installed_sf_version() {
  # "@salesforce/cli/2.153.5 linux-x64 node-v22.11.0" -> 2.153.5
  sf --version 2>/dev/null | sed -n 's#.*@salesforce/cli/\([0-9][0-9A-Za-z.+-]*\).*#\1#p' | head -n 1
}

current=""
if command -v sf >/dev/null 2>&1; then
  current="$(installed_sf_version || true)"
fi
if [[ "$current" == "$SF_CLI_VERSION" ]]; then
  echo "Salesforce CLI $SF_CLI_VERSION is already installed."
else
  require_cmd npm
  echo "Installing @salesforce/cli@$SF_CLI_VERSION (found: ${current:-none})"
  npm install --global --no-audit --no-fund "@salesforce/cli@$SF_CLI_VERSION"
  hash -r
  current="$(installed_sf_version || true)"
  [[ "$current" == "$SF_CLI_VERSION" ]] ||
    die "sf --version reports '${current:-nothing}' after installing $SF_CLI_VERSION (is the npm global bin directory on PATH?)"
fi

installed_sgd_version() {
  # `sf plugins` lists user plugins as "sfdx-git-delta 6.45.1" (sometimes "(6.45.1)" too).
  sf plugins 2>/dev/null | sed -n 's/^sfdx-git-delta \([0-9][0-9A-Za-z.+-]*\).*/\1/p' | head -n 1
}

sgd_current="$(installed_sgd_version || true)"
if [[ "$sgd_current" == "$SGD_VERSION" ]]; then
  echo "sfdx-git-delta $SGD_VERSION is already installed."
else
  echo "Installing sfdx-git-delta@$SGD_VERSION (found: ${sgd_current:-none})"
  # The plugin is not signed by Salesforce, so the CLI asks for confirmation. Answer it from a
  # here-string: no pipe, no prompt, no hang.
  sf plugins install "sfdx-git-delta@$SGD_VERSION" <<<"y"
  sgd_current="$(installed_sgd_version || true)"
  [[ "$sgd_current" == "$SGD_VERSION" ]] ||
    die "sfdx-git-delta reports '${sgd_current:-nothing}' after installing $SGD_VERSION"
fi

echo "---- versions ----"
sf --version
sf plugins
if command -v node >/dev/null 2>&1; then echo "node $(node --version)"; fi

gh_output sf_version "$SF_CLI_VERSION"
gh_output sgd_version "$SGD_VERSION"
