#!/usr/bin/env python3
"""conflict-check.py - find in-flight work items that touch the same component.

Joins work items on the component Unique ID ("Type:Name", CDO_Component__c.Unique_ID__c) so
overlaps surface before they become merge conflicts at a promotion. Two inputs, either or both:

  --git       every remote feature branch refs/remotes/origin/<prefix>*: the paths it changed
              since its merge-base with --baseline, under --source-path, each mapped to a Unique
              ID by path convention. The work item key is the branch name after the prefix.
  --hub-json  rows exported from the hub: [{"workItem": "WI-1", "uniqueId": "ApexClass:Foo"}]

It is a report: exit 0 even when overlaps exist; exit 2 on usage errors (bad arguments, an
unreadable --hub-json, a --baseline that does not resolve).

Outputs (also appended to $GITHUB_OUTPUT when it is set)
  overlap_count  number of Unique IDs touched by two or more work items
  report         markdown
  overlaps_json  [{"uniqueId": ..., "workItems": [...], "paths": [...]}] ("paths": git only)

Usage
  conflict-check.py [--git] [--hub-json FILE] [--baseline origin/main] [--feature-prefix feature/]
                    [--source-path force-app] [--repo-dir .]
  --baseline defaults to origin/$BASELINE_BRANCH, --source-path to $SOURCE_PATH or force-app.
"""

import argparse
import json
import os
import subprocess
import sys
import uuid

# metadata folder -> component type, for one-file-per-component folders
SIMPLE_FOLDERS = {
    "classes": "ApexClass",
    "triggers": "ApexTrigger",
    "layouts": "Layout",
    "permissionsets": "PermissionSet",
    "profiles": "Profile",
    "flows": "Flow",
    "flexipages": "FlexiPage",
    "tabs": "CustomTab",
    "applications": "CustomApplication",
    "staticresources": "StaticResource",
    "customMetadata": "CustomMetadata",
    "pages": "ApexPage",
    "components": "ApexComponent",
}
BUNDLE_FOLDERS = {"lwc": "LightningComponentBundle", "aura": "AuraDefinitionBundle"}
OBJECT_CHILDREN = {
    "fields": "CustomField",
    "listViews": "ListView",
    "recordTypes": "RecordType",
    "validationRules": "ValidationRule",
    "compactLayouts": "CompactLayout",
    "fieldSets": "FieldSet",
    "webLinks": "WebLink",
    "businessProcesses": "BusinessProcess",
}
KNOWN_FOLDERS = set(SIMPLE_FOLDERS) | set(BUNDLE_FOLDERS) | {"objects", "labels"}


class UsageError(Exception):
    pass


def component_name(filename):
    """'Foo.cls-meta.xml' -> 'Foo'; 'My_Type.Rec.md-meta.xml' -> 'My_Type.Rec'; 'X.resource' -> 'X'."""
    name = filename[: -len("-meta.xml")] if filename.endswith("-meta.xml") else filename
    return name.rsplit(".", 1)[0] if "." in name else name


def unique_id(path):
    """Map a repository path to a component Unique ID 'Type:Name' (Unknown:<path> otherwise)."""
    norm = path.replace("\\", "/").strip("/")
    parts = norm.split("/")
    for i, part in enumerate(parts):
        if part not in KNOWN_FOLDERS:
            continue
        rest = parts[i + 1:]
        if not rest:
            break
        if part in BUNDLE_FOLDERS:
            if len(rest) >= 2:
                return f"{BUNDLE_FOLDERS[part]}:{rest[0]}"
            break
        if part == "labels":
            return "CustomLabels:CustomLabels"
        if part == "objects":
            obj = rest[0]
            if len(rest) == 2 and component_name(rest[1]) == obj:
                return f"CustomObject:{obj}"
            if len(rest) == 3 and rest[1] in OBJECT_CHILDREN:
                return f"{OBJECT_CHILDREN[rest[1]]}:{obj}.{component_name(rest[2])}"
            break
        if part == "staticresources" and len(rest) >= 2:
            return f"StaticResource:{rest[0]}"  # an expanded (folder) static resource
        if len(rest) == 1:
            return f"{SIMPLE_FOLDERS[part]}:{component_name(rest[0])}"
        break
    return f"Unknown:{norm}"


def git(repo, *args):
    proc = subprocess.run(["git", "-C", repo, "-c", "core.quotepath=off", *args],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {proc.stderr.strip() or 'failed'}")
    return proc.stdout


def from_git(repo, baseline, prefix, source_path):
    """{work item: {uniqueId: [paths]}} for every remote feature branch."""
    try:
        git(repo, "rev-parse", "--verify", "--quiet", f"{baseline}^{{commit}}")
    except RuntimeError:
        raise UsageError(f"--baseline '{baseline}' does not resolve to a commit (fetch it first)")
    refs = git(repo, "for-each-ref", "--format=%(refname)", f"refs/remotes/origin/{prefix}*").split()
    items = {}
    for ref in sorted(refs):
        branch = ref[len("refs/remotes/origin/"):]
        work_item = branch[len(prefix):]
        if not work_item or branch == "HEAD":
            continue
        try:
            base = git(repo, "merge-base", baseline, ref).strip()
        except RuntimeError:
            print(f"::warning::{branch} shares no history with {baseline}; skipped")
            continue
        paths = [p for p in git(repo, "diff", "--name-only", base, ref, "--", source_path).splitlines() if p]
        bucket = items.setdefault(work_item, {})
        for path in paths:
            bucket.setdefault(unique_id(path), []).append(path)
    return items


def from_hub(path):
    try:
        with open(path, encoding="utf-8") as fh:
            rows = json.load(fh)
    except (OSError, ValueError) as exc:
        raise UsageError(f"--hub-json {path}: {exc}")
    if isinstance(rows, dict):
        rows = rows.get("records") or (rows.get("result") or {}).get("records") or []
    if not isinstance(rows, list):
        raise UsageError(f"--hub-json {path}: expected a JSON array of {{workItem, uniqueId}} rows")
    items = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        work_item = row.get("workItem") or row.get("Work_Item_Key__c") or (row.get("Work_Item__r") or {}).get("Name")
        uid = row.get("uniqueId") or row.get("Unique_ID__c")
        if work_item and uid:
            items.setdefault(str(work_item), {}).setdefault(str(uid), [])
    return items


def find_overlaps(*sources):
    by_component = {}
    for source in sources:
        for work_item, components in source.items():
            for uid, paths in components.items():
                entry = by_component.setdefault(uid, {"workItems": set(), "paths": set()})
                entry["workItems"].add(work_item)
                entry["paths"].update(paths)
    overlaps = []
    for uid in sorted(by_component):
        entry = by_component[uid]
        if len(entry["workItems"]) > 1:
            overlap = {"uniqueId": uid, "workItems": sorted(entry["workItems"])}
            if entry["paths"]:
                overlap["paths"] = sorted(entry["paths"])
            overlaps.append(overlap)
    return overlaps


def render(overlaps, work_item_count, inputs):
    lines = ["### Component overlap check", "",
             f"Compared {work_item_count} in-flight work item(s) from {' and '.join(inputs)}."]
    if not overlaps:
        lines += ["", "No overlapping components."]
        return "\n".join(lines)
    lines += ["", f"**{len(overlaps)} component(s) are changed by more than one work item.** "
              "Coordinate before promoting: the later promotion will merge on top of the earlier one.",
              "", "| Component | Work items | Paths |", "| --- | --- | --- |"]
    for o in overlaps:
        paths = "<br>".join(f"`{p}`" for p in o.get("paths", [])) or "-"
        lines.append(f"| `{o['uniqueId']}` | {', '.join(o['workItems'])} | {paths} |")
    return "\n".join(lines)


def emit(outputs):
    chunks = []
    for key, value in outputs.items():
        text = "" if value is None else str(value)
        if "\n" in text:
            delim = f"EOF_{uuid.uuid4().hex}"
            chunks.append(f"{key}<<{delim}\n{text}\n{delim}")
        else:
            chunks.append(f"{key}={text}")
    payload = "\n".join(chunks) + "\n"
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(payload)
    sys.stdout.write(payload)


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    p = argparse.ArgumentParser(prog="conflict-check.py", description="Cross-work-item component overlap report")
    p.add_argument("--git", action="store_true", help="scan remote feature branches")
    p.add_argument("--hub-json", default="", help="JSON rows [{workItem, uniqueId}] from the hub")
    p.add_argument("--baseline", default="")
    p.add_argument("--feature-prefix", default="feature/")
    p.add_argument("--source-path", default=os.environ.get("SOURCE_PATH") or "force-app")
    p.add_argument("--repo-dir", default=".")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    if not args.git and not args.hub_json:
        print("::error title=conflict-check.py::give --git, --hub-json FILE, or both")
        return 2
    sources, inputs = [], []
    try:
        if args.git:
            baseline = args.baseline
            if not baseline and os.environ.get("BASELINE_BRANCH"):
                baseline = "origin/" + os.environ["BASELINE_BRANCH"].removeprefix("origin/")
            if not baseline:
                raise UsageError("--git needs --baseline (or BASELINE_BRANCH)")
            if not args.feature_prefix:
                raise UsageError("--feature-prefix must not be empty")
            sources.append(from_git(args.repo_dir, baseline, args.feature_prefix,
                                    args.source_path.rstrip("/") or "."))
            inputs.append(f"git ({args.feature_prefix}* vs {baseline})")
        if args.hub_json:
            sources.append(from_hub(args.hub_json))
            inputs.append("the hub")
    except UsageError as exc:
        print(f"::error title=conflict-check.py::{exc}")
        return 2
    except RuntimeError as exc:
        print(f"::error title=conflict-check.py::{exc}")
        return 2
    overlaps = find_overlaps(*sources)
    work_items = set()
    for source in sources:
        work_items.update(source)
    if overlaps:
        print(f"::warning::{len(overlaps)} component(s) are changed by more than one in-flight work item")
    emit({
        "overlap_count": len(overlaps),
        "report": render(overlaps, len(work_items), inputs),
        "overlaps_json": json.dumps(overlaps, separators=(",", ":")),
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
