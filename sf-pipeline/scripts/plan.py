#!/usr/bin/env python3
"""plan.py — turn sf-pipeline/pipeline.config.yml into GitHub Actions outputs.

Every workflow runs this in a `plan` job and consumes its outputs, so no workflow
ever names an environment, a branch or an org count.

Modes
  outputs              every pipeline setting, plus auto_json: the ordered environment
                       list that drives dynamic matrices (works for any org count)
  resolve <branch>     the environment a PR into <branch> validates against
                       (r_found, r_name, r_gh_environment, r_test_level, r_is_entry, r_is_prod)
  promote <env>        a manual env->env promotion target
                       (r_name, r_gh_environment, r_branch, r_source_branch, r_test_level)
  target  <env>        one environment's branch + GitHub Environment + test level,
                       plus r_is_entry (true only for the first environment in the chain)
  source  <name>       a developer source org's GitHub Environment (commit workflows)

Outputs are appended to $GITHUB_OUTPUT when it is set; otherwise they are printed as
key=value lines. Exit codes: 0 ok, 2 invalid config, 3 unknown environment or org.

Usage: plan.py [--config PATH] <mode> [argument]
       (PIPELINE_CONFIG may also point at the config file)
"""

import json
import os
import sys
import uuid

DEFAULT_CONFIG = os.path.join("sf-pipeline", "pipeline.config.yml")
VALID_TEST_LEVELS = ("NoTestRun", "RunSpecifiedTests", "RunLocalTests", "RunAllTestsInOrg")
DEFAULT_TEST_LEVEL = "RunSpecifiedTests"


class ConfigError(Exception):
    """The config file is missing something or contradicts itself."""


class UnknownTarget(Exception):
    """A mode argument names an environment or org the config does not define."""


def load_yaml(path):
    try:
        import yaml  # preinstalled on GitHub-hosted runners
    except ImportError:
        import subprocess

        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "pyyaml"])
        import yaml
    if not os.path.isfile(path):
        raise ConfigError(f"config file not found: {path}")
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: expected a mapping at the top level")
    return data


def _bool(value, default):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _test_level(value, where):
    level = str(value or DEFAULT_TEST_LEVEL)
    if level not in VALID_TEST_LEVELS:
        raise ConfigError(f"{where}: test_level '{level}' is not one of {', '.join(VALID_TEST_LEVELS)}")
    return level


def strip_ref(branch):
    branch = str(branch or "").strip()
    for prefix in ("refs/heads/", "origin/"):
        if branch.startswith(prefix):
            branch = branch[len(prefix):]
    return branch


def normalize_envs(cfg):
    """Ordered promotion chain. Defaults test_level to RunSpecifiedTests and
    gh_environment to the environment name."""
    raw_envs = cfg.get("environments") or []
    if not isinstance(raw_envs, list) or not raw_envs:
        raise ConfigError("environments: at least one environment is required")
    envs, names, branches = [], set(), set()
    for i, raw in enumerate(raw_envs):
        where = f"environments[{i}]"
        if not isinstance(raw, dict) or not raw.get("name") or not raw.get("branch"):
            raise ConfigError(f"{where}: 'name' and 'branch' are required")
        name, branch = str(raw["name"]), strip_ref(raw["branch"])
        if name in names:
            raise ConfigError(f"{where}: duplicate environment name '{name}'")
        if branch in branches:
            raise ConfigError(f"{where}: duplicate branch '{branch}'")
        names.add(name)
        branches.add(branch)
        envs.append({
            "name": name,
            "branch": branch,
            "gh_environment": str(raw.get("gh_environment") or name),
            "test_level": _test_level(raw.get("test_level"), where),
            "org_alias": str(raw.get("org_alias") or ""),
            "index": i,
            "order": i + 1,
            "is_entry": i == 0,
        })
    for i, env in enumerate(envs):
        env["source_branch"] = envs[i - 1]["branch"] if i > 0 else ""
        env["prev"] = envs[i - 1]["name"] if i > 0 else ""
        env["next"] = envs[i + 1]["name"] if i + 1 < len(envs) else ""
    return envs


def normalize_production(cfg, envs):
    prod = cfg.get("production")
    if not isinstance(prod, dict) or not prod.get("branch"):
        raise ConfigError("production.branch is required")
    name = str(prod.get("name") or "prod")
    branch = strip_ref(prod["branch"])
    if name in {e["name"] for e in envs}:
        raise ConfigError(f"production.name '{name}' collides with an environment name")
    if branch in {e["branch"] for e in envs}:
        raise ConfigError(f"production.branch '{branch}' is also an environment branch")
    deploy_env = str(prod.get("deploy_environment") or name)
    validate_env = str(prod.get("validate_environment") or f"{deploy_env}-validate")
    if deploy_env == validate_env:
        raise ConfigError("production.deploy_environment and validate_environment must differ "
                          "(the validate environment has no reviewers; the deploy one does)")
    return {
        "name": name,
        "branch": branch,
        "deploy_environment": deploy_env,
        "validate_environment": validate_env,
        "gh_environment": deploy_env,
        "release_branch_prefix": str(prod.get("release_branch_prefix") or "release/"),
        "test_level": _test_level(prod.get("test_level"), "production"),
        "destructive_tests": str(prod.get("destructive_tests") or "").strip(),
        "org_alias": str(prod.get("org_alias") or ""),
        "source_branch": envs[-1]["branch"],
        "prev": envs[-1]["name"],
    }


def normalize_source_orgs(cfg):
    orgs, names = [], set()
    for i, raw in enumerate(cfg.get("source_orgs") or []):
        if not isinstance(raw, dict) or not raw.get("name"):
            raise ConfigError(f"source_orgs[{i}]: 'name' is required")
        name = str(raw["name"])
        if name in names:
            raise ConfigError(f"source_orgs[{i}]: duplicate source org '{name}'")
        names.add(name)
        orgs.append({
            "name": name,
            "gh_environment": str(raw.get("gh_environment") or name),
            "org_alias": str(raw.get("org_alias") or ""),
            "description": str(raw.get("description") or ""),
        })
    return orgs


def build_plan(cfg):
    envs = normalize_envs(cfg)
    prod = normalize_production(cfg, envs)
    orgs = normalize_source_orgs(cfg)

    delta_baseline = str(cfg.get("delta_baseline") or "target")
    if delta_baseline not in ("baseline", "target"):
        raise ConfigError(f"delta_baseline '{delta_baseline}' must be 'baseline' or 'target'")
    profiles_mode = str(cfg.get("profiles_mode") or "full")
    if profiles_mode not in ("full", "incremental"):
        raise ConfigError(f"profiles_mode '{profiles_mode}' must be 'full' or 'incremental'")
    try:
        threshold = float(cfg.get("coverage_threshold", 85))
    except (TypeError, ValueError):
        raise ConfigError("coverage_threshold must be a number")
    if not 0 <= threshold <= 100:
        raise ConfigError("coverage_threshold must be between 0 and 100")

    gates = cfg.get("quality_gates") or {}
    prefixes = cfg.get("branch_prefixes") or {}
    notifications = cfg.get("notifications") or {}
    hub = cfg.get("hub") or {}

    return {
        "envs": envs,
        "prod": prod,
        "source_orgs": orgs,
        "settings": {
            "source_path": str(cfg.get("source_path") or "force-app").rstrip("/"),
            "api_version": str(cfg.get("api_version") or "66.0"),
            "node_version": str(cfg.get("node_version") or "22"),
            "baseline_branch": strip_ref(cfg.get("baseline_branch") or prod["branch"]),
            "delta_baseline": delta_baseline,
            "coverage_threshold": f"{threshold:g}",
            "profiles_mode": profiles_mode,
            "approved_label": str(cfg.get("approved_label") or "approved"),
            "bypass_label": str(cfg.get("bypass_label") or "bypass-quality-gates"),
            "feature_prefix": str(prefixes.get("feature") or "feature/"),
            "promotion_prefix": str(prefixes.get("promotion") or "promotion/"),
            "gate_pmd": _bool(gates.get("pmd"), True),
            "gate_sonar": _bool(gates.get("sonar"), True),
            "gate_apex_coverage": _bool(gates.get("apex_coverage"), True),
            "gate_jest": _bool(gates.get("jest"), True),
            "notify_webex": _bool(notifications.get("webex"), False),
            "hub_org_alias": str(hub.get("org_alias") or ""),
        },
    }


def _fmt(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (list, dict)):
        return json.dumps(value, separators=(",", ":"))
    return str(value)


def mode_outputs(plan):
    envs, prod, s = plan["envs"], plan["prod"], plan["settings"]
    auto = [{k: e[k] for k in ("name", "branch", "gh_environment", "test_level", "source_branch",
                                "is_entry", "order")} for e in envs]
    chain = auto + [{"name": prod["name"], "branch": prod["branch"],
                     "gh_environment": prod["deploy_environment"], "test_level": prod["test_level"],
                     "source_branch": prod["source_branch"], "is_entry": False,
                     "order": len(envs) + 1, "is_prod": True}]
    out = dict(s)
    out.update({
        "env_count": len(envs),
        "env_names": " ".join(e["name"] for e in envs),
        "env_branches": " ".join(e["branch"] for e in envs),
        "entry_name": envs[0]["name"],
        "entry_branch": envs[0]["branch"],
        "entry_gh_environment": envs[0]["gh_environment"],
        "last_name": envs[-1]["name"],
        "last_branch": envs[-1]["branch"],
        "prod_name": prod["name"],
        "prod_branch": prod["branch"],
        "prod_deploy_environment": prod["deploy_environment"],
        "prod_validate_environment": prod["validate_environment"],
        "prod_test_level": prod["test_level"],
        "release_branch_prefix": prod["release_branch_prefix"],
        "destructive_tests": prod["destructive_tests"],
        "auto_json": auto,
        "chain_json": chain,
        "source_orgs_json": [{"name": o["name"], "gh_environment": o["gh_environment"]}
                             for o in plan["source_orgs"]],
        "protected_branches": " ".join([prod["branch"]] + [e["branch"] for e in reversed(envs)]),
    })
    return out


def _find_env(plan, name):
    for env in plan["envs"]:
        if env["name"] == name:
            return env
    return None


def _known(plan):
    return ", ".join([e["name"] for e in plan["envs"]] + [plan["prod"]["name"]])


def mode_resolve(plan, branch):
    branch = strip_ref(branch)
    prod = plan["prod"]
    for env in plan["envs"]:
        if env["branch"] == branch:
            return {"r_found": True, "r_name": env["name"], "r_gh_environment": env["gh_environment"],
                    "r_test_level": env["test_level"], "r_branch": env["branch"],
                    "r_is_entry": env["is_entry"], "r_is_prod": False}
    if branch == prod["branch"]:
        # A PR into production validates in the reviewer-free environment.
        return {"r_found": True, "r_name": prod["name"], "r_gh_environment": prod["validate_environment"],
                "r_test_level": prod["test_level"], "r_branch": prod["branch"],
                "r_is_entry": False, "r_is_prod": True}
    return {"r_found": False, "r_name": "", "r_gh_environment": "", "r_test_level": "",
            "r_branch": branch, "r_is_entry": False, "r_is_prod": False}


def mode_target(plan, name):
    env = _find_env(plan, name)
    prod = plan["prod"]
    if env:
        return {"r_name": env["name"], "r_branch": env["branch"], "r_gh_environment": env["gh_environment"],
                "r_test_level": env["test_level"], "r_is_entry": env["is_entry"], "r_is_prod": False,
                "r_order": env["order"], "r_prev": env["prev"], "r_next": env["next"] or prod["name"],
                "r_source_branch": env["source_branch"], "r_org_alias": env["org_alias"]}
    if name == prod["name"]:
        return {"r_name": prod["name"], "r_branch": prod["branch"], "r_gh_environment": prod["deploy_environment"],
                "r_validate_environment": prod["validate_environment"], "r_test_level": prod["test_level"],
                "r_is_entry": False, "r_is_prod": True, "r_order": len(plan["envs"]) + 1,
                "r_prev": prod["prev"], "r_next": "", "r_source_branch": prod["source_branch"],
                "r_org_alias": prod["org_alias"]}
    raise UnknownTarget(f"unknown environment '{name}' (known: {_known(plan)})")


def mode_promote(plan, name):
    env = _find_env(plan, name)
    prod = plan["prod"]
    if env:
        if env["is_entry"]:
            raise UnknownTarget(f"'{name}' is the entry environment; it is fed by feature branches "
                                "through sf-promotion / sf-int-deploy, not by a whole-branch promotion")
        return {"r_name": env["name"], "r_gh_environment": env["gh_environment"], "r_branch": env["branch"],
                "r_source_branch": env["source_branch"], "r_test_level": env["test_level"],
                "r_is_prod": False}
    if name == prod["name"]:
        return {"r_name": prod["name"], "r_gh_environment": prod["deploy_environment"],
                "r_validate_environment": prod["validate_environment"], "r_branch": prod["branch"],
                "r_source_branch": prod["source_branch"], "r_test_level": prod["test_level"],
                "r_is_prod": True}
    raise UnknownTarget(f"unknown environment '{name}' (known: {_known(plan)})")


def mode_source(plan, name):
    for org in plan["source_orgs"]:
        if org["name"] == name:
            return {"r_name": org["name"], "r_gh_environment": org["gh_environment"]}
    known = ", ".join(o["name"] for o in plan["source_orgs"]) or "none configured"
    raise UnknownTarget(f"unknown source org '{name}' (known: {known})")


def emit(outputs, stream=None):
    lines = []
    for key, value in outputs.items():
        text = _fmt(value)
        if "\n" in text:
            delim = f"EOF_{uuid.uuid4().hex}"
            lines.append(f"{key}<<{delim}\n{text}\n{delim}")
        else:
            lines.append(f"{key}={text}")
    payload = "\n".join(lines) + "\n"
    target = os.environ.get("GITHUB_OUTPUT")
    if stream is not None:
        stream.write(payload)
    elif target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(payload)
        # Echo to the log too, so a run shows what it resolved.
        sys.stdout.write(payload)
    else:
        sys.stdout.write(payload)


MODES = {
    "outputs": (0, lambda plan, args: mode_outputs(plan)),
    "resolve": (1, lambda plan, args: mode_resolve(plan, args[0])),
    "promote": (1, lambda plan, args: mode_promote(plan, args[0])),
    "target": (1, lambda plan, args: mode_target(plan, args[0])),
    "source": (1, lambda plan, args: mode_source(plan, args[0])),
}


def run(argv):
    args = list(argv)
    config = os.environ.get("PIPELINE_CONFIG") or DEFAULT_CONFIG
    if len(args) >= 2 and args[0] == "--config":
        config = args[1]
        args = args[2:]
    if not args or args[0] not in MODES:
        sys.stderr.write(__doc__)
        return 2
    mode, rest = args[0], args[1:]
    nargs, fn = MODES[mode]
    if len(rest) != nargs:
        sys.stderr.write(f"plan.py {mode}: expected {nargs} argument(s)\n")
        return 2
    try:
        plan = build_plan(load_yaml(config))
        emit(fn(plan, rest))
    except ConfigError as exc:
        print(f"::error title=pipeline.config.yml::{exc}")
        return 2
    except UnknownTarget as exc:
        print(f"::error title=plan.py {mode}::{exc}")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
