"""Tests for sf-pipeline/scripts/plan.py.

The same code must resolve a 3-environment and a 5-environment chain, with different
branch names, without any change. Run: python3 -m unittest discover -s sf-pipeline/tests
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(ROOT, "sf-pipeline", "scripts", "plan.py")
FIX3 = os.path.join(HERE, "fixtures", "config-3env.yml")
FIX5 = os.path.join(HERE, "fixtures", "config-5env.yml")
REAL = os.path.join(ROOT, "sf-pipeline", "pipeline.config.yml")

spec = importlib.util.spec_from_file_location("plan", SCRIPT)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


def run_cli(config, *args):
    """Run plan.py as the workflows do and parse what it writes to $GITHUB_OUTPUT."""
    with tempfile.TemporaryDirectory() as tmp:
        out_file = os.path.join(tmp, "out")
        open(out_file, "w").close()
        env = dict(os.environ, GITHUB_OUTPUT=out_file)
        proc = subprocess.run([sys.executable, SCRIPT, "--config", config, *args],
                              capture_output=True, text=True, env=env)
        with open(out_file, encoding="utf-8") as fh:
            text = fh.read()
    outputs, lines, i = {}, text.splitlines(), 0
    while i < len(lines):
        line = lines[i]
        if "<<" in line and "=" not in line.split("<<", 1)[0]:
            key, delim = line.split("<<", 1)
            i += 1
            buf = []
            while lines[i] != delim:
                buf.append(lines[i])
                i += 1
            outputs[key] = "\n".join(buf)
        elif "=" in line:
            key, value = line.split("=", 1)
            outputs[key] = value
        i += 1
    return proc.returncode, outputs, proc.stdout + proc.stderr


class OutputsMode(unittest.TestCase):
    def test_three_env_chain(self):
        code, out, _ = run_cli(FIX3, "outputs")
        self.assertEqual(code, 0)
        auto = json.loads(out["auto_json"])
        self.assertEqual([e["name"] for e in auto], ["int", "qa", "stage"])
        self.assertEqual(out["env_count"], "3")
        self.assertEqual(out["entry_name"], "int")
        self.assertEqual(out["entry_branch"], "int")
        self.assertEqual(out["last_branch"], "stage")
        self.assertEqual(out["prod_branch"], "main")
        self.assertEqual(out["prod_name"], "prod")
        self.assertEqual(out["prod_validate_environment"], "prod-validate")
        self.assertEqual(out["destructive_tests"], "PipelineCanaryTest")
        self.assertEqual(out["delta_baseline"], "target")
        self.assertEqual(out["protected_branches"], "main stage qa int")
        chain = json.loads(out["chain_json"])
        self.assertEqual(len(chain), 4)
        self.assertTrue(chain[-1]["is_prod"])

    def test_normalize_defaults(self):
        code, out, _ = run_cli(FIX3, "outputs")
        auto = {e["name"]: e for e in json.loads(out["auto_json"])}
        # test_level defaults to RunSpecifiedTests, gh_environment defaults to the name
        self.assertEqual(auto["int"]["test_level"], "RunSpecifiedTests")
        self.assertEqual(auto["int"]["gh_environment"], "int")
        self.assertEqual(auto["qa"]["test_level"], "RunLocalTests")
        self.assertEqual(auto["stage"]["gh_environment"], "staging-org")
        self.assertTrue(auto["int"]["is_entry"])
        self.assertFalse(auto["qa"]["is_entry"])
        self.assertEqual(auto["qa"]["source_branch"], "int")

    def test_five_env_chain_same_code(self):
        code, out, _ = run_cli(FIX5, "outputs")
        self.assertEqual(code, 0)
        auto = json.loads(out["auto_json"])
        self.assertEqual([e["name"] for e in auto], ["int", "sit", "qa", "uat", "stage"])
        self.assertEqual([e["branch"] for e in auto],
                         ["env/int", "env/sit", "env/qa", "env/uat", "env/stage"])
        self.assertEqual(out["env_count"], "5")
        self.assertEqual(out["source_path"], "src/salesforce")
        self.assertEqual(out["baseline_branch"], "release-main")
        self.assertEqual(out["prod_name"], "production")
        self.assertEqual(out["release_branch_prefix"], "rel/")
        self.assertEqual(out["profiles_mode"], "incremental")
        self.assertEqual(out["coverage_threshold"], "80")
        self.assertEqual(out["gate_sonar"], "false")
        self.assertEqual(out["gate_pmd"], "true")
        self.assertEqual(out["delta_baseline"], "baseline")

    def test_real_config_is_valid(self):
        code, out, log = run_cli(REAL, "outputs")
        self.assertEqual(code, 0, log)
        self.assertGreaterEqual(int(out["env_count"]), 1)


class ResolveMode(unittest.TestCase):
    def test_entry_branch(self):
        code, out, _ = run_cli(FIX3, "resolve", "int")
        self.assertEqual(code, 0)
        self.assertEqual(out["r_found"], "true")
        self.assertEqual(out["r_name"], "int")
        self.assertEqual(out["r_gh_environment"], "int")
        self.assertEqual(out["r_test_level"], "RunSpecifiedTests")
        self.assertEqual(out["r_is_entry"], "true")

    def test_refs_heads_prefix(self):
        code, out, _ = run_cli(FIX5, "resolve", "refs/heads/env/uat")
        self.assertEqual(out["r_name"], "uat")
        self.assertEqual(out["r_test_level"], "RunLocalTests")
        self.assertEqual(out["r_is_entry"], "false")

    def test_prod_branch_validates_in_reviewer_free_env(self):
        code, out, _ = run_cli(FIX3, "resolve", "main")
        self.assertEqual(out["r_name"], "prod")
        self.assertEqual(out["r_gh_environment"], "prod-validate")
        self.assertEqual(out["r_is_prod"], "true")

    def test_unknown_branch_is_not_an_error(self):
        code, out, _ = run_cli(FIX3, "resolve", "feature/WI-0001")
        self.assertEqual(code, 0)
        self.assertEqual(out["r_found"], "false")


class PromoteMode(unittest.TestCase):
    def test_promote_middle_env(self):
        code, out, _ = run_cli(FIX3, "promote", "qa")
        self.assertEqual(code, 0)
        self.assertEqual(out["r_branch"], "qa")
        self.assertEqual(out["r_source_branch"], "int")
        self.assertEqual(out["r_gh_environment"], "qa")
        self.assertEqual(out["r_test_level"], "RunLocalTests")

    def test_promote_prod_sources_from_last_env(self):
        code, out, _ = run_cli(FIX5, "promote", "production")
        self.assertEqual(out["r_branch"], "release-main")
        self.assertEqual(out["r_source_branch"], "env/stage")
        self.assertEqual(out["r_gh_environment"], "production")
        self.assertEqual(out["r_validate_environment"], "production-validate")

    def test_promote_entry_is_refused(self):
        code, _, log = run_cli(FIX3, "promote", "int")
        self.assertEqual(code, 3)
        self.assertIn("entry environment", log)

    def test_promote_unknown(self):
        code, _, log = run_cli(FIX3, "promote", "uat")
        self.assertEqual(code, 3)
        self.assertIn("unknown environment", log)


class TargetMode(unittest.TestCase):
    def test_entry_flag_only_on_first(self):
        for name, expected in (("int", "true"), ("qa", "false"), ("stage", "false")):
            code, out, _ = run_cli(FIX3, "target", name)
            self.assertEqual(code, 0)
            self.assertEqual(out["r_is_entry"], expected, name)

    def test_target_five_env(self):
        code, out, _ = run_cli(FIX5, "target", "sit")
        self.assertEqual(out["r_branch"], "env/sit")
        self.assertEqual(out["r_prev"], "int")
        self.assertEqual(out["r_next"], "qa")
        code, out, _ = run_cli(FIX5, "target", "stage")
        self.assertEqual(out["r_next"], "production")

    def test_target_prod(self):
        code, out, _ = run_cli(FIX3, "target", "prod")
        self.assertEqual(out["r_is_prod"], "true")
        self.assertEqual(out["r_gh_environment"], "prod")
        self.assertEqual(out["r_validate_environment"], "prod-validate")


class SourceMode(unittest.TestCase):
    def test_source_org_default_and_explicit(self):
        code, out, _ = run_cli(FIX5, "source", "dev1")
        self.assertEqual(out["r_gh_environment"], "dev-one")
        code, out, _ = run_cli(FIX5, "source", "dev2")
        self.assertEqual(out["r_gh_environment"], "dev2")
        code, _, _ = run_cli(FIX5, "source", "nope")
        self.assertEqual(code, 3)


class Validation(unittest.TestCase):
    def check(self, cfg, needle):
        with self.assertRaises(plan.ConfigError) as ctx:
            plan.build_plan(cfg)
        self.assertIn(needle, str(ctx.exception))

    def base(self):
        return {"environments": [{"name": "int", "branch": "int"}],
                "production": {"branch": "main", "deploy_environment": "prod",
                               "validate_environment": "prod-validate"}}

    def test_requires_environments(self):
        cfg = self.base()
        cfg["environments"] = []
        self.check(cfg, "at least one environment")

    def test_duplicate_branch(self):
        cfg = self.base()
        cfg["environments"].append({"name": "qa", "branch": "int"})
        self.check(cfg, "duplicate branch")

    def test_bad_test_level(self):
        cfg = self.base()
        cfg["environments"][0]["test_level"] = "RunEverything"
        self.check(cfg, "test_level")

    def test_prod_branch_cannot_be_env_branch(self):
        cfg = self.base()
        cfg["production"]["branch"] = "int"
        self.check(cfg, "also an environment branch")

    def test_bad_delta_baseline(self):
        cfg = self.base()
        cfg["delta_baseline"] = "merge-base"
        self.check(cfg, "delta_baseline")

    def test_bad_profiles_mode(self):
        cfg = self.base()
        cfg["profiles_mode"] = "partial"
        self.check(cfg, "profiles_mode")

    def test_same_deploy_and_validate_env(self):
        cfg = self.base()
        cfg["production"]["validate_environment"] = "prod"
        self.check(cfg, "must differ")


if __name__ == "__main__":
    unittest.main()
