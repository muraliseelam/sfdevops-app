"""Tests for sf-pipeline/scripts/deploy_report.py.

The success, failed-test and component-failure fixtures are real `sf project deploy start
--dry-run --json` results from a scratch org (ids and URLs scrubbed).
"""

import json
import os
import tempfile
import unittest

from sfp_testutil import fixture, load_script, run_script, write

dr = load_script("deploy_report.py")


def deploy_fixture(name):
    return fixture("deploy", name)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def report(self, path, *extra):
        code, out, log = run_script("deploy_report.py", "--report-json", path, *extra)
        self.assertEqual(code, 0, log)
        return out, log

    def json_file(self, data, name="deploy.json"):
        return write(os.path.join(self.tmp.name, name), json.dumps(data) if not isinstance(data, str) else data)


class Success(Base):
    def test_success_with_coverage(self):
        summary = os.path.join(self.tmp.name, "summary.md")
        out, _ = self.report(deploy_fixture("success-coverage.json"), "--summary-file", summary)
        self.assertEqual(out["outcome"], "success")
        self.assertEqual(out["status"], "Succeeded")
        self.assertEqual(out["deploy_id"], "0Afh1000000NuXmCAK")
        self.assertEqual(out["coverage_percent"], "88.9")  # 8 of 9 lines
        self.assertEqual(out["tests_passed"], "true")
        self.assertEqual(out["failing_methods"], "")
        self.assertEqual(out["component_failures"], "")
        self.assertEqual(out["coverage_note"], "")
        self.assertEqual(out["coverage_ok"], "skipped")      # gate off by default
        with open(summary, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("### Deploy result: SUCCESS", text)
        self.assertIn("88.9%", text)
        self.assertIn("`0Afh1000000NuXmCAK`", text)

    def test_gate_on_and_coverage_above_threshold(self):
        out, _ = self.report(deploy_fixture("success-coverage.json"), "--coverage-gate", "true",
                             "--apex-changed", "true", "--threshold", "85", "--classes", "SfpFixtureCalc")
        self.assertEqual(out["outcome"], "success")
        self.assertEqual(out["coverage_ok"], "true")

    def test_status_succeeded_despite_a_non_zero_exit(self):
        # The CLI exited 1 (top-level status 1, lost connection while polling), but the org
        # says Succeeded: believe the org.
        out, _ = self.report(deploy_fixture("succeeded-nonzero-exit.json"))
        self.assertEqual(out["outcome"], "success")
        self.assertEqual(out["status"], "Succeeded")
        self.assertEqual(out["deploy_id"], "0Afh1000000NuXmCAK")
        self.assertIn("lost the connection", out["message"])

    def test_quick_deploy_has_no_coverage(self):
        out, _ = self.report(deploy_fixture("quick-deploy.json"), "--coverage-gate", "false")
        self.assertEqual(out["outcome"], "success")
        self.assertEqual(out["coverage_percent"], "")
        self.assertIn("no Apex tests ran", out["coverage_note"])
        self.assertEqual(out["tests_passed"], "false")
        self.assertEqual(out["coverage_ok"], "skipped")


class Failures(Base):
    def test_failed_tests(self):
        out, log = self.report(deploy_fixture("failed-tests.json"))
        self.assertEqual(out["outcome"], "failure")
        self.assertEqual(out["status"], "Failed")
        self.assertEqual(out["deploy_id"], "0Afh1000000NwRVCA0")
        self.assertEqual(out["tests_passed"], "false")
        self.assertEqual(out["failing_methods"],
                         "SfpFixtureCalcTest.doublesNumbers: System.AssertException: Assertion Failed: "
                         "twice(2) should be 4: Expected: 5, Actual: 4")
        self.assertEqual(out["coverage_percent"], "55.6")
        self.assertIn("::error", log)

    def test_component_failures(self):
        out, _ = self.report(deploy_fixture("component-failures.json"))
        self.assertEqual(out["outcome"], "failure")
        lines = out["component_failures"].splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0], "ApexClass SfpFixtureCalc: Variable does not exist: undefinedVar "
                                   "(classes/SfpFixtureCalc.cls:3:20)")
        self.assertIn("Dependent class is invalid", lines[1])
        self.assertEqual(out["coverage_percent"], "")
        self.assertIn("failed before any Apex test ran", out["coverage_note"])
        self.assertEqual(out["tests_passed"], "false")

    def test_component_failures_as_a_single_object(self):
        path = self.json_file({"status": 1, "result": {"id": "0Af1", "status": "Failed", "success": False,
                                                       "details": {"componentFailures": {
                                                           "componentType": "CustomField", "fullName": "Account.X__c",
                                                           "problem": "Field type\nis invalid", "fileName": "objects/Account/fields/X__c.field-meta.xml"}}}})
        out, _ = self.report(path)
        self.assertEqual(out["component_failures"],
                         "CustomField Account.X__c: Field type is invalid (objects/Account/fields/X__c.field-meta.xml)")

    def test_error_json_with_no_result(self):
        out, _ = self.report(deploy_fixture("error-no-result.json"))
        self.assertEqual(out["outcome"], "failure")
        self.assertEqual(out["status"], "NoOrgFound")
        self.assertEqual(out["deploy_id"], "")
        self.assertIn("No authorization information", out["message"])
        self.assertIn("did not return a result", out["coverage_note"])
        self.assertEqual(out["tests_passed"], "false")

    def test_unparseable_output(self):
        out, _ = self.report(self.json_file("Error: something exploded\n", "bad.json"))
        self.assertEqual(out["outcome"], "failure")
        self.assertEqual(out["status"], "Unknown")

    def test_json_after_a_warning_line_is_still_read(self):
        with open(deploy_fixture("success-coverage.json"), encoding="utf-8") as fh:
            text = "Warning: a newer CLI is available\n" + fh.read()
        out, _ = self.report(self.json_file(text, "noisy.json"))
        self.assertEqual(out["outcome"], "success")

    def test_in_progress_is_not_success(self):
        path = self.json_file({"status": 0, "result": {"id": "0Af2", "status": "InProgress", "done": False}})
        out, _ = self.report(path)
        self.assertEqual(out["outcome"], "failure")
        self.assertIn("not finished", out["message"])


class CoverageGate(Base):
    def test_below_threshold_fails_when_gate_on_and_apex_changed(self):
        out, log = self.report(deploy_fixture("success-coverage.json"), "--coverage-gate", "true",
                               "--apex-changed", "true", "--threshold", "90")
        self.assertEqual(out["outcome"], "failure")
        self.assertEqual(out["coverage_ok"], "false")
        self.assertEqual(out["status"], "Succeeded")        # the deploy itself was fine
        self.assertIn("below", log)

    def test_below_threshold_passes_when_gate_off(self):
        out, _ = self.report(deploy_fixture("success-coverage.json"), "--coverage-gate", "false",
                             "--apex-changed", "true", "--threshold", "90")
        self.assertEqual(out["outcome"], "success")
        self.assertEqual(out["coverage_ok"], "skipped")

    def test_below_threshold_passes_when_no_apex_changed(self):
        out, _ = self.report(deploy_fixture("success-coverage.json"), "--coverage-gate", "true",
                             "--apex-changed", "false", "--threshold", "90")
        self.assertEqual(out["outcome"], "success")
        self.assertEqual(out["coverage_ok"], "skipped")

    def coverage_result(self):
        return {"status": 0, "result": {"id": "0Af3", "status": "Succeeded", "success": True, "details": {
            "runTestResult": {"numTestsRun": "2", "numFailures": "0", "codeCoverage": [
                {"name": "Alpha", "numLocations": "10", "numLocationsNotCovered": "0"},
                {"name": "Beta", "numLocations": 10, "numLocationsNotCovered": 10},
            ]}}}}

    def test_coverage_is_restricted_to_the_changed_classes(self):
        path = self.json_file(self.coverage_result())
        self.assertEqual(self.report(path, "--classes", "Alpha")[0]["coverage_percent"], "100.0")
        self.assertEqual(self.report(path, "--classes", "alpha,Beta")[0]["coverage_percent"], "50.0")
        self.assertEqual(self.report(path)[0]["coverage_percent"], "50.0")
        out, _ = self.report(path, "--classes", "Gamma")
        self.assertEqual(out["coverage_percent"], "")
        self.assertIn("Gamma", out["coverage_note"])

    def test_bad_boolean_is_a_usage_error(self):
        code, _, _ = run_script("deploy_report.py", "--report-json", deploy_fixture("success-coverage.json"),
                                "--coverage-gate", "maybe")
        self.assertEqual(code, 2)

    def test_missing_file_is_a_usage_error(self):
        code, _, _ = run_script("deploy_report.py", "--report-json", os.path.join(self.tmp.name, "absent.json"))
        self.assertEqual(code, 2)

    def test_analyse_directly(self):
        out, facts = dr.analyse(self.coverage_result(), threshold=60, coverage_gate=True, apex_changed=True)
        self.assertEqual(out["coverage_ok"], "false")
        self.assertEqual(out["outcome"], "failure")
        self.assertEqual((facts["covered"], facts["total"]), (10, 20))


if __name__ == "__main__":
    unittest.main()
