"""Tests for sf-pipeline/scripts/manifest_to_md.py."""

import os
import tempfile
import unittest

from sfp_testutil import load_script, package_xml, run_script, write

mm = load_script("manifest_to_md.py")


class ManifestToMarkdown(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def xml(self, name, types):
        return write(os.path.join(self.tmp.name, name), package_xml(types))

    def test_additions_and_deletions_tables(self):
        pkg = self.xml("package.xml", {"ApexClass": ["Zeta", "alpha", "Beta"], "CustomField": ["Account.Region__c"]})
        destructive = self.xml("destructiveChanges.xml", {"ApexTrigger": ["OldTrigger"]})
        out_file = os.path.join(self.tmp.name, "out", "manifest.md")
        code, _, log = run_script("manifest_to_md.py", "--package", pkg, "--destructive", destructive,
                                  "--title", "Validate WI-0032", "--out", out_file)
        self.assertEqual(code, 0, log)
        with open(out_file, encoding="utf-8") as fh:
            md = fh.read()
        self.assertTrue(md.startswith("## Validate WI-0032\n"))
        self.assertIn("| Type | Count | Members |", md)
        self.assertIn("| ApexClass | 3 | alpha, Beta, Zeta |", md)
        self.assertIn("| CustomField | 1 | Account.Region__c |", md)
        self.assertIn("### Deletions (destructiveChanges.xml)", md)
        self.assertIn("| ApexTrigger | 1 | OldTrigger |", md)
        self.assertIn("**Total:** 4 component(s) to deploy in 2 type(s); 1 component(s) to delete in 1 type(s).", md)
        self.assertIn(md, log)  # also printed to the log

    def test_no_deployable_changes(self):
        pkg = self.xml("package.xml", {})
        destructive = self.xml("destructiveChanges.xml", {})
        md = mm.render(mm.read_manifest(pkg), mm.read_manifest(destructive), "Deployment")
        self.assertEqual(md, "## Deployment\n\n_No deployable changes._\n")

    def test_deletions_only(self):
        md = mm.render({}, {"ApexClass": ["Gone"]}, "Deployment")
        self.assertIn("### Additions and changes\n\n_None._", md)
        self.assertIn("| ApexClass | 1 | Gone |", md)

    def test_pipes_are_escaped(self):
        md = mm.render({"Layout": ["Odd|Name"]}, {}, "T")
        self.assertIn("Odd\\|Name", md)

    def test_default_title_and_missing_destructive_file(self):
        pkg = self.xml("package.xml", {"ApexClass": ["Foo"]})
        code, _, log = run_script("manifest_to_md.py", "--package", pkg, "--destructive",
                                  os.path.join(self.tmp.name, "absent.xml"))
        self.assertEqual(code, 0, log)
        self.assertIn("## Deployment", log)
        self.assertNotIn("Deletions", log)

    def test_missing_package_is_a_usage_error(self):
        code, _, log = run_script("manifest_to_md.py", "--package", os.path.join(self.tmp.name, "absent.xml"))
        self.assertEqual(code, 2)
        self.assertIn("manifest not found", log)


if __name__ == "__main__":
    unittest.main()
