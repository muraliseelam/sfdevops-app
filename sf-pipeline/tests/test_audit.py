"""Tests for sf-pipeline/scripts/audit.py (JSON-lines audit trail)."""

import json
import os
import re
import tempfile
import unittest
from datetime import datetime, timezone

from sfp_testutil import load_script, run_script

au = load_script("audit.py")
GH = {"GITHUB_ACTOR": "octo-dev", "GITHUB_REPOSITORY": "acme/sf-app", "GITHUB_SERVER_URL": "https://github.com",
      "GITHUB_RUN_ID": "4242"}


class Audit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = os.path.join(self.tmp.name, "nested", "audit.jsonl")

    def lines(self, path=None):
        with open(path or self.file, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def test_appends_one_line_per_event(self):
        code, _, log = run_script("audit.py", "--event", "Deploy", "--status", "Running", "--env", "qa",
                                  "--work-item", "WI-0032", "--sha", "abc123", "--file", self.file, env=GH)
        self.assertEqual(code, 0, log)
        code, _, _ = run_script("audit.py", "--event", "Deploy", "--status", "Success", "--file", self.file,
                                "--details", '{"deployId": "0Af1", "tests": 3}', env=GH)
        self.assertEqual(code, 0)
        first, second = self.lines()
        self.assertEqual(list(first), ["ts", "event", "status", "env", "workItem", "sha", "runUrl", "actor", "repo",
                                       "details"])
        self.assertRegex(first["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual((first["event"], first["status"], first["env"]), ("Deploy", "Running", "qa"))
        self.assertEqual((first["workItem"], first["sha"]), ("WI-0032", "abc123"))
        self.assertEqual(first["actor"], "octo-dev")
        self.assertEqual(first["repo"], "acme/sf-app")
        self.assertEqual(first["runUrl"], "https://github.com/acme/sf-app/actions/runs/4242")
        self.assertIsNone(first["details"])
        self.assertEqual(second["status"], "Success")
        self.assertIsNone(second["env"])
        self.assertEqual(second["details"], {"deployId": "0Af1", "tests": 3})
        self.assertIn('"event":"Deploy"', log)  # the line is printed

    def test_plain_text_details_and_explicit_run_url(self):
        rec = au.build_event("Merge", "Failed", details="target moved", run_url="https://example.invalid/r/1",
                             now=datetime(2026, 10, 13, 5, 52, 6, tzinfo=timezone.utc))
        self.assertEqual(rec["ts"], "2026-10-13T05:52:06Z")
        self.assertEqual(rec["details"], "target moved")
        self.assertEqual(rec["runUrl"], "https://example.invalid/r/1")
        self.assertEqual(au.parse_details("42"), "42")  # scalars stay strings

    def test_default_file_from_audit_file_env(self):
        target = os.path.join(self.tmp.name, "from-env.jsonl")
        code, _, _ = run_script("audit.py", "--event", "Commit", "--status", "Success", env={"AUDIT_FILE": target})
        self.assertEqual(code, 0)
        self.assertEqual(self.lines(target)[0]["event"], "Commit")

    def test_default_file_is_sgd_audit_jsonl(self):
        code, _, _ = run_script("audit.py", "--event", "Validation", "--status", "Success", cwd=self.tmp.name)
        self.assertEqual(code, 0)
        rec = self.lines(os.path.join(self.tmp.name, ".sgd", "audit.jsonl"))[0]
        self.assertIsNone(rec["actor"])
        self.assertIsNone(rec["runUrl"])

    def test_usage_errors(self):
        self.assertEqual(run_script("audit.py", "--status", "Success", "--file", self.file)[0], 2)
        self.assertEqual(run_script("audit.py", "--event", " ", "--status", "Success", "--file", self.file)[0], 2)
        self.assertFalse(os.path.exists(self.file))

    def test_timestamp_is_utc(self):
        rec = au.build_event("X", "Y")
        parsed = datetime.strptime(rec["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        self.assertLess(abs((datetime.now(timezone.utc) - parsed).total_seconds()), 120)
        self.assertTrue(re.match(r"^\d{4}-", rec["ts"]))


if __name__ == "__main__":
    unittest.main()
