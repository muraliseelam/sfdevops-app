#!/usr/bin/env python3
"""seed-pipeline.py — generate the hub's pipeline records FROM pipeline.config.yml.

Configuration lives in two places and they must agree: the YAML drives GitHub, while
CDO_Project__c / CDO_Environment__c / CDO_Stage__c drive the hub. If they drift, promotions
target the wrong branch. So the hub's copy is never edited by hand: this script upserts it
from the YAML on external ids (Key__c), and `--check` reports any drift.

  seed-pipeline.py --org <hub alias>            upsert project, environments, stages, settings
  seed-pipeline.py --org <hub alias> --check    exit 1 if the hub disagrees with the YAML
  seed-pipeline.py --dry-run                    print the records it would write

Records
  CDO_Project__c      Key__c = hub.project_key, or the repository name
  CDO_Environment__c  one per source org, environment and production (Key__c = <project>:<key>)
  CDO_Stage__c        one per environment in chain order, then production (Key__c likewise);
                      Gate_Type__c Review on the entry stage, Self_Service in between,
                      Required_Reviewer on production
  CDO_Settings__c     org defaults: GitHub owner/repo, workflow ref (= baseline), project key
  Scheduled jobs      the promotion reconciler, every 15 minutes (skip with --no-schedule)

The org alias defaults to hub.org_alias from the config. Percent fields are written as
literal percents (85 means 85 %).
"""

import argparse
import csv
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import plan as planlib  # noqa: E402

CONFIG = os.path.join(ROOT, "sf-pipeline", "pipeline.config.yml")


def sf_exe():
    path = shutil.which("sf") or shutil.which("sf.cmd")
    if not path:
        raise SystemExit("the Salesforce CLI (sf) is not on PATH")
    return path


def repo_slug():
    try:
        url = subprocess.run(["git", "-C", ROOT, "remote", "get-url", "origin"], capture_output=True, text=True,
                             check=True).stdout.strip()
    except subprocess.CalledProcessError:
        return "", ""
    url = url[:-4] if url.endswith(".git") else url
    slug = url.split("github.com", 1)[-1].lstrip(":/")
    owner, _, name = slug.partition("/")
    return owner, name


def build_records(cfg, raw, owner, name):
    s, envs, prod = cfg["settings"], cfg["envs"], cfg["prod"]
    key = str((raw.get("hub") or {}).get("project_key") or name or "pipeline")
    with open(CONFIG, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    project = {
        "Key__c": key, "Name": name or key, "Repository__c": f"{owner}/{name}" if owner else name,
        "Baseline_Branch__c": s["baseline_branch"], "Delta_Baseline__c": s["delta_baseline"],
        "Coverage_Threshold__c": s["coverage_threshold"], "Source_Path__c": s["source_path"],
        "API_Version__c": s["api_version"], "Profiles_Mode__c": s["profiles_mode"], "Active__c": "true",
        "Config_Hash__c": digest,
        "Last_Seeded_On__c": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    environments, stages = [], []
    for o in cfg["source_orgs"]:
        environments.append({"Key__c": f"{key}:{o['name']}", "Name": o["name"], "Project__r.Key__c": key,
                             "Pipeline_Key__c": o["name"], "Type__c": "Source", "Branch__c": "",
                             "GitHub_Environment__c": o["gh_environment"], "Validate_Environment__c": "",
                             "Org_Alias__c": o["org_alias"], "Test_Level__c": ""})
    for e in envs:
        environments.append({"Key__c": f"{key}:{e['name']}", "Name": e["name"], "Project__r.Key__c": key,
                             "Pipeline_Key__c": e["name"], "Type__c": "Pipeline", "Branch__c": e["branch"],
                             "GitHub_Environment__c": e["gh_environment"], "Validate_Environment__c": "",
                             "Org_Alias__c": e["org_alias"], "Test_Level__c": e["test_level"]})
        stages.append({"Key__c": f"{key}:{e['name']}", "Name": e["name"], "Project__r.Key__c": key,
                       "Environment__r.Key__c": f"{key}:{e['name']}", "Order__c": str(e["order"]),
                       "Gate_Type__c": "Review" if e["is_entry"] else "Self_Service",
                       "Is_Entry__c": str(e["is_entry"]).lower(), "Is_Production__c": "false",
                       "Branch__c": e["branch"], "Pipeline_Key__c": e["name"], "Test_Level__c": e["test_level"]})
    environments.append({"Key__c": f"{key}:{prod['name']}", "Name": prod["name"], "Project__r.Key__c": key,
                         "Pipeline_Key__c": prod["name"], "Type__c": "Production", "Branch__c": prod["branch"],
                         "GitHub_Environment__c": prod["deploy_environment"],
                         "Validate_Environment__c": prod["validate_environment"],
                         "Org_Alias__c": prod["org_alias"], "Test_Level__c": prod["test_level"]})
    stages.append({"Key__c": f"{key}:{prod['name']}", "Name": prod["name"], "Project__r.Key__c": key,
                   "Environment__r.Key__c": f"{key}:{prod['name']}", "Order__c": str(len(envs) + 1),
                   "Gate_Type__c": "Required_Reviewer", "Is_Entry__c": "false", "Is_Production__c": "true",
                   "Branch__c": prod["branch"], "Pipeline_Key__c": prod["name"], "Test_Level__c": prod["test_level"]})
    settings = {"GitHub_Owner__c": owner, "GitHub_Repo__c": name, "Workflow_Ref__c": s["baseline_branch"],
                "Default_Project_Key__c": key}
    return key, project, environments, stages, settings


def write_csv(path, rows):
    cols = list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)


def sf_json(args):
    out = subprocess.run([sf_exe(), *args, "--json"], capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"status": 1, "message": out[:500]}


def upsert(org, sobject, rows, tmp):
    path = os.path.join(tmp, f"{sobject}.csv")
    write_csv(path, rows)
    res = sf_json(["data", "upsert", "bulk", "--sobject", sobject, "--file", path, "--external-id", "Key__c",
                   "--target-org", org, "--wait", "10", "--line-ending", "LF"])
    r = res.get("result") or {}
    failed = r.get("failedRecords") or r.get("numberRecordsFailed") or 0
    if res.get("status", 1) != 0 or (isinstance(failed, int) and failed > 0):
        raise SystemExit(f"upsert of {sobject} failed: {res.get('message') or json.dumps(r)[:800]}")
    print(f"  {sobject}: {len(rows)} upserted")


def query(org, soql):
    res = sf_json(["data", "query", "--query", soql, "--target-org", org])
    if res.get("status", 1) != 0:
        raise SystemExit(f"query failed: {res.get('message')}")
    return (res.get("result") or {}).get("records") or []


def seed_settings(org, settings):
    org_id = sf_json(["org", "display", "--target-org", org]).get("result", {}).get("id")
    existing = query(org, f"SELECT Id FROM CDO_Settings__c WHERE SetupOwnerId = '{org_id}'")
    values = " ".join(f"{k}='{v}'" for k, v in settings.items())
    if existing:
        res = sf_json(["data", "update", "record", "--sobject", "CDO_Settings__c", "--record-id", existing[0]["Id"],
                       "--values", values, "--target-org", org])
    else:
        res = sf_json(["data", "create", "record", "--sobject", "CDO_Settings__c",
                       "--values", f"SetupOwnerId='{org_id}' {values}", "--target-org", org])
    if res.get("status", 1) != 0:
        raise SystemExit(f"CDO_Settings__c org defaults failed: {res.get('message')}")
    print("  CDO_Settings__c: org defaults set")


RECONCILER = "SF DevOps reconciler"


def schedule_reconciler(org, tmp):
    """Every 15 minutes, sweep promotions whose workflow never called back (a status in the hub is
    not evidence a run started). Salesforce cron has no minute step, so four hourly jobs."""
    have = {r["CronJobDetail"]["Name"] for r in query(
        org, f"SELECT CronJobDetail.Name FROM CronTrigger WHERE CronJobDetail.Name LIKE '{RECONCILER}%'")}
    lines = []
    for minute in (0, 15, 30, 45):
        name = f"{RECONCILER} :{minute:02d}"
        if name not in have:
            lines.append(f"System.schedule('{name}', '0 {minute} * * * ?', new CDO_PromotionReconciler.ReconcileJob());")
    if not lines:
        print("  reconciler: already scheduled")
        return
    path = os.path.join(tmp, "schedule.apex")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    res = sf_json(["apex", "run", "--file", path, "--target-org", org])
    r = res.get("result") or {}
    if res.get("status", 1) != 0 or not r.get("success", False):
        raise SystemExit(f"scheduling the reconciler failed: {r.get('compileProblem') or r.get('exceptionMessage') or res.get('message')}")
    print(f"  reconciler: scheduled {len(lines)} job(s) (every 15 minutes)")


def check(org, key, environments, stages):
    drift = []
    got = {r["Key__c"]: r for r in query(org, f"SELECT Key__c, Branch__c, GitHub_Environment__c, Type__c FROM CDO_Environment__c WHERE Project__r.Key__c = '{key}'")}
    for e in environments:
        g = got.get(e["Key__c"])
        if not g:
            drift.append(f"missing environment {e['Key__c']}")
        elif (g.get("Branch__c") or "") != e["Branch__c"] or g.get("GitHub_Environment__c") != e["GitHub_Environment__c"]:
            drift.append(f"environment {e['Key__c']}: hub says branch={g.get('Branch__c')} env={g.get('GitHub_Environment__c')}, YAML says branch={e['Branch__c']} env={e['GitHub_Environment__c']}")
    got_s = {r["Key__c"]: r for r in query(org, f"SELECT Key__c, Order__c, Branch__c FROM CDO_Stage__c WHERE Project__r.Key__c = '{key}'")}
    for st in stages:
        g = got_s.get(st["Key__c"])
        if not g:
            drift.append(f"missing stage {st['Key__c']}")
        elif int(g.get("Order__c") or 0) != int(st["Order__c"]) or g.get("Branch__c") != st["Branch__c"]:
            drift.append(f"stage {st['Key__c']}: hub order={g.get('Order__c')} branch={g.get('Branch__c')}, YAML order={st['Order__c']} branch={st['Branch__c']}")
    extra = set(got_s) - {s["Key__c"] for s in stages}
    drift += [f"stage {k} exists in the hub but not in the YAML" for k in sorted(extra)]
    return drift


def main(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--org", default="", help="hub org alias (default: hub.org_alias)")
    p.add_argument("--check", action="store_true", help="report drift; write nothing")
    p.add_argument("--dry-run", action="store_true", help="print the records; write nothing")
    p.add_argument("--no-schedule", action="store_true", help="do not schedule the hub's promotion reconciler")
    a = p.parse_args(argv)
    raw = planlib.load_yaml(CONFIG)
    cfg = planlib.build_plan(raw)
    owner, name = repo_slug()
    key, project, environments, stages, settings = build_records(cfg, raw, owner, name)
    org = a.org or cfg["settings"]["hub_org_alias"]
    if a.dry_run:
        print(json.dumps({"project": project, "environments": environments, "stages": stages, "settings": settings}, indent=2))
        return 0
    if not org:
        raise SystemExit("no hub org: pass --org or set hub.org_alias in pipeline.config.yml")
    if a.check:
        drift = check(org, key, environments, stages)
        for d in drift:
            print(f"DRIFT: {d}")
        print("hub matches pipeline.config.yml" if not drift else f"{len(drift)} difference(s); run seed-pipeline.py to fix")
        return 1 if drift else 0
    print(f"Seeding project '{key}' into {org} from pipeline.config.yml")
    with tempfile.TemporaryDirectory() as tmp:
        upsert(org, "CDO_Project__c", [project], tmp)
        upsert(org, "CDO_Environment__c", environments, tmp)
        upsert(org, "CDO_Stage__c", stages, tmp)
        seed_settings(org, settings)
        if not a.no_schedule:
            schedule_reconciler(org, tmp)
    drift = check(org, key, environments, stages)
    print("verified: hub matches pipeline.config.yml" if not drift else "\n".join(drift))
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
