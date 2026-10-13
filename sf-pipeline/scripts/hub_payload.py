#!/usr/bin/env python3
"""hub_payload.py — build a hub callback payload from environment variables.

  hub_payload.py deploy   CallbackRequest for POST /cdo/deploy-callback (docs/CONTRACTS.md §2.1)
  hub_payload.py merge    merge-status payload for POST /cdo/merge-status (§2.2)

Every field is optional; empty variables are omitted, so the hub only sees what a run knows.
Numbers and booleans are emitted with their JSON types. COMPONENTS_JSON_FILE and
FINDINGS_JSON_FILE, when set and present, embed their arrays.

Writes the JSON to stdout.
"""

import json
import os
import sys

DEPLOY_FIELDS = [
    # (json key, env var, type)
    ("deploymentId", "DEPLOYMENT_ID", str),
    ("promotionId", "PROMOTION_ID", str),
    ("releaseId", "RELEASE_ID", str),
    ("status", "STATUS", str),
    ("message", "MESSAGE", str),
    ("runUrl", "RUN_URL", str),
    ("commitSha", "COMMIT_SHA", str),
    ("workItem", "WORK_ITEM", str),
    ("environment", "ENVIRONMENT", str),
    ("eventType", "EVENT_TYPE", str),
    ("pullRequestUrl", "PULL_REQUEST_URL", str),
    ("pullRequestNumber", "PULL_REQUEST_NUMBER", int),
    ("pullRequestsApproved", "PULL_REQUESTS_APPROVED", bool),
    ("reviewState", "REVIEW_STATE", str),
    ("approver", "APPROVER", str),
    ("approvalMethod", "APPROVAL_METHOD", str),
    ("coveragePercent", "COVERAGE_PERCENT", float),
    ("testsPassed", "TESTS_PASSED", bool),
    ("failingMethods", "FAILING_METHODS", str),
    ("deployId", "DEPLOY_ID", str),
    ("checkOnly", "CHECK_ONLY", bool),
    ("testLevel", "TEST_LEVEL", str),
    ("componentCount", "COMPONENT_COUNT", int),
    ("promotionBranch", "PROMOTION_BRANCH", str),
    ("targetShaAtCut", "TARGET_SHA_AT_CUT", str),
    ("conflictPaths", "CONFLICT_PATHS", str),
]

MERGE_FIELDS = [
    ("promotionId", "PROMOTION_ID", str),
    ("workItem", "WORK_ITEM", str),
    ("environment", "ENVIRONMENT", str),
    ("targetBranch", "TARGET_BRANCH", str),
    ("mergeSha", "MERGE_SHA", str),
    ("merged", "MERGED", bool),
    ("reason", "REASON", str),
    ("runUrl", "RUN_URL", str),
]


def convert(raw, kind):
    raw = raw.strip()
    if raw == "":
        return None
    if kind is bool:
        return raw.lower() in ("1", "true", "yes", "on")
    if kind is int:
        try:
            return int(float(raw))
        except ValueError:
            return None
    if kind is float:
        try:
            return float(raw)
        except ValueError:
            return None
    return raw


def build(fields, env):
    payload = {}
    for key, var, kind in fields:
        value = convert(env.get(var, ""), kind)
        if value is not None:
            payload[key] = value
    return payload


def embed_array(payload, key, path):
    if path and os.path.isfile(path):
        try:
            data = json.load(open(path, encoding="utf-8"))
        except ValueError:
            return
        if isinstance(data, list) and data:
            payload[key] = data


def main(argv):
    if len(argv) != 1 or argv[0] not in ("deploy", "merge"):
        sys.stderr.write(__doc__)
        return 2
    env = os.environ
    if argv[0] == "deploy":
        payload = build(DEPLOY_FIELDS, env)
        embed_array(payload, "components", env.get("COMPONENTS_JSON_FILE", ""))
        embed_array(payload, "findings", env.get("FINDINGS_JSON_FILE", ""))
    else:
        payload = build(MERGE_FIELDS, env)
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
