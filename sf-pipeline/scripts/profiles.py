#!/usr/bin/env python3
"""profiles.py - shape the profiles and permission sets in a delta: full | incremental.

  full         no change: profiles and permission sets deploy exactly as they are in source.
  incremental  for every Profile / PermissionSet named in package.xml, rewrite its source file
               in place, keeping only the permission entries that reference a component ALSO
               in package.xml. Profile-level settings (userPermissions, loginHours,
               loginIpRanges, custom, description, userLicense, license, label,
               hasActivationRequired, ...) are always kept. This avoids "component does not
               exist" failures on orgs that lag behind.

Permission entries and the component each one must reference:
  fieldPermissions/field                  CustomField
  objectPermissions/object                CustomObject
  classAccesses/apexClass                 ApexClass
  tabVisibilities/tab, tabSettings/tab    CustomTab
  applicationVisibilities/application     CustomApplication
  recordTypeVisibilities/recordType       RecordType
  layoutAssignments/layout                Layout
  pageAccesses/apexPage                   ApexPage
  flowAccesses/flow                       Flow
  customMetadataTypeAccesses/name         CustomObject
  customSettingAccesses/name              CustomObject
  customPermissions/name                  CustomPermission
Any other element is left untouched. A `*` member in package.xml keeps every entry of that type.

Outputs (also appended to $GITHUB_OUTPUT when it is set)
  changed_files  rewritten files, one per line (with --dry-run: the files that would change)
  summary        kept / stripped counts per file

Usage: profiles.py --package PKG --source-path DIR --mode full|incremental [--dry-run]
Exit codes: 0 ok, 2 usage or unreadable input.
"""

import argparse
import os
import sys
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import quote, unquote

MD_NS = "http://soap.sforce.com/2006/04/metadata"
NS = "{" + MD_NS + "}"

PERMISSION_RULES = {
    "fieldPermissions": ("field", "CustomField"),
    "objectPermissions": ("object", "CustomObject"),
    "classAccesses": ("apexClass", "ApexClass"),
    "tabVisibilities": ("tab", "CustomTab"),
    "tabSettings": ("tab", "CustomTab"),
    "applicationVisibilities": ("application", "CustomApplication"),
    "recordTypeVisibilities": ("recordType", "RecordType"),
    "layoutAssignments": ("layout", "Layout"),
    "pageAccesses": ("apexPage", "ApexPage"),
    "flowAccesses": ("flow", "Flow"),
    "customMetadataTypeAccesses": ("name", "CustomObject"),
    "customSettingAccesses": ("name", "CustomObject"),
    "customPermissions": ("name", "CustomPermission"),
}
SUFFIXES = {"Profile": ".profile-meta.xml", "PermissionSet": ".permissionset-meta.xml"}


class UsageError(Exception):
    pass


def read_manifest(path):
    if not os.path.isfile(path):
        raise UsageError(f"package.xml not found: {path}")
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise UsageError(f"{path} is not valid XML: {exc}")
    types = {}
    for node in root.iter(NS + "types"):
        name = (node.findtext(NS + "name") or "").strip()
        for member in node.findall(NS + "members"):
            text = (member.text or "").strip()
            if name and text:
                types.setdefault(name, set()).add(text)
    return types


def _local(tag):
    return tag.split("}", 1)[1] if isinstance(tag, str) and "}" in tag else tag


def _variants(name):
    """Profile names are URL-encoded in file names ('Custom%3A Sales'); accept both forms."""
    return {name, unquote(name), quote(name, safe=" -_.()'")}


def index_sources(source_path):
    """{('Profile'|'PermissionSet', name variant lower): path}"""
    index = {}
    for dirpath, dirnames, filenames in os.walk(source_path):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "node_modules"]
        for filename in filenames:
            for mtype, suffix in SUFFIXES.items():
                if filename.endswith(suffix):
                    stem = filename[: -len(suffix)]
                    for variant in _variants(stem):
                        index.setdefault((mtype, variant.lower()), os.path.join(dirpath, filename))
    return index


def find_source(index, mtype, member):
    for variant in _variants(member):
        path = index.get((mtype, variant.lower()))
        if path:
            return path
    return None


def strip_file(path, package, dry_run=False):
    """Strip one profile / permission set. Returns (kept, stripped, per-element stripped, changed)."""
    lowered = {t: {m.lower() for m in members} for t, members in package.items()}
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    tree = ET.parse(path, parser=parser)
    root = tree.getroot()
    kept = stripped = 0
    detail = {}
    for child in list(root):
        element = _local(child.tag)
        rule = PERMISSION_RULES.get(element)
        if not rule:
            continue
        key_tag, component_type = rule
        members = lowered.get(component_type, set())
        reference = (child.findtext(NS + key_tag) or child.findtext(key_tag) or "").strip()
        if "*" in members or (reference and reference.lower() in members):
            kept += 1
            continue
        root.remove(child)
        stripped += 1
        detail[element] = detail.get(element, 0) + 1
    if stripped and not dry_run:
        ET.register_namespace("", MD_NS)
        ET.indent(tree, space="    ")
        body = ET.tostring(root, encoding="unicode")
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?>\n')
            fh.write(body)
            fh.write("\n")
    return kept, stripped, detail, stripped > 0


def run(package_path, source_path, mode, dry_run=False):
    package = read_manifest(package_path)
    targets = [(t, m) for t in ("Profile", "PermissionSet") for m in sorted(package.get(t, set()))]
    if mode == "full":
        if targets:
            summary = (f"profiles_mode=full: {len(targets)} profile(s)/permission set(s) deploy exactly as "
                       "they are in source.")
        else:
            summary = "profiles_mode=full: no profiles or permission sets in this delta."
        return [], summary
    if not targets:
        return [], "profiles_mode=incremental: no profiles or permission sets in this delta."
    if not os.path.isdir(source_path):
        raise UsageError(f"source path not found: {source_path}")
    index = index_sources(source_path)
    changed, lines = [], []
    verb = "would strip" if dry_run else "stripped"
    lines.append(f"profiles_mode=incremental{' (dry run)' if dry_run else ''}: permission entries that reference "
                 "components outside this delta are removed; profile-level settings are kept.")
    for mtype, member in targets:
        path = find_source(index, mtype, member)
        if not path:
            print(f"::warning::{mtype} '{member}' is in package.xml but no source file was found under {source_path}")
            lines.append(f"- {mtype} `{member}`: source file not found, left as is")
            continue
        try:
            kept, stripped, detail, did_change = strip_file(path, package, dry_run=dry_run)
        except ET.ParseError as exc:
            raise UsageError(f"{path} is not valid XML: {exc}")
        display = os.path.normpath(path).replace(os.sep, "/")
        if did_change:
            changed.append(display)
        parts = ", ".join(f"{k} {v}" for k, v in sorted(detail.items()))
        lines.append(f"- {mtype} `{member}` ({display}): kept {kept}, {verb} {stripped}"
                     + (f" ({parts})" if parts else ""))
    return changed, "\n".join(lines)


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
    p = argparse.ArgumentParser(prog="profiles.py", description="full | incremental profile/permission set shaping")
    p.add_argument("--package", required=True)
    p.add_argument("--source-path", required=True)
    p.add_argument("--mode", required=True, choices=("full", "incremental"))
    p.add_argument("--dry-run", action="store_true", help="report what would change without writing")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        changed, summary = run(args.package, args.source_path, args.mode, args.dry_run)
    except (UsageError, OSError) as exc:
        print(f"::error title=profiles.py::{exc}")
        return 2
    emit({"changed_files": "\n".join(changed), "summary": summary})
    return 0


if __name__ == "__main__":
    sys.exit(main())
