#!/usr/bin/env python3
"""commit_helper.py — the pieces of sf-commit that are easier in Python than in YAML.

  commit_helper.py package --components <json|@file> --denylist <file> --api <ver> --out <package.xml>
      Build a retrieve manifest from the hub's selection ([{"type":..,"name":..,"action":..}]).
      Entries with action "Delete" are not retrieved; they are written to deletes.json.
      Entries matching the deny-list are dropped and reported (outputs: denied, retrieve_count,
      delete_count).

  commit_helper.py apply-deletes --deletes deletes.json --source-path <dir>
      Remove the source files of components the developer deleted in the org.

  commit_helper.py payload --from <ref> --to <ref> --source-path <dir> --out components.json
      List the components a commit touched, as hub ComponentPayload objects:
      {type, name, action (Add|Modify|Delete), uniqueId, path, lastCommitDate, lastCommitSha}.
"""

import argparse
import fnmatch
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sf_paths import path_to_component  # noqa: E402

NS = "http://soap.sforce.com/2006/04/metadata"


def emit(key, value):
    target = os.environ.get("GITHUB_OUTPUT")
    line = f"{key}={value}\n"
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(line)
    sys.stdout.write(line)


def load_components(arg):
    text = open(arg[1:], encoding="utf-8").read() if arg.startswith("@") else arg
    data = json.loads(text or "[]")
    if not isinstance(data, list):
        raise SystemExit("components must be a JSON array")
    out = []
    for c in data:
        t, n = str(c.get("type", "")).strip(), str(c.get("name", "")).strip()
        if t and n:
            out.append({"type": t, "name": n, "action": str(c.get("action", "") or "Retrieve")})
    return out


def load_denylist(path):
    if not path or not os.path.isfile(path):
        return []
    pats = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            pats.append(line)
    return pats


def denied(component, patterns):
    key = f"{component['type']}:{component['name']}"
    return any(fnmatch.fnmatchcase(key, p) for p in patterns)


def write_package(components, api, out):
    ET.register_namespace("", NS)
    root = ET.Element(f"{{{NS}}}Package")
    by_type = {}
    for c in components:
        by_type.setdefault(c["type"], set()).add(c["name"])
    for t in sorted(by_type):
        el = ET.SubElement(root, f"{{{NS}}}types")
        for m in sorted(by_type[t]):
            ET.SubElement(el, f"{{{NS}}}members").text = m
        ET.SubElement(el, f"{{{NS}}}name").text = t
    ET.SubElement(root, f"{{{NS}}}version").text = api
    ET.indent(root)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    ET.ElementTree(root).write(out, encoding="UTF-8", xml_declaration=True)


def cmd_package(a):
    comps = load_components(a.components)
    patterns = load_denylist(a.denylist)
    keep, deletes, dropped = [], [], []
    for c in comps:
        if denied(c, patterns):
            dropped.append(f"{c['type']}:{c['name']}")
        elif c["action"].lower() == "delete":
            deletes.append(c)
        else:
            keep.append(c)
    write_package(keep, a.api, a.out)
    with open(os.path.join(os.path.dirname(os.path.abspath(a.out)), "deletes.json"), "w", encoding="utf-8") as fh:
        json.dump(deletes, fh)
    for d in dropped:
        print(f"::warning::{d} is on the commit deny-list and was not committed")
    emit("retrieve_count", len(keep))
    emit("delete_count", len(deletes))
    emit("denied", ",".join(dropped))
    return 0


def cmd_apply_deletes(a):
    deletes = json.load(open(a.deletes, encoding="utf-8")) if os.path.isfile(a.deletes) else []
    wanted = {(d["type"], d["name"]) for d in deletes}
    removed = []
    for root, _dirs, files in os.walk(a.source_path):
        for f in files:
            p = os.path.join(root, f).replace("\\", "/")
            if path_to_component(p) in wanted:
                os.remove(p)
                removed.append(p)
    for p in removed:
        print(f"deleted {p}")
    emit("deleted_files", len(removed))
    return 0


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def cmd_payload(a):
    sha = git("rev-parse", a.to).strip()
    when = git("show", "-s", "--format=%cI", a.to).strip()
    status = git("diff", "--name-status", "--no-renames", a.frm, a.to, "--", a.source_path)
    comps = {}
    for line in status.splitlines():
        if not line.strip():
            continue
        code, path = line.split("\t", 1)
        t, n = path_to_component(path)
        action = {"A": "Add", "D": "Delete"}.get(code[0], "Modify")
        key = f"{t}:{n}"
        prev = comps.get(key)
        # A bundle with some files added and some modified is a modification; a component
        # whose every file was deleted is a deletion.
        if prev:
            if prev["action"] != action:
                action = "Modify"
        comps[key] = {"type": t, "name": n, "action": action, "uniqueId": key, "path": path,
                      "lastCommitDate": when, "lastCommitSha": sha}
    payload = sorted(comps.values(), key=lambda c: c["uniqueId"])
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
    emit("component_count", len(payload))
    return 0


def main(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pk = sub.add_parser("package")
    pk.add_argument("--components", required=True)
    pk.add_argument("--denylist", default="")
    pk.add_argument("--api", default="66.0")
    pk.add_argument("--out", required=True)
    ad = sub.add_parser("apply-deletes")
    ad.add_argument("--deletes", required=True)
    ad.add_argument("--source-path", required=True)
    pl = sub.add_parser("payload")
    pl.add_argument("--from", dest="frm", required=True)
    pl.add_argument("--to", default="HEAD")
    pl.add_argument("--source-path", required=True)
    pl.add_argument("--out", required=True)
    a = p.parse_args(argv)
    return {"package": cmd_package, "apply-deletes": cmd_apply_deletes, "payload": cmd_payload}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
