#!/usr/bin/env python3
"""specified_tests.py - resolve the Apex tests a delta needs, in three passes.

A one-class change must run that class's tests, not the org's. For every ApexClass and
ApexTrigger in package.xml:

  Pass 1  the org's coverage map (ApexCodeCoverage, Tooling API): the test classes that
          actually exercise the changed code, ordered by lines covered, capped at --cap
          (default 25) in TOTAL. Selection is round-robin by rank across the changed classes,
          so one widely-used utility cannot take every slot from the other changed classes.
  Pass 2  the naming convention, against test classes that exist in the source tree:
          {n}Test {n}_Test Test{n} Test_{n} {n}Tests {n}_Tests {n}TestClass
  Pass 3  every changed class that is itself a test (@isTest or testMethod).

--explicit "A,B" overrides all three passes. Test classes being deleted (--destructive) and
managed-package test classes are never named.

Outputs (also appended to $GITHUB_OUTPUT when it is set)
  apex_changed  true when package.xml holds ApexClass or ApexTrigger members
  tests         comma-separated, de-duplicated, stable order
  test_level    RunSpecifiedTests when tests resolved; EMPTY otherwise. Empty with
                apex_changed=true means "nothing resolved": the caller decides (fail a
                validation, NoTestRun with a warning in a sandbox, refuse production).
                RunLocalTests is never emitted.
  unresolved    changed non-test classes/triggers with no test found
  report        markdown explaining how each test was found

Usage
  specified_tests.py --package PKG --source-path DIR [--org ALIAS] [--coverage-json FILE]
                     [--explicit "A,B"] [--cap 25] [--destructive DESTRUCTIVE_XML]
Exit codes: 0 ok, 2 usage or unreadable package.xml.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

NS = "{http://soap.sforce.com/2006/04/metadata}"
APEX_TYPES = ("ApexClass", "ApexTrigger")
NAME_PATTERNS = ("{n}Test", "{n}_Test", "Test{n}", "Test_{n}", "{n}Tests", "{n}_Tests", "{n}TestClass")
DEFAULT_CAP = 25
QUERY_CHUNK = 100
TEST_MARKER = re.compile(r"@\s*istest\b|\btestmethod\b", re.IGNORECASE)
COMMENTS = re.compile(r"/\*.*?\*/|//[^\n]*", re.DOTALL)


class UsageError(Exception):
    pass


# ---- inputs -----------------------------------------------------------------------------------
def read_manifest(path):
    """{type: [members]} in file order. A missing optional file reads as empty."""
    if not path:
        return {}
    if not os.path.isfile(path):
        raise UsageError(f"manifest not found: {path}")
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
                types.setdefault(name, [])
                if text not in types[name]:
                    types[name].append(text)
    return types


def is_test_source(text):
    return bool(TEST_MARKER.search(COMMENTS.sub(" ", text or "")))


def scan_source(source_path):
    """Index the Apex in the source tree: {lowercase name: {name, path, kind, is_test, text}}."""
    index = {}
    if not source_path or not os.path.isdir(source_path):
        return index
    for dirpath, dirnames, filenames in os.walk(source_path):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "node_modules"]
        for filename in filenames:
            if filename.endswith(".cls"):
                kind, name = "ApexClass", filename[: -len(".cls")]
            elif filename.endswith(".trigger"):
                kind, name = "ApexTrigger", filename[: -len(".trigger")]
            else:
                continue
            path = os.path.join(dirpath, filename)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                text = ""
            key = name.lower() if kind == "ApexClass" else f"trigger:{name.lower()}"
            index[key] = {"name": name, "path": path, "kind": kind, "text": text,
                          "is_test": kind == "ApexClass" and is_test_source(text)}
    return index


def split_names(value):
    out, seen = [], set()
    for part in re.split(r"[,;\s]+", value or ""):
        part = part.strip()
        if part and part.lower() not in seen:
            seen.add(part.lower())
            out.append(part)
    return out


# ---- pass 1: the org's coverage map ------------------------------------------------------------
def _field(record, dotted):
    """Read 'ApexTestClass.Name' from a nested sf JSON record or a flattened one."""
    if dotted in record:
        return record[dotted]
    value = record
    for part in dotted.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(part)
    return value


def load_coverage_json(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):  # `sf data query --json` output, or its bare result
        inner = data.get("result", data)
        data = inner.get("records", []) if isinstance(inner, dict) else None
    if not isinstance(data, list):
        raise UsageError(f"{path}: expected sf data query JSON or a list of records")
    return data


def _soql_quote(name):
    return "'" + name.replace("\\", "\\\\").replace("'", "\\'") + "'"


def query_coverage(org, names):
    """ApexCodeCoverage rows for the named classes/triggers. Returns (records, error)."""
    sf = shutil.which("sf")
    if not sf:
        return [], "the sf CLI is not on PATH"
    records = []
    for i in range(0, len(names), QUERY_CHUNK):
        chunk = names[i:i + QUERY_CHUNK]
        soql = ("SELECT ApexTestClass.Name, ApexTestClass.NamespacePrefix, ApexClassOrTrigger.Name, "
                "TestMethodName, NumLinesCovered FROM ApexCodeCoverage "
                f"WHERE ApexClassOrTrigger.Name IN ({', '.join(_soql_quote(n) for n in chunk)}) "
                "AND NumLinesCovered > 0 ORDER BY NumLinesCovered DESC")
        proc = subprocess.run([sf, "data", "query", "--use-tooling-api", "--json", "-o", org, "-q", soql],
                              capture_output=True, text=True, encoding="utf-8", errors="replace")
        try:
            data = json.loads(proc.stdout or "{}")
        except ValueError:
            data = {}
        if proc.returncode != 0 or not isinstance(data.get("result"), dict):
            stderr_lines = (proc.stderr or "").strip().splitlines()
            message = data.get("message") or (stderr_lines[-1] if stderr_lines else "unknown error")
            return records, f"ApexCodeCoverage query against '{org}' failed: {str(message).strip()}"
        records.extend(data["result"].get("records") or [])
    return records, None


def coverage_scores(records, changed_lower, excluded_lower):
    """{changed class (lower): {test name: max lines covered}} from ApexCodeCoverage rows."""
    scores = {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        test = _field(rec, "ApexTestClass.Name")
        covered = _field(rec, "ApexClassOrTrigger.Name")
        namespace = _field(rec, "ApexTestClass.NamespacePrefix")
        if not test or not covered or namespace:
            continue
        key = str(covered).lower()
        if key not in changed_lower or str(test).lower() in excluded_lower:
            continue
        try:
            lines = int(float(_field(rec, "NumLinesCovered") or 0))
        except (TypeError, ValueError):
            lines = 0
        if lines <= 0:
            continue
        per_class = scores.setdefault(key, {})
        per_class[test] = max(lines, per_class.get(test, 0))
    return scores


def select_pass1(scores, changed_order, cap):
    """Round-robin by rank across changed classes, best-covered first within a round."""
    ranked = {}
    for key in changed_order:
        if key in scores:
            ranked[key] = sorted(scores[key].items(), key=lambda kv: (-kv[1], kv[0].lower()))
    selected, seen, dropped = [], set(), set()
    depth = max((len(v) for v in ranked.values()), default=0)
    for rank in range(depth):
        round_items = [(lst[rank][1], lst[rank][0]) for lst in ranked.values() if rank < len(lst)]
        round_items.sort(key=lambda item: (-item[0], item[1].lower()))
        for lines, test in round_items:
            if test.lower() in seen:
                continue
            if len(selected) >= cap:
                dropped.add(test.lower())
                continue
            seen.add(test.lower())
            selected.append(test)
    dropped -= seen
    return selected, len(dropped)


# ---- resolution -------------------------------------------------------------------------------
def resolve(package, source_index, coverage_records=None, coverage_error=None, coverage_source="",
            explicit=None, cap=DEFAULT_CAP, destructive=None):
    destructive = destructive or {}
    changed = []  # (kind, name)
    for kind in APEX_TYPES:
        for name in package.get(kind, []):
            changed.append((kind, name))
    apex_changed = bool(changed)
    deleted_lower = {n.lower() for kind in APEX_TYPES for n in destructive.get(kind, [])}

    rows = []           # (test, how, covers)
    tests, seen = [], set()
    notes = []

    def add(test, how, covers):
        if test.lower() in deleted_lower:
            return
        if test.lower() not in seen:
            seen.add(test.lower())
            tests.append(test)
            rows.append([test, how, list(covers)])
        else:
            for row in rows:
                if row[0].lower() == test.lower():
                    for c in covers:
                        if c not in row[2]:
                            row[2].append(c)

    explicit_names = split_names(explicit) if explicit else []
    if explicit_names:
        for name in explicit_names:
            add(name, "explicit (work item / promotion)", [])
        return {
            "apex_changed": apex_changed, "changed": changed, "tests": tests,
            "test_level": "RunSpecifiedTests" if tests else "", "unresolved": [],
            "rows": rows, "notes": ["Explicit tests override the coverage map and the naming convention."],
            "explicit": True,
        }

    def source_entry(kind, name):
        key = name.lower() if kind == "ApexClass" else f"trigger:{name.lower()}"
        return source_index.get(key)

    changed_tests = {name.lower() for kind, name in changed
                     if kind == "ApexClass" and (source_entry(kind, name) or {}).get("is_test")}
    targets = [(kind, name) for kind, name in changed if name.lower() not in changed_tests]
    target_lower = [name.lower() for _, name in targets]
    resolved = set()

    # Pass 1 - coverage map
    if coverage_records is not None and targets:
        scores = coverage_scores(coverage_records, set(target_lower), deleted_lower)
        picked, dropped = select_pass1(scores, target_lower, cap)
        picked_lower = {t.lower() for t in picked}
        for test in picked:
            covers, best = [], 0
            for kind, name in targets:
                lines = scores.get(name.lower(), {}).get(test)
                if lines:
                    covers.append(name)
                    best = max(best, lines)
            add(test, f"coverage map ({coverage_source}, up to {best} lines)", covers)
        for key, per_class in scores.items():
            if any(t.lower() in picked_lower for t in per_class):
                resolved.add(key)
        if not picked:
            notes.append(f"The coverage map ({coverage_source}) has no rows for the changed classes.")
        if dropped:
            notes.append(f"The coverage map named {dropped} more test class(es); the list is capped at {cap} "
                         "so a shared utility cannot turn into a whole-org run.")
    elif coverage_error:
        notes.append(f"Coverage map not used: {coverage_error}")
    elif targets:
        notes.append("Coverage map not used: no org (--org) or coverage file (--coverage-json) given.")

    # Pass 2 - naming convention against test classes in the source tree
    for kind, name in targets:
        for pattern in NAME_PATTERNS:
            entry = source_index.get(pattern.format(n=name).lower())
            if entry and entry["kind"] == "ApexClass" and entry["is_test"] and entry["name"].lower() not in deleted_lower:
                add(entry["name"], f"naming convention (`{pattern}`)", [name])
                resolved.add(name.lower())

    # Pass 3 - changed classes that are tests themselves
    for kind, name in changed:
        if name.lower() in changed_tests:
            entry = source_entry(kind, name)
            covers = [t for k, t in targets
                      if re.search(r"\b" + re.escape(t) + r"\b", COMMENTS.sub(" ", entry["text"]), re.IGNORECASE)]
            add(entry["name"], "changed test class", covers)
            resolved.update(c.lower() for c in covers)

    unresolved = [name for _, name in targets if name.lower() not in resolved]
    return {
        "apex_changed": apex_changed, "changed": changed, "tests": tests,
        "test_level": "RunSpecifiedTests" if tests else "", "unresolved": unresolved,
        "rows": rows, "notes": notes, "explicit": False,
    }


# ---- output -----------------------------------------------------------------------------------
def render_report(res):
    lines = ["### Apex test selection", ""]
    if not res["apex_changed"] and not res["tests"]:
        lines.append("No Apex classes or triggers in this delta, so no tests are needed.")
        return "\n".join(lines)
    if res["changed"]:
        classes = [n for k, n in res["changed"] if k == "ApexClass"]
        triggers = [n for k, n in res["changed"] if k == "ApexTrigger"]
        parts = []
        if classes:
            parts.append(f"{len(classes)} class(es): " + ", ".join(f"`{c}`" for c in classes))
        if triggers:
            parts.append(f"{len(triggers)} trigger(s): " + ", ".join(f"`{t}`" for t in triggers))
        lines.append("Changed Apex - " + "; ".join(parts) + ".")
        lines.append("")
    if res["rows"]:
        lines += ["| Test class | Found by | Covers |", "| --- | --- | --- |"]
        for test, how, covers in res["rows"]:
            lines.append(f"| `{test}` | {how} | {', '.join(covers) if covers else '-'} |")
        lines.append("")
    level = res["test_level"] or "(empty - nothing resolved; the target decides)"
    lines.append(f"**Test level:** {level}")
    if res["unresolved"]:
        lines.append("")
        lines.append("**No test found for:** " + ", ".join(f"`{u}`" for u in res["unresolved"]))
        for name in res["unresolved"]:
            lines.append(f"- `{name}`: add a test class named `{name}Test` (or `{name}_Test`), or name the "
                         "covering test explicitly on the work item.")
    for note in res["notes"]:
        lines.append("")
        lines.append(f"_{note}_")
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


def parse_args(argv):
    p = argparse.ArgumentParser(prog="specified_tests.py", description="Resolve the Apex tests a delta needs.")
    p.add_argument("--package", required=True, help="package.xml of the delta")
    p.add_argument("--source-path", required=True, help="metadata root, e.g. force-app")
    p.add_argument("--org", default="", help="org alias whose ApexCodeCoverage is queried (pass 1)")
    p.add_argument("--coverage-json", default="", help="sf data query JSON of ApexCodeCoverage (instead of --org)")
    p.add_argument("--explicit", default="", help="comma-separated tests; overrides every pass")
    p.add_argument("--cap", type=int, default=DEFAULT_CAP, help="max tests taken from the coverage map (total)")
    p.add_argument("--destructive", default="", help="destructiveChanges.xml; deleted tests are never named")
    return p.parse_args(argv)


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    if args.cap < 1:
        print("::error::--cap must be at least 1")
        return 2
    try:
        package = read_manifest(args.package)
        destructive = read_manifest(args.destructive) if args.destructive and os.path.isfile(args.destructive) else {}
        source_index = scan_source(args.source_path)
        changed = [n for k in APEX_TYPES for n in package.get(k, [])]
        records, error, source = None, None, ""
        if not args.explicit.strip() and changed:
            if args.coverage_json:
                records, source = load_coverage_json(args.coverage_json), os.path.basename(args.coverage_json)
            elif args.org:
                records, error = query_coverage(args.org, changed)
                source = f"org {args.org}"
                if error:
                    print(f"::warning::{error}; continuing with the naming convention")
                    records = records or None
        res = resolve(package, source_index, coverage_records=records, coverage_error=error,
                      coverage_source=source, explicit=args.explicit, cap=args.cap, destructive=destructive)
    except (UsageError, OSError, ValueError) as exc:
        print(f"::error title=specified_tests.py::{exc}")
        return 2
    if res["apex_changed"] and not res["tests"]:
        print("::warning::Apex changed but no test resolved: " + ", ".join(res["unresolved"]))
    emit({
        "apex_changed": "true" if res["apex_changed"] else "false",
        "tests": ",".join(res["tests"]),
        "test_level": res["test_level"],
        "unresolved": ",".join(res["unresolved"]),
        "report": render_report(res),
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
