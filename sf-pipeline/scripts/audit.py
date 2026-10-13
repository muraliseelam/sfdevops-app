#!/usr/bin/env python3
"""audit.py - append one event to the pipeline's JSON-lines audit trail and print it.

Line shape:
  {"ts": "2026-10-13T05:52:06Z", "event": E, "status": S, "env": X, "workItem": W, "sha": SHA,
   "runUrl": URL, "actor": $GITHUB_ACTOR, "repo": $GITHUB_REPOSITORY, "details": D}
Fields that were not given are null. --details is stored as an object/array when it is JSON,
otherwise as a string. --run-url defaults to this workflow run when the GitHub variables are set.

Usage: audit.py --event E --status S [--env X] [--work-item W] [--sha SHA] [--run-url URL]
                [--details D] [--file F]
       --file defaults to $AUDIT_FILE, else .sgd/audit.jsonl
Exit codes: 0 appended, 1 cannot write the file, 2 usage error.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone


def default_run_url():
    server, repo, run_id = (os.environ.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    if server and repo and run_id:
        return f"{server}/{repo}/actions/runs/{run_id}"
    return None


def parse_details(value):
    if value is None or value == "":
        return None
    try:
        parsed = json.loads(value)
    except ValueError:
        return value
    return parsed if isinstance(parsed, (dict, list)) else value


def build_event(event, status, env=None, work_item=None, sha=None, run_url=None, details=None, now=None):
    now = now or datetime.now(timezone.utc)
    return {
        "ts": now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        "status": status,
        "env": env or None,
        "workItem": work_item or None,
        "sha": sha or None,
        "runUrl": run_url or default_run_url(),
        "actor": os.environ.get("GITHUB_ACTOR") or None,
        "repo": os.environ.get("GITHUB_REPOSITORY") or None,
        "details": parse_details(details),
    }


def append(path, record):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
    with open(path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(line + "\n")
    return line


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    p = argparse.ArgumentParser(prog="audit.py", description="Append one JSON line to the audit trail.")
    p.add_argument("--event", required=True)
    p.add_argument("--status", required=True)
    p.add_argument("--env", default="")
    p.add_argument("--work-item", default="")
    p.add_argument("--sha", default="")
    p.add_argument("--run-url", default="")
    p.add_argument("--details", default="")
    p.add_argument("--file", default=os.environ.get("AUDIT_FILE") or os.path.join(".sgd", "audit.jsonl"))
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    if not args.event.strip() or not args.status.strip():
        print("::error title=audit.py::--event and --status must not be empty")
        return 2
    record = build_event(args.event.strip(), args.status.strip(), args.env, args.work_item, args.sha,
                         args.run_url, args.details)
    try:
        line = append(args.file, record)
    except OSError as exc:
        print(f"::error title=audit.py::cannot append to {args.file}: {exc}")
        return 1
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
