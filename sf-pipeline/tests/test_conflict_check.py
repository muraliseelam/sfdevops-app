"""Tests for sf-pipeline/scripts/conflict-check.py (cross-work-item component overlaps)."""

import json
import os
import subprocess
import tempfile
import unittest

from sfp_testutil import load_script, run_script, write

cc = load_script("conflict-check.py")


class UniqueIdMapping(unittest.TestCase):
    CASES = {
        "force-app/main/default/classes/Foo.cls": "ApexClass:Foo",
        "force-app/main/default/classes/Foo.cls-meta.xml": "ApexClass:Foo",
        "force-app/main/default/triggers/AccountTrigger.trigger": "ApexTrigger:AccountTrigger",
        "force-app/main/default/lwc/widget/widget.js": "LightningComponentBundle:widget",
        "force-app/main/default/lwc/widget/__tests__/widget.test.js": "LightningComponentBundle:widget",
        "force-app/main/default/aura/Panel/PanelController.js": "AuraDefinitionBundle:Panel",
        "force-app/main/default/objects/Account/fields/Region__c.field-meta.xml": "CustomField:Account.Region__c",
        "force-app/main/default/objects/Invoice__c/Invoice__c.object-meta.xml": "CustomObject:Invoice__c",
        "force-app/main/default/objects/Account/listViews/All.listView-meta.xml": "ListView:Account.All",
        "force-app/main/default/objects/Account/recordTypes/Partner.recordType-meta.xml": "RecordType:Account.Partner",
        "force-app/main/default/objects/Account/validationRules/Need_Region.validationRule-meta.xml":
            "ValidationRule:Account.Need_Region",
        "force-app/main/default/layouts/Account-Account Layout.layout-meta.xml": "Layout:Account-Account Layout",
        "force-app/main/default/permissionsets/Sales_Ops.permissionset-meta.xml": "PermissionSet:Sales_Ops",
        "force-app/main/default/profiles/Admin.profile-meta.xml": "Profile:Admin",
        "force-app/main/default/flows/Invoice_Approval.flow-meta.xml": "Flow:Invoice_Approval",
        "force-app/main/default/flexipages/Invoice_Record.flexipage-meta.xml": "FlexiPage:Invoice_Record",
        "force-app/main/default/tabs/Invoice__c.tab-meta.xml": "CustomTab:Invoice__c",
        "force-app/main/default/applications/Invoicing.app-meta.xml": "CustomApplication:Invoicing",
        "force-app/main/default/staticresources/logo.png": "StaticResource:logo",
        "force-app/main/default/staticresources/logo.resource-meta.xml": "StaticResource:logo",
        "force-app/main/default/staticresources/bundle/js/app.js": "StaticResource:bundle",
        "force-app/main/default/customMetadata/Setting.Default.md-meta.xml": "CustomMetadata:Setting.Default",
        "force-app/main/default/labels/CustomLabels.labels-meta.xml": "CustomLabels:CustomLabels",
        "force-app/main/default/pages/InvoicePdf.page": "ApexPage:InvoicePdf",
        "force-app/main/default/components/Header.component-meta.xml": "ApexComponent:Header",
        "force-app/main/default/lwc/jsconfig.json": "Unknown:force-app/main/default/lwc/jsconfig.json",
        "force-app/main/default/documents/x.txt": "Unknown:force-app/main/default/documents/x.txt",
        "force-app\\main\\default\\classes\\Win.cls": "ApexClass:Win",
    }

    def test_path_conventions(self):
        for path, expected in self.CASES.items():
            self.assertEqual(cc.unique_id(path), expected, path)


class HubJson(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_overlaps_from_hub_rows(self):
        rows = [
            {"workItem": "WI-1", "uniqueId": "ApexClass:Foo"},
            {"workItem": "WI-2", "uniqueId": "ApexClass:Foo"},
            {"workItem": "WI-2", "uniqueId": "CustomField:Account.Region__c"},
            {"workItem": "WI-3", "uniqueId": "CustomField:Account.Region__c"},
            {"workItem": "WI-3", "uniqueId": "ApexClass:OnlyMine"},
            {"workItem": "WI-1", "uniqueId": "ApexClass:Foo"},  # duplicate row
        ]
        path = write(os.path.join(self.tmp.name, "hub.json"), json.dumps(rows))
        code, out, log = run_script("conflict-check.py", "--hub-json", path)
        self.assertEqual(code, 0, log)  # overlaps are a report, not a failure
        self.assertEqual(out["overlap_count"], "2")
        overlaps = json.loads(out["overlaps_json"])
        self.assertEqual(overlaps, [
            {"uniqueId": "ApexClass:Foo", "workItems": ["WI-1", "WI-2"]},
            {"uniqueId": "CustomField:Account.Region__c", "workItems": ["WI-2", "WI-3"]},
        ])
        self.assertIn("| `ApexClass:Foo` | WI-1, WI-2 |", out["report"])
        self.assertIn("Compared 3 in-flight work item(s)", out["report"])
        self.assertIn("::warning::", log)

    def test_no_overlaps(self):
        path = write(os.path.join(self.tmp.name, "hub.json"),
                     json.dumps([{"workItem": "WI-1", "uniqueId": "ApexClass:A"},
                                 {"workItem": "WI-2", "uniqueId": "ApexClass:B"}]))
        code, out, _ = run_script("conflict-check.py", "--hub-json", path)
        self.assertEqual(code, 0)
        self.assertEqual(out["overlap_count"], "0")
        self.assertEqual(json.loads(out["overlaps_json"]), [])
        self.assertIn("No overlapping components.", out["report"])

    def test_usage_errors(self):
        self.assertEqual(run_script("conflict-check.py")[0], 2)
        bad = write(os.path.join(self.tmp.name, "bad.json"), "{not json")
        self.assertEqual(run_script("conflict-check.py", "--hub-json", bad)[0], 2)
        self.assertEqual(run_script("conflict-check.py", "--hub-json", os.path.join(self.tmp.name, "absent.json"))[0], 2)
        self.assertEqual(run_script("conflict-check.py", "--git", "--repo-dir", self.tmp.name)[0], 2)  # no baseline


class GitBranches(unittest.TestCase):
    """A temp repo with a bare origin and three pushed feature branches."""

    def git(self, *args):
        subprocess.run(["git", "-C", self.repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                        "-c", "core.autocrlf=false", *args], check=True, capture_output=True, text=True)

    def put(self, rel, text="x\n"):
        write(os.path.join(self.repo, rel), text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        origin = os.path.join(self.tmp.name, "origin.git")
        self.repo = os.path.join(self.tmp.name, "work")
        subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        self.git("checkout", "-q", "-b", "main")
        self.git("remote", "add", "origin", origin)
        cls = "force-app/main/default/classes/"
        self.put(cls + "Foo.cls", "public class Foo {}\n")
        self.put(cls + "Bar.cls", "public class Bar {}\n")
        self.put("README.md", "readme\n")
        self.commit("base")
        self.git("push", "-q", "origin", "main")
        # WI-1: Foo + a field
        self.git("checkout", "-q", "-b", "feature/WI-1", "main")
        self.put(cls + "Foo.cls", "public class Foo { Integer a; }\n")
        self.put("force-app/main/default/objects/Account/fields/Region__c.field-meta.xml", "<x/>\n")
        self.commit("WI-1")
        # WI-2: Foo (meta file) + an LWC
        self.git("checkout", "-q", "-b", "feature/WI-2", "main")
        self.put(cls + "Foo.cls-meta.xml", "<meta/>\n")
        self.put("force-app/main/default/lwc/widget/widget.js", "export default {}\n")
        self.commit("WI-2")
        # WI-3: Bar + README (outside the source path)
        self.git("checkout", "-q", "-b", "feature/WI-3", "main")
        self.put(cls + "Bar.cls", "public class Bar { Integer b; }\n")
        self.put("README.md", "changed\n")
        self.commit("WI-3")
        # a branch that is not a feature branch
        self.git("checkout", "-q", "-b", "hotfix/x", "main")
        self.put(cls + "Bar.cls", "public class Bar { Integer h; }\n")
        self.commit("hotfix")
        # the baseline moves on after the cut: touching Foo on main must not count as WI work
        self.git("checkout", "-q", "main")
        self.put("force-app/main/default/lwc/widget/widget.js", "export default { later: true }\n")
        self.commit("main moves")
        for branch in ("main", "feature/WI-1", "feature/WI-2", "feature/WI-3", "hotfix/x"):
            self.git("push", "-q", "origin", branch)

    def test_git_overlaps(self):
        code, out, log = run_script("conflict-check.py", "--git", "--baseline", "origin/main",
                                    "--source-path", "force-app", cwd=self.repo)
        self.assertEqual(code, 0, log)
        overlaps = json.loads(out["overlaps_json"])
        self.assertEqual(out["overlap_count"], "1")
        self.assertEqual(overlaps[0]["uniqueId"], "ApexClass:Foo")
        self.assertEqual(overlaps[0]["workItems"], ["WI-1", "WI-2"])
        self.assertEqual(overlaps[0]["paths"], ["force-app/main/default/classes/Foo.cls",
                                                "force-app/main/default/classes/Foo.cls-meta.xml"])
        self.assertIn("Compared 3 in-flight work item(s)", out["report"])
        self.assertNotIn("hotfix", out["report"])
        self.assertNotIn("README", out["overlaps_json"])

    def test_git_and_hub_together(self):
        hub = write(os.path.join(self.tmp.name, "hub.json"),
                    json.dumps([{"workItem": "WI-9", "uniqueId": "ApexClass:Bar"}]))
        code, out, log = run_script("conflict-check.py", "--git", "--hub-json", hub, "--repo-dir", self.repo,
                                    env={"BASELINE_BRANCH": "main"})
        self.assertEqual(code, 0, log)
        ids = {o["uniqueId"]: o["workItems"] for o in json.loads(out["overlaps_json"])}
        self.assertEqual(ids, {"ApexClass:Foo": ["WI-1", "WI-2"], "ApexClass:Bar": ["WI-3", "WI-9"]})

    def test_custom_prefix_and_bad_baseline(self):
        code, out, _ = run_script("conflict-check.py", "--git", "--baseline", "origin/main",
                                  "--feature-prefix", "hotfix/", "--repo-dir", self.repo)
        self.assertEqual(code, 0)
        self.assertEqual(out["overlap_count"], "0")
        self.assertIn("Compared 1 in-flight work item(s)", out["report"])
        code, _, log = run_script("conflict-check.py", "--git", "--baseline", "origin/nope", "--repo-dir", self.repo)
        self.assertEqual(code, 2)
        self.assertIn("does not resolve", log)


if __name__ == "__main__":
    unittest.main()
