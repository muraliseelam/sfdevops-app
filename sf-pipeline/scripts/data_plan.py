#!/usr/bin/env python3
"""data_plan.py — turn a hub data-set plan into ordered export/upsert steps.

Input (sf-data-deploy input `plan`, base64 of docs/CONTRACTS.md §5):
  {"dataSet": "...",
   "templates": [{"name","object","fields":[..],"filter","externalId","order","limit"}],
   "relationships": [{"parent": <template name>, "child": <template name>, "field": "AccountId"}]}

Records are moved by external id, never by Salesforce Id (Ids differ between orgs). A child's
lookup field is therefore exported as `<Relationship>.<parent external id>` (AccountId →
Account.External_Id__c, Parent__c → Parent__r.External_Id__c), which Bulk API upserts resolve
in the target org. Parents are ordered before children.

  data_plan.py steps --plan-b64 <b64> --out steps.json
      writes [{"name","object","soql","file","externalId"}] in dependency order
"""

import argparse
import base64
import json
import re
import sys

SAFE_NAME = re.compile(r"[^A-Za-z0-9_.-]+")
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$")


class PlanError(Exception):
    pass


def relationship_name(field):
    if field.endswith("__c"):
        return field[:-3] + "__r"
    if field.endswith("Id") and len(field) > 2:
        return field[:-2]
    raise PlanError(f"cannot derive a relationship name from lookup field '{field}'")


def order_templates(templates, relationships):
    names = {t["name"] for t in templates}
    deps = {t["name"]: set() for t in templates}
    for r in relationships:
        if r["parent"] not in names or r["child"] not in names:
            raise PlanError(f"relationship {r} names an unknown template")
        deps[r["child"]].add(r["parent"])
    by_order = sorted(templates, key=lambda t: (int(t.get("order") or 0), t["name"]))
    done, out = set(), []
    while len(out) < len(by_order):
        progressed = False
        for t in by_order:
            if t["name"] not in done and deps[t["name"]] <= done:
                out.append(t)
                done.add(t["name"])
                progressed = True
        if not progressed:
            raise PlanError("relationships form a cycle: " + ", ".join(sorted(set(names) - done)))
    return out


def build_steps(plan):
    templates = plan.get("templates") or []
    relationships = plan.get("relationships") or []
    if not templates:
        raise PlanError("the plan has no templates")
    by_name = {t["name"]: t for t in templates}
    steps = []
    for i, t in enumerate(order_templates(templates, relationships), start=1):
        obj, ext = t.get("object", ""), t.get("externalId", "")
        if not IDENT.match(obj or ""):
            raise PlanError(f"template '{t['name']}': invalid object '{obj}'")
        if not ext or not IDENT.match(ext):
            raise PlanError(f"template '{t['name']}': an external id field is required to move records between orgs")
        fields = [f.strip() for f in (t.get("fields") or []) if f and f.strip()]
        for r in relationships:
            if r["child"] != t["name"]:
                continue
            parent = by_name[r["parent"]]
            lookup = r["field"]
            fields = [f for f in fields if f != lookup]
            fields.append(f"{relationship_name(lookup)}.{parent['externalId']}")
        if ext not in fields:
            fields.insert(0, ext)
        for f in fields:
            if not IDENT.match(f):
                raise PlanError(f"template '{t['name']}': invalid field '{f}'")
        soql = f"SELECT {', '.join(dict.fromkeys(fields))} FROM {obj}"
        if t.get("filter"):
            soql += f" WHERE {t['filter']}"
        if t.get("limit"):
            soql += f" LIMIT {int(t['limit'])}"
        steps.append({"name": t["name"], "object": obj, "soql": soql,
                      "file": f"data/{i:02d}-{SAFE_NAME.sub('_', t['name'])}.csv", "externalId": ext})
    return steps


def main(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("steps")
    s.add_argument("--plan-b64", required=True)
    s.add_argument("--out", required=True)
    a = p.parse_args(argv)
    try:
        plan = json.loads(base64.b64decode(a.plan_b64).decode("utf-8"))
        steps = build_steps(plan)
    except (ValueError, PlanError) as exc:
        print(f"::error title=Data plan::{exc}")
        return 2
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(steps, fh, indent=2)
    for st in steps:
        print(f"{st['name']}: {st['soql']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
