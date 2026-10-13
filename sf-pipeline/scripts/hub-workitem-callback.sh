#!/usr/bin/env bash
# hub-workitem-callback.sh - POST a work-item-scoped event to /cdo/deploy-callback.
#
# Builds a CallbackRequest with NO promotionId (the hub routes it to applyWorkItemEvent) from
# these env vars; empty ones are omitted:
#   WORK_ITEM (required) EVENT_TYPE (required) STATUS MESSAGE RUN_URL COMMIT_SHA ENVIRONMENT
#   PULL_REQUEST_URL PULL_REQUEST_NUMBER(int) PULL_REQUESTS_APPROVED(bool) REVIEW_STATE APPROVER
#   APPROVAL_METHOD COVERAGE_PERCENT(number) TESTS_PASSED(bool) FAILING_METHODS DEPLOY_ID
#   CHECK_ONLY(bool) TEST_LEVEL COMPONENT_COUNT(int) CONFLICT_PATHS
#   COMPONENTS_JSON_FILE / FINDINGS_JSON_FILE  files holding a JSON array, embedded as
#                                              "components" / "findings"
#   CALLBACK_OUT   where to write the payload (default: a temp file)
# RUN_URL defaults to this workflow run's URL when GITHUB_SERVER_URL, GITHUB_REPOSITORY and
# GITHUB_RUN_ID are set, because the hub de-duplicates deployments on it.
# Then calls hub-callback.sh deploy-callback <payload>; that script decides whether the hub is
# reachable, so this one exits 0 without a hub too.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ -n "${WORK_ITEM:-}" ]] || {
  error "WORK_ITEM is required (the work item key, e.g. WI-0032)"
  exit 2
}
[[ -n "${EVENT_TYPE:-}" ]] || {
  error "EVENT_TYPE is required (Commit | Validation | Deploy | PullRequest | Approval | Conflict | ...)"
  exit 2
}

if [[ -z "${RUN_URL:-}" && -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  export RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

PY="$(find_python)" || die "python3 (3.10+) is required to build the callback payload"

payload="${CALLBACK_OUT:-}"
if [[ -z "$payload" ]]; then
  payload="$(mktemp)"
  trap 'rm -f "$payload"' EXIT
fi

"$PY" - "$payload" <<'PY'
import json
import os
import sys

STRINGS = [
    ("WORK_ITEM", "workItem"), ("EVENT_TYPE", "eventType"), ("STATUS", "status"),
    ("MESSAGE", "message"), ("RUN_URL", "runUrl"), ("COMMIT_SHA", "commitSha"),
    ("ENVIRONMENT", "environment"), ("PULL_REQUEST_URL", "pullRequestUrl"),
    ("REVIEW_STATE", "reviewState"), ("APPROVER", "approver"),
    ("APPROVAL_METHOD", "approvalMethod"), ("FAILING_METHODS", "failingMethods"),
    ("DEPLOY_ID", "deployId"), ("TEST_LEVEL", "testLevel"), ("CONFLICT_PATHS", "conflictPaths"),
]
INTS = [("PULL_REQUEST_NUMBER", "pullRequestNumber"), ("COMPONENT_COUNT", "componentCount")]
NUMBERS = [("COVERAGE_PERCENT", "coveragePercent")]
BOOLS = [("PULL_REQUESTS_APPROVED", "pullRequestsApproved"), ("TESTS_PASSED", "testsPassed"),
         ("CHECK_ONLY", "checkOnly")]
ARRAYS = [("COMPONENTS_JSON_FILE", "components"), ("FINDINGS_JSON_FILE", "findings")]


def warn(msg):
    print(f"::warning::{msg}")


def env(name):
    return (os.environ.get(name) or "").strip()


body = {}
for var, key in STRINGS:
    # Multi-line values (failing methods, conflict paths) keep their newlines.
    raw = os.environ.get(var) or ""
    if raw.strip():
        body[key] = raw.strip("\r\n") if "\n" in raw else raw.strip()
for var, key in INTS:
    if env(var):
        try:
            body[key] = int(float(env(var)))
        except ValueError:
            warn(f"{var}='{env(var)}' is not a whole number; omitted from the callback")
for var, key in NUMBERS:
    if env(var):
        try:
            value = float(env(var))
            body[key] = int(value) if value.is_integer() else value
        except ValueError:
            warn(f"{var}='{env(var)}' is not a number; omitted from the callback")
for var, key in BOOLS:
    value = env(var).lower()
    if value in ("true", "1", "yes", "on"):
        body[key] = True
    elif value in ("false", "0", "no", "off"):
        body[key] = False
    elif value:
        warn(f"{var}='{env(var)}' is not true/false; omitted from the callback")
for var, key in ARRAYS:
    path = env(var)
    if not path:
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        warn(f"{var}: cannot read a JSON array from '{path}' ({exc}); omitted from the callback")
        continue
    if not isinstance(data, list):
        warn(f"{var}: '{path}' does not hold a JSON array; omitted from the callback")
        continue
    if data:
        body[key] = data

with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as fh:
    json.dump(body, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY

echo "Work item callback payload:"
cat "$payload"
bash "$here/hub-callback.sh" deploy-callback "$payload"
