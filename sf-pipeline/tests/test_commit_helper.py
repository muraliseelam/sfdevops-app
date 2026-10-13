"""Tests for sf_paths.py and commit_helper.py."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.abspath(os.path.join(HERE, "..", "scripts"))
sys.path.insert(0, SCRIPTS)
import sf_paths  # noqa: E402

HELPER = os.path.join(SCRIPTS, "commit_helper.py")
DENY = os.path.abspath(os.path.join(HERE, "..", "config", "commit-denylist.txt"))


class PathMapping(unittest.TestCase):
    def test_common_types(self):
        cases = {
            "force-app/main/default/classes/Foo.cls": "ApexClass:Foo",
            "force-app/main/default/classes/Foo.cls-meta.xml": "ApexClass:Foo",
            "force-app/main/default/triggers/AccTrg.trigger": "ApexTrigger:AccTrg",
            "force-app/main/default/lwc/myCmp/myCmp.js": "LightningComponentBundle:myCmp",
            "force-app/main/default/aura/auraCmp/auraCmpController.js": "AuraDefinitionBundle:auraCmp",
            "force-app/main/default/objects/Invoice__c/Invoice__c.object-meta.xml": "CustomObject:Invoice__c",
            "force-app/main/default/objects/Invoice__c/fields/Total__c.field-meta.xml": "CustomField:Invoice__c.Total__c",
            "force-app/main/default/objects/Account/listViews/All.listView-meta.xml": "ListView:Account.All",
            "force-app/main/default/layouts/Invoice__c-Invoice Layout.layout-meta.xml": "Layout:Invoice__c-Invoice Layout",
            "force-app/main/default/permissionsets/Sales.permissionset-meta.xml": "PermissionSet:Sales",
            "force-app/main/default/labels/CustomLabels.labels-meta.xml": "CustomLabels:CustomLabels",
            "force-app/main/default/email/Support/Welcome.email-meta.xml": "EmailTemplate:Support/Welcome",
        }
        for path, expected in cases.items():
            self.assertEqual(sf_paths.unique_id(path), expected, path)

    def test_unknown(self):
        self.assertEqual(sf_paths.path_to_component("README.md")[0], "Unknown")


def run(*args, cwd=None):
    return subprocess.run([sys.executable, HELPER, *args], capture_output=True, text=True, cwd=cwd)


class Package(unittest.TestCase):
    def test_package_denylist_and_deletes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "pkg", "package.xml")
            comps = json.dumps([
                {"type": "ApexClass", "name": "Foo"},
                {"type": "ApexClass", "name": "Bar"},
                {"type": "CustomField", "name": "Invoice__c.Total__c"},
                {"type": "NamedCredential", "name": "Secret_API"},
                {"type": "ApexClass", "name": "Old", "action": "Delete"},
            ])
            r = run("package", "--components", comps, "--denylist", DENY, "--api", "66.0", "--out", out)
            self.assertEqual(r.returncode, 0, r.stderr)
            xml = open(out, encoding="utf-8").read()
            self.assertIn("<members>Bar</members>", xml)
            self.assertIn("<members>Foo</members>", xml)
            self.assertIn("<name>CustomField</name>", xml)
            self.assertNotIn("Secret_API", xml)
            self.assertNotIn("<members>Old</members>", xml)
            self.assertIn("retrieve_count=3", r.stdout)
            self.assertIn("delete_count=1", r.stdout)
            self.assertIn("denied=NamedCredential:Secret_API", r.stdout)
            deletes = json.load(open(os.path.join(tmp, "pkg", "deletes.json")))
            self.assertEqual(deletes[0]["name"], "Old")


class DeletesAndPayload(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@e")
        self.env = env
        g = lambda *a: subprocess.run(["git", "-c", "core.autocrlf=false", *a], cwd=self.repo, check=True,
                                      capture_output=True, env=env)
        self.g = g
        g("init", "-q")
        cls = os.path.join(self.repo, "force-app", "main", "default", "classes")
        os.makedirs(cls)
        for n in ("Keep", "Old", "Mod"):
            open(os.path.join(cls, f"{n}.cls"), "w").write(f"public class {n} {{}}\n")
            open(os.path.join(cls, f"{n}.cls-meta.xml"), "w").write("<x/>\n")
        g("add", ".")
        g("commit", "-qm", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def test_apply_deletes_then_payload(self):
        deletes = os.path.join(self.repo, "deletes.json")
        json.dump([{"type": "ApexClass", "name": "Old"}], open(deletes, "w"))
        r = run("apply-deletes", "--deletes", deletes, "--source-path", "force-app", cwd=self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("deleted_files=2", r.stdout)
        cls = os.path.join(self.repo, "force-app", "main", "default", "classes")
        open(os.path.join(cls, "Mod.cls"), "w").write("public class Mod { Integer x; }\n")
        open(os.path.join(cls, "New.cls"), "w").write("public class New {}\n")
        open(os.path.join(cls, "New.cls-meta.xml"), "w").write("<x/>\n")
        os.remove(deletes)
        self.g("add", "-A")
        self.g("commit", "-qm", "change")
        out = os.path.join(self.repo, "components.json")
        r = run("payload", "--from", "HEAD~1", "--to", "HEAD", "--source-path", "force-app", "--out", out,
                cwd=self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        comps = {c["uniqueId"]: c for c in json.load(open(out))}
        self.assertEqual(comps["ApexClass:Old"]["action"], "Delete")
        self.assertEqual(comps["ApexClass:New"]["action"], "Add")
        self.assertEqual(comps["ApexClass:Mod"]["action"], "Modify")
        self.assertNotIn("ApexClass:Keep", comps)
        self.assertEqual(len(comps["ApexClass:New"]["lastCommitSha"]), 40)


if __name__ == "__main__":
    unittest.main()
