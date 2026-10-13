#!/usr/bin/env python3
"""manifest_to_md.py - render package.xml (and destructiveChanges.xml) as a markdown manifest.

Produces a "Type | Count | Members" table for additions/changes and one for deletions, with
totals, or a "No deployable changes" line when both are empty. Written to --out, or printed.

Usage: manifest_to_md.py --package PKG [--destructive XML] [--title T] [--out FILE]
Exit codes: 0 ok, 2 usage or unreadable package.xml.
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ET

NS = "{http://soap.sforce.com/2006/04/metadata}"


class UsageError(Exception):
    pass


def read_manifest(path, required=True):
    if not path or not os.path.isfile(path):
        if required:
            raise UsageError(f"manifest not found: {path}")
        return {}
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
                bucket = types.setdefault(name, [])
                if text not in bucket:
                    bucket.append(text)
    return {t: sorted(m, key=str.lower) for t, m in sorted(types.items(), key=lambda kv: kv[0].lower())}


def _cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def table(types):
    lines = ["| Type | Count | Members |", "| --- | ---: | --- |"]
    for mtype, members in types.items():
        lines.append(f"| {_cell(mtype)} | {len(members)} | {_cell(', '.join(members))} |")
    return lines


def render(package, destructive, title="Deployment"):
    adds = sum(len(m) for m in package.values())
    dels = sum(len(m) for m in destructive.values())
    lines = [f"## {title}", ""]
    if not adds and not dels:
        lines.append("_No deployable changes._")
        return "\n".join(lines) + "\n"
    lines.append(f"**Total:** {adds} component(s) to deploy in {len(package)} type(s); "
                 f"{dels} component(s) to delete in {len(destructive)} type(s).")
    lines.append("")
    lines.append("### Additions and changes")
    lines.append("")
    lines += table(package) if package else ["_None._"]
    if destructive:
        lines += ["", "### Deletions (destructiveChanges.xml)", ""] + table(destructive)
    return "\n".join(lines) + "\n"


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    p = argparse.ArgumentParser(prog="manifest_to_md.py", description="package.xml -> markdown manifest")
    p.add_argument("--package", required=True)
    p.add_argument("--destructive", default="")
    p.add_argument("--title", default="Deployment")
    p.add_argument("--out", default="")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        package = read_manifest(args.package, required=True)
        destructive = read_manifest(args.destructive, required=False) if args.destructive else {}
    except UsageError as exc:
        print(f"::error title=manifest_to_md.py::{exc}")
        return 2
    markdown = render(package, destructive, args.title)
    if args.out:
        parent = os.path.dirname(os.path.abspath(args.out))
        os.makedirs(parent, exist_ok=True)
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(markdown)
    sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
