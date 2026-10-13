#!/usr/bin/env python3
"""deploy_report.py - read `sf project deploy start|report|quick --json` and decide the outcome.

Believe the deploy result (result.status / result.success), never the shell exit code: a
deploy the org accepted in full can exit non-zero because the client lost the connection while
polling, and a rolled-back deploy can look clean behind a pipe.

Handles the normal {status, result: {...}} wrapper and error JSON with no result.

Outputs (also appended to $GITHUB_OUTPUT when it is set)
  outcome             success | failure
  status              result.status (Succeeded, Failed, ...) or the error name
  deploy_id           result.id
  coverage_percent    aggregate covered/total lines, 1 decimal; blank when not measured
  tests_passed        true when Apex tests ran and none failed; false otherwise
  failing_methods     one "Class.method: message" per line
  component_failures  one "Type Name: problem (file:line)" per line
  coverage_note       why coverage_percent is blank, when it is
  coverage_ok         true | false | skipped (skipped: gate off, no Apex changed, or not measured)
  message             the CLI's error message, when there is one

Coverage is computed from result.details.runTestResult.codeCoverage
(numLocations - numLocationsNotCovered over numLocations), restricted to --classes when given
and present. With --coverage-gate true and --apex-changed true, coverage below --threshold turns
the outcome into failure.

Usage
  deploy_report.py --report-json FILE [--threshold 85] [--coverage-gate true|false]
                   [--apex-changed true|false] [--classes "A,B"] [--summary-file FILE]
Exit codes: 0 report written (read `outcome`), 2 usage error.
"""

import argparse
import json
import os
import re
import sys
import uuid

FAILED_STATUSES = {"failed", "canceled", "canceling", "succeededpartial"}


def as_list(value):
    if value is None or value == "":
        return []
    if isinstance(value, list):
        return value
    return [value]


def to_int(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def to_bool(value):
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in ("true", "1", "yes", "on")


def one_line(text):
    return re.sub(r"\s+", " ", str(text or "")).strip()


def load_report(path):
    """Parse the CLI JSON. Tolerates text before the JSON (a stray warning line)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if not text.strip():
        return None, "the deploy JSON file is empty"
    try:
        return json.loads(text), None
    except ValueError:
        pass
    start = text.find("{")
    while start != -1:
        try:
            data, _ = json.JSONDecoder().raw_decode(text[start:])
            if isinstance(data, dict):
                return data, None
        except ValueError:
            pass
        start = text.find("{", start + 1)
    return None, "the deploy output is not JSON"


def analyse(data, threshold=85.0, coverage_gate=False, apex_changed=False, classes=None, parse_error=None):
    out = {
        "outcome": "failure", "status": "", "deploy_id": "", "coverage_percent": "",
        "tests_passed": "false", "failing_methods": "", "component_failures": "",
        "coverage_note": "", "coverage_ok": "skipped", "message": "",
    }
    facts = {"check_only": None, "tests_run": 0, "tests_failed": 0, "components_total": None,
             "components_deployed": None, "component_errors": None, "coverage_warnings": [],
             "covered": 0, "total": 0, "measured_classes": [], "missing_classes": []}

    if parse_error or not isinstance(data, dict):
        out["status"] = "Unknown"
        out["message"] = parse_error or "the deploy output is not a JSON object"
        out["coverage_note"] = f"Coverage was not measured: {out['message']}."
        return out, facts

    result = data.get("result")
    if not isinstance(result, dict) or not result:
        out["status"] = str(data.get("name") or "Error")
        out["message"] = one_line(data.get("message") or "the CLI returned an error and no deploy result")
        out["coverage_note"] = "Coverage was not measured: the deploy did not return a result."
        return out, facts

    status = str(result.get("status") or "")
    out["status"] = status
    out["deploy_id"] = str(result.get("id") or "")
    if data.get("message"):
        out["message"] = one_line(data["message"])
    if status.lower() == "succeeded":
        success = True
    elif status.lower() in FAILED_STATUSES:
        success = False
    else:
        # InProgress / Pending / blank: only an explicit success flag with no status counts.
        success = not status and to_bool(result.get("success"))
    if status and status.lower() not in FAILED_STATUSES and status.lower() != "succeeded" and not success:
        out["message"] = out["message"] or f"the deploy has not finished (status {status})"

    details = result.get("details") if isinstance(result.get("details"), dict) else {}
    facts["check_only"] = result.get("checkOnly")
    facts["components_total"] = result.get("numberComponentsTotal")
    facts["components_deployed"] = result.get("numberComponentsDeployed")
    facts["component_errors"] = result.get("numberComponentErrors")

    # Component failures
    comp_lines = []
    for f in as_list(details.get("componentFailures")):
        if not isinstance(f, dict):
            continue
        where = f.get("fileName") or ""
        if f.get("lineNumber"):
            where += f":{f.get('lineNumber')}"
            if f.get("columnNumber"):
                where += f":{f.get('columnNumber')}"
        label = " ".join(x for x in (str(f.get("componentType") or ""), str(f.get("fullName") or "")) if x)
        line = f"{label or 'Component'}: {one_line(f.get('problem') or 'failed')}"
        if where:
            line += f" ({where})"
        comp_lines.append(line)
    out["component_failures"] = "\n".join(comp_lines)

    # Tests
    rtr = details.get("runTestResult") if isinstance(details.get("runTestResult"), dict) else {}
    failures = [f for f in as_list(rtr.get("failures")) if isinstance(f, dict)]
    fail_lines = []
    for f in failures:
        cls = f.get("name") or "UnknownClass"
        if f.get("namespace"):
            cls = f"{f['namespace']}.{cls}"
        fail_lines.append(f"{cls}.{f.get('methodName') or 'unknownMethod'}: {one_line(f.get('message') or 'failed')}")
    out["failing_methods"] = "\n".join(fail_lines)
    tests_run = to_int(rtr.get("numTestsRun"), -1)
    if tests_run < 0:
        tests_run = to_int(result.get("numberTestsCompleted")) + to_int(result.get("numberTestErrors"))
    tests_failed = max(to_int(rtr.get("numFailures")), len(failures), to_int(result.get("numberTestErrors")))
    facts["tests_run"], facts["tests_failed"] = tests_run, tests_failed
    out["tests_passed"] = "true" if tests_run > 0 and tests_failed == 0 else "false"
    facts["coverage_warnings"] = [one_line(w.get("message")) for w in as_list(rtr.get("codeCoverageWarnings"))
                                  if isinstance(w, dict) and w.get("message")]

    # Coverage
    entries = [c for c in as_list(rtr.get("codeCoverage")) if isinstance(c, dict)]
    wanted = [c for c in (classes or []) if c]
    if wanted:
        names = {str(c.get("name") or "").lower() for c in entries}
        present = [c for c in wanted if c.lower() in names]
        facts["missing_classes"] = [c for c in wanted if c.lower() not in names]
        wanted_lower = {c.lower() for c in present}
        entries = [c for c in entries if str(c.get("name") or "").lower() in wanted_lower]
    total = sum(to_int(c.get("numLocations")) for c in entries)
    uncovered = sum(to_int(c.get("numLocationsNotCovered")) for c in entries)
    facts["total"], facts["covered"] = total, max(total - uncovered, 0)
    facts["measured_classes"] = [str(c.get("name")) for c in entries]
    pct = None
    if total > 0:
        pct = round(100.0 * (total - uncovered) / total, 1)
        out["coverage_percent"] = f"{pct:.1f}"
    elif tests_run <= 0:
        if comp_lines and not success:
            out["coverage_note"] = "Coverage was not measured: the deploy failed before any Apex test ran."
        else:
            out["coverage_note"] = ("Coverage was not measured: no Apex tests ran (NoTestRun, a quick deploy "
                                    "of a validated id, or no Apex in the delta).")
    elif wanted and not entries:
        out["coverage_note"] = ("Coverage was not measured: none of the changed classes ("
                                + ", ".join(wanted) + ") appear in the deploy's coverage results.")
    elif entries:
        out["coverage_note"] = "Coverage was not measured: the measured classes have no executable lines."
    else:
        out["coverage_note"] = "Coverage was not measured: the deploy result carries no code coverage."

    # Gate
    if coverage_gate and apex_changed and pct is not None:
        if pct + 1e-9 >= float(threshold):
            out["coverage_ok"] = "true"
        else:
            out["coverage_ok"] = "false"
            success = False
    out["outcome"] = "success" if success else "failure"
    return out, facts


def render_summary(out, facts, threshold, coverage_gate, apex_changed):
    lines = [f"### Deploy result: {out['outcome'].upper()}", "", "| | |", "| --- | --- |",
             f"| Status | {out['status'] or '-'} |",
             f"| Deploy id | {('`' + out['deploy_id'] + '`') if out['deploy_id'] else '-'} |"]
    if facts["check_only"] is not None:
        lines.append(f"| Check only | {str(to_bool(facts['check_only'])).lower()} |")
    if facts["components_total"] is not None:
        lines.append(f"| Components | {to_int(facts['components_deployed'])} deployed of "
                     f"{to_int(facts['components_total'])}, {to_int(facts['component_errors'])} error(s) |")
    lines.append(f"| Apex tests | {max(facts['tests_run'], 0)} run, {facts['tests_failed']} failed |")
    if out["coverage_percent"]:
        gate = "on" if coverage_gate and apex_changed else "off"
        lines.append(f"| Coverage | {out['coverage_percent']}% ({facts['covered']}/{facts['total']} lines; "
                     f"threshold {threshold:g}%, gate {gate}) |")
    else:
        lines.append("| Coverage | not measured |")
    lines.append(f"| Coverage gate | {out['coverage_ok']} |")
    if out["message"]:
        lines += ["", f"**Message:** {out['message']}"]
    if out["coverage_ok"] == "false":
        lines += ["", f"**Coverage {out['coverage_percent']}% is below the {threshold:g}% threshold.**"]
    if out["coverage_note"]:
        lines += ["", f"_{out['coverage_note']}_"]
    if facts["missing_classes"] and out["coverage_percent"]:
        lines += ["", "_Not in the coverage results: " + ", ".join(facts["missing_classes"]) + "._"]
    if out["component_failures"]:
        lines += ["", "#### Component failures", ""] + [f"- {x}" for x in out["component_failures"].splitlines()]
    if out["failing_methods"]:
        lines += ["", "#### Failing test methods", ""] + [f"- {x}" for x in out["failing_methods"].splitlines()]
    if facts["coverage_warnings"]:
        lines += ["", "#### Coverage warnings", ""] + [f"- {x}" for x in facts["coverage_warnings"]]
    return "\n".join(lines) + "\n"


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


def _bool_arg(value):
    v = str(value).strip().lower()
    if v in ("true", "1", "yes", "on"):
        return True
    if v in ("false", "0", "no", "off", ""):
        return False
    raise argparse.ArgumentTypeError(f"expected true or false, got '{value}'")


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    p = argparse.ArgumentParser(prog="deploy_report.py", description="Parse sf project deploy --json output.")
    p.add_argument("--report-json", required=True)
    p.add_argument("--threshold", type=float, default=85.0)
    p.add_argument("--coverage-gate", type=_bool_arg, default=False)
    p.add_argument("--apex-changed", type=_bool_arg, default=False)
    p.add_argument("--classes", default="", help="comma-separated classes the coverage is restricted to")
    p.add_argument("--summary-file", default="")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    if not os.path.isfile(args.report_json):
        print(f"::error title=deploy_report.py::deploy JSON not found: {args.report_json}")
        return 2
    data, error = load_report(args.report_json)
    classes = [c.strip() for c in re.split(r"[,;\s]+", args.classes or "") if c.strip()]
    out, facts = analyse(data, args.threshold, args.coverage_gate, args.apex_changed, classes, error)
    summary = render_summary(out, facts, args.threshold, args.coverage_gate, args.apex_changed)
    if args.summary_file:
        parent = os.path.dirname(os.path.abspath(args.summary_file))
        os.makedirs(parent, exist_ok=True)
        with open(args.summary_file, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(summary)
    if out["outcome"] != "success":
        reason = out["message"] or (f"coverage {out['coverage_percent']}% below {args.threshold:g}%"
                                    if out["coverage_ok"] == "false" else f"status {out['status']}")
        print(f"::error title=Deploy {out['status'] or 'failed'}::{reason}")
    emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
