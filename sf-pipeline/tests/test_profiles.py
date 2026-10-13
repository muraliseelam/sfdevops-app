"""Tests for sf-pipeline/scripts/profiles.py (full vs incremental profile shaping)."""

import os
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

from sfp_testutil import fixture, load_script, package_xml, run_script, write

pr = load_script("profiles.py")
NS = {"m": "http://soap.sforce.com/2006/04/metadata"}
FIXTURE_ROOT = fixture("profiles")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def slash(path):
    return os.path.normpath(path).replace(os.sep, "/")


def values(path, element, child):
    root = ET.parse(path).getroot()
    return [e.findtext(f"m:{child}", namespaces=NS) for e in root.findall(f"m:{element}", NS)]


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = os.path.join(tmp.name, "repo")
        shutil.copytree(FIXTURE_ROOT, self.root)
        self.source = os.path.join(self.root, "force-app")
        self.package = os.path.join(self.root, "package.xml")
        base = os.path.join(self.source, "main", "default")
        self.admin = os.path.join(base, "profiles", "Admin.profile-meta.xml")
        self.marketing = os.path.join(base, "profiles", "Custom%3A Marketing Profile.profile-meta.xml")
        self.permset = os.path.join(base, "permissionsets", "Sales_Ops.permissionset-meta.xml")

    def run_cli(self, mode, *extra):
        code, out, log = run_script("profiles.py", "--package", self.package, "--source-path", self.source,
                                    "--mode", mode, *extra)
        self.assertEqual(code, 0, log)
        return out, log


class Incremental(Base):
    def test_keeps_profile_settings_and_strips_out_of_delta_entries(self):
        out, _ = self.run_cli("incremental")
        # profile-level settings survive untouched
        self.assertEqual(values(self.admin, "userPermissions", "name"), ["ApiEnabled", "ViewSetup"])
        self.assertEqual(values(self.admin, "loginIpRanges", "startAddress"), ["10.0.0.0"])
        self.assertEqual(values(self.admin, "loginHours", "mondayStart"), ["480"])
        root = ET.parse(self.admin).getroot()
        self.assertEqual(root.findtext("m:custom", namespaces=NS), "false")
        self.assertEqual(root.findtext("m:userLicense", namespaces=NS), "Salesforce")
        self.assertEqual(root.findtext("m:description", namespaces=NS), "System administrator")
        # permission entries outside the delta are stripped, those inside are kept
        self.assertEqual(values(self.admin, "fieldPermissions", "field"), ["Account.Region__c", "Invoice__c.Amount__c"])
        self.assertEqual(values(self.admin, "classAccesses", "apexClass"), ["InvoiceService"])
        self.assertEqual(values(self.admin, "tabVisibilities", "tab"), ["Invoice__c"])
        self.assertEqual(values(self.admin, "objectPermissions", "object"), ["Invoice__c"])
        self.assertEqual(values(self.admin, "applicationVisibilities", "application"), ["Invoicing"])
        self.assertEqual(values(self.admin, "recordTypeVisibilities", "recordType"), ["Invoice__c.Standard"])
        self.assertEqual(values(self.admin, "layoutAssignments", "layout"), ["Invoice__c-Invoice Layout"])
        self.assertEqual(values(self.admin, "pageAccesses", "apexPage"), ["InvoicePdf"])
        self.assertEqual(values(self.admin, "flowAccesses", "flow"), ["Invoice_Approval"])
        self.assertEqual(values(self.admin, "customPermissions", "name"), ["Approve_Invoices"])
        self.assertEqual(values(self.admin, "customMetadataTypeAccesses", "name"), ["Invoice_Setting__mdt"])
        self.assertEqual(values(self.admin, "customSettingAccesses", "name"), [])
        # outputs
        changed = out["changed_files"].splitlines()
        self.assertEqual(len(changed), 3)
        self.assertIn(slash(self.admin), changed)
        self.assertIn("Profile `Admin`", out["summary"])
        self.assertIn("kept 12, stripped 12", out["summary"])
        self.assertIn("fieldPermissions 1", out["summary"])

    def test_permission_set_tab_settings_and_labels(self):
        self.run_cli("incremental")
        self.assertEqual(values(self.permset, "tabSettings", "tab"), ["Invoice__c"])
        self.assertEqual(values(self.permset, "classAccesses", "apexClass"), ["InvoiceService"])
        self.assertEqual(values(self.permset, "fieldPermissions", "field"), ["Invoice__c.Amount__c"])
        root = ET.parse(self.permset).getroot()
        for tag, expected in (("label", "Sales Ops"), ("description", "Sales operations"), ("license", "Salesforce"),
                              ("hasActivationRequired", "false")):
            self.assertEqual(root.findtext(f"m:{tag}", namespaces=NS), expected, tag)
        self.assertEqual(values(self.permset, "userPermissions", "name"), ["RunReports"])
        self.assertIn("<!-- Sales operations access -->", read(self.permset))

    def test_url_encoded_profile_name(self):
        out, _ = self.run_cli("incremental")
        self.assertEqual(values(self.marketing, "classAccesses", "apexClass"), ["InvoiceService"])
        self.assertIn("Custom: Marketing Profile", out["summary"])

    def test_output_keeps_the_metadata_format(self):
        self.run_cli("incremental")
        text = read(self.admin)
        self.assertTrue(text.startswith('<?xml version="1.0" encoding="UTF-8"?>\n<Profile xmlns="http://soap.sforce.com/2006/04/metadata">'))
        self.assertNotIn("ns0:", text)
        self.assertIn("\n    <userPermissions>\n        <enabled>true</enabled>", text)
        self.assertTrue(text.endswith("</Profile>\n"))
        self.assertNotIn("\r", text)

    def test_dry_run_reports_but_does_not_write(self):
        before = read(self.admin)
        out, _ = self.run_cli("incremental", "--dry-run")
        self.assertEqual(read(self.admin), before)
        self.assertIn(slash(self.admin), out["changed_files"].splitlines())
        self.assertIn("would strip 12", out["summary"])

    def test_a_profile_entirely_in_the_delta_is_not_rewritten(self):
        # Both classes the profile references are in the delta, so nothing needs stripping.
        write(self.package, package_xml({"ApexClass": ["InvoiceService", "MarketingOnly"],
                                         "Profile": ["Custom: Marketing Profile"]}))
        before = read(self.marketing)
        out, _ = self.run_cli("incremental")
        self.assertEqual(read(self.marketing), before)
        self.assertEqual(out["changed_files"], "")
        self.assertIn("kept 2, stripped 0", out["summary"])

    def test_wildcard_member_keeps_every_entry_of_that_type(self):
        write(self.package, package_xml({"CustomField": ["*"], "Profile": ["Admin"]}))
        self.run_cli("incremental")
        self.assertEqual(len(values(self.admin, "fieldPermissions", "field")), 3)
        self.assertEqual(values(self.admin, "classAccesses", "apexClass"), [])

    def test_profile_without_a_source_file_warns(self):
        write(self.package, package_xml({"Profile": ["Ghost"], "ApexClass": ["InvoiceService"]}))
        out, log = self.run_cli("incremental")
        self.assertIn("::warning::", log)
        self.assertIn("Ghost", out["summary"])
        self.assertEqual(out["changed_files"], "")


class Full(Base):
    def test_full_is_a_no_op(self):
        before = {p: read(p) for p in (self.admin, self.permset, self.marketing)}
        out, _ = self.run_cli("full")
        for path, text in before.items():
            self.assertEqual(read(path), text, path)
        self.assertEqual(out["changed_files"], "")
        self.assertIn("profiles_mode=full", out["summary"])


class Usage(Base):
    def test_bad_mode_is_a_usage_error(self):
        code, _, _ = run_script("profiles.py", "--package", self.package, "--source-path", self.source,
                                "--mode", "partial")
        self.assertEqual(code, 2)

    def test_missing_package_is_a_usage_error(self):
        code, _, log = run_script("profiles.py", "--package", os.path.join(self.root, "nope.xml"),
                                  "--source-path", self.source, "--mode", "incremental")
        self.assertEqual(code, 2)
        self.assertIn("not found", log)

    def test_no_profiles_in_the_delta(self):
        write(self.package, package_xml({"ApexClass": ["InvoiceService"]}))
        before = read(self.admin)
        changed, summary = pr.run(self.package, self.source, "incremental")
        self.assertEqual(changed, [])
        self.assertIn("no profiles", summary)
        self.assertEqual(read(self.admin), before)


if __name__ == "__main__":
    unittest.main()
