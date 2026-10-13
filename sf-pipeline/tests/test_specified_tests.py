"""Tests for sf-pipeline/scripts/specified_tests.py (the three-pass Apex test resolver)."""

import json
import os
import tempfile
import unittest
from unittest import mock

from sfp_testutil import fixture, load_script, package_xml, run_script, write

st = load_script("specified_tests.py")
SOURCE = fixture("apex", "force-app")
COVERAGE = fixture("apex", "apex-code-coverage.json")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def pkg(self, types, name="package.xml"):
        return write(os.path.join(self.tmp.name, name), package_xml(types))

    def run_cli(self, types, *extra, destructive=None):
        args = ["--package", self.pkg(types), "--source-path", SOURCE, *extra]
        if destructive is not None:
            args += ["--destructive", self.pkg(destructive, "destructiveChanges.xml")]
        code, out, log = run_script("specified_tests.py", *args)
        self.assertEqual(code, 0, log)
        self.assertNotIn("RunLocalTests", log, "RunLocalTests must never be emitted")
        self.assertNotIn("RunLocalTests", out.get("test_level", ""))
        return out, log


class CoverageMap(Base):
    def test_coverage_json_orders_by_lines_and_skips_managed_tests(self):
        out, _ = self.run_cli({"ApexClass": ["Orphan"]}, "--coverage-json", COVERAGE)
        self.assertEqual(out["apex_changed"], "true")
        # DataFactoryTest covers 30 lines, OrphanIntegrationSuite 12 (max over its methods);
        # PkgInstallTest is a managed-package test and is never named.
        self.assertEqual(out["tests"], "DataFactoryTest,OrphanIntegrationSuite")
        self.assertEqual(out["test_level"], "RunSpecifiedTests")
        self.assertEqual(out["unresolved"], "")
        self.assertIn("coverage map", out["report"])
        self.assertIn("up to 30 lines", out["report"])

    def test_coverage_and_naming_are_merged_without_duplicates(self):
        out, _ = self.run_cli({"ApexClass": ["AccountService"]}, "--coverage-json", COVERAGE)
        # AccountServiceTest comes from the coverage map (40 lines) and the naming convention.
        self.assertEqual(out["tests"], "AccountServiceTest,DataFactoryTest")
        self.assertEqual(out["tests"].count("AccountServiceTest"), 1)

    def test_unrelated_coverage_rows_are_ignored(self):
        out, _ = self.run_cli({"ApexClass": ["Ledger"]}, "--coverage-json", COVERAGE)
        self.assertNotIn("UnrelatedTest", out["tests"])

    def test_org_query_failure_falls_back_to_naming(self):
        with mock.patch.object(st.shutil, "which", return_value=None):
            records, error = st.query_coverage("int", ["AccountService"])
        self.assertEqual(records, [])
        self.assertIn("sf CLI is not on PATH", error)
        res = st.resolve(st.read_manifest(self.pkg({"ApexClass": ["AccountService"]})), st.scan_source(SOURCE),
                         coverage_records=None, coverage_error=error)
        self.assertEqual(res["tests"], ["AccountServiceTest"])
        self.assertTrue(any("Coverage map not used" in n for n in res["notes"]))


class NamingConvention(Base):
    def test_all_name_patterns_against_the_source_tree(self):
        out, _ = self.run_cli({"ApexClass": ["AccountService", "InvoiceBuilder", "Ledger"],
                               "ApexTrigger": ["AccountTrigger"]})
        self.assertEqual(out["tests"], "AccountServiceTest,InvoiceBuilder_Test,TestLedger,AccountTriggerTest")
        self.assertEqual(out["test_level"], "RunSpecifiedTests")
        self.assertEqual(out["unresolved"], "")
        self.assertIn("naming convention", out["report"])

    def test_a_class_named_like_a_test_that_is_not_a_test_is_skipped(self):
        out, _ = self.run_cli({"ApexClass": ["Helper", "AccountService"]})
        self.assertNotIn("HelperTest", out["tests"].split(","))
        self.assertEqual(out["unresolved"], "Helper")
        self.assertEqual(out["test_level"], "RunSpecifiedTests")

    def test_is_test_source_ignores_comments(self):
        self.assertTrue(st.is_test_source("@isTest\nprivate class X {}"))
        self.assertTrue(st.is_test_source("public class X { static testMethod void t() {} }"))
        self.assertTrue(st.is_test_source("@IsTest(SeeAllData=true) private class X {}"))
        self.assertFalse(st.is_test_source("// @isTest\npublic class X {}"))
        self.assertFalse(st.is_test_source("/* @isTest */ public class X {}"))


class ChangedTestClass(Base):
    def test_changed_test_class_is_run_and_resolves_what_it_references(self):
        out, _ = self.run_cli({"ApexClass": ["QuoteEngine", "QuoteEngineSpec"]})
        self.assertEqual(out["tests"], "QuoteEngineSpec")
        self.assertEqual(out["unresolved"], "")
        self.assertIn("changed test class", out["report"])

    def test_only_a_test_class_changed(self):
        out, _ = self.run_cli({"ApexClass": ["AccountServiceTest"]})
        self.assertEqual(out["apex_changed"], "true")
        self.assertEqual(out["tests"], "AccountServiceTest")
        self.assertEqual(out["test_level"], "RunSpecifiedTests")


class ExplicitOverride(Base):
    def test_explicit_overrides_every_pass(self):
        out, _ = self.run_cli({"ApexClass": ["AccountService", "Orphan"]}, "--coverage-json", COVERAGE,
                              "--explicit", " SmokeTest, RegressionTest ,SmokeTest")
        self.assertEqual(out["tests"], "SmokeTest,RegressionTest")
        self.assertEqual(out["test_level"], "RunSpecifiedTests")
        self.assertEqual(out["unresolved"], "")
        self.assertIn("explicit", out["report"])

    def test_explicit_does_not_read_the_coverage_file(self):
        out, _ = self.run_cli({"ApexClass": ["Orphan"]}, "--coverage-json", os.path.join(self.tmp.name, "absent.json"),
                              "--explicit", "OnlyThis")
        self.assertEqual(out["tests"], "OnlyThis")


class Cap(Base):
    def records(self):
        recs = [{"ApexTestClass": {"Name": f"UtilCover{n:02d}"}, "ApexClassOrTrigger": {"Name": "Util"},
                 "NumLinesCovered": n} for n in range(1, 41)]
        recs.append({"ApexTestClass": {"Name": "OtherCover"}, "ApexClassOrTrigger": {"Name": "Other"},
                     "NumLinesCovered": 1})
        return recs

    def test_cap_is_25_in_total_and_shared_fairly(self):
        path = write(os.path.join(self.tmp.name, "cov.json"), json.dumps({"result": {"records": self.records()}}))
        out, _ = self.run_cli({"ApexClass": ["Util", "Other"]}, "--coverage-json", path)
        tests = out["tests"].split(",")
        self.assertEqual(len(tests), 25)
        self.assertEqual(tests[0], "UtilCover40")           # best-covered first
        self.assertIn("OtherCover", tests)                   # the second class still gets its test
        self.assertNotIn("UtilCover01", tests)               # the tail of the shared utility is cut
        self.assertIn("capped at 25", out["report"])
        self.assertEqual(out["unresolved"], "")

    def test_custom_cap(self):
        res = st.resolve({"ApexClass": ["Util"]}, {}, coverage_records=self.records(), coverage_source="t", cap=3)
        self.assertEqual(res["tests"], ["UtilCover40", "UtilCover39", "UtilCover38"])

    def test_cap_must_be_positive(self):
        code, _, _ = run_script("specified_tests.py", "--package", self.pkg({}), "--source-path", SOURCE, "--cap", "0")
        self.assertEqual(code, 2)


class NothingResolves(Base):
    def test_apex_changed_but_nothing_resolves_leaves_the_level_empty(self):
        out, log = self.run_cli({"ApexClass": ["Orphan"]})
        self.assertEqual(out["apex_changed"], "true")
        self.assertEqual(out["tests"], "")
        self.assertEqual(out["test_level"], "")
        self.assertEqual(out["unresolved"], "Orphan")
        self.assertIn("OrphanTest", out["report"])           # tells the developer what to add
        self.assertIn("::warning::", log)

    def test_no_apex_in_the_delta(self):
        out, _ = self.run_cli({"CustomObject": ["Invoice__c"], "LightningComponentBundle": ["widget"]})
        self.assertEqual(out["apex_changed"], "false")
        self.assertEqual(out["tests"], "")
        self.assertEqual(out["test_level"], "")
        self.assertEqual(out["unresolved"], "")

    def test_never_run_local_tests(self):
        for types in ({"ApexClass": ["Orphan"]}, {"ApexClass": ["AccountService"]}, {}):
            res = st.resolve(types, st.scan_source(SOURCE))
            self.assertIn(res["test_level"], ("", "RunSpecifiedTests"))
            self.assertNotIn("RunLocalTests", st.render_report(res))


class Destructive(Base):
    def test_a_test_class_being_deleted_is_never_named(self):
        out, _ = self.run_cli({"ApexClass": ["Orphan"]}, "--coverage-json", COVERAGE,
                              destructive={"ApexClass": ["DataFactoryTest"]})
        self.assertEqual(out["tests"], "OrphanIntegrationSuite")

    def test_missing_package_is_a_usage_error(self):
        code, _, log = run_script("specified_tests.py", "--package", os.path.join(self.tmp.name, "nope.xml"),
                                  "--source-path", SOURCE)
        self.assertEqual(code, 2)
        self.assertIn("manifest not found", log)


if __name__ == "__main__":
    unittest.main()
