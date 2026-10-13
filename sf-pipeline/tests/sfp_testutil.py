"""Helpers shared by the Python tests: load a script as a module, run it as the workflows do.

Not a test module itself (unittest only collects test_*.py).
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPTS = os.path.join(ROOT, "sf-pipeline", "scripts")
FIXTURES = os.path.join(HERE, "fixtures")


def fixture(*parts):
    return os.path.join(FIXTURES, *parts)


def load_script(filename):
    """Import sf-pipeline/scripts/<filename> (dashes allowed) as a module."""
    name = "sfp_" + os.path.splitext(filename)[0].replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_outputs(text):
    """Parse $GITHUB_OUTPUT content: key=value lines and key<<DELIM blocks (last one wins)."""
    outputs, lines, i = {}, text.splitlines(), 0
    while i < len(lines):
        line = lines[i]
        if "<<" in line and "=" not in line.split("<<", 1)[0]:
            key, delim = line.split("<<", 1)
            buf, i = [], i + 1
            while i < len(lines) and lines[i] != delim:
                buf.append(lines[i])
                i += 1
            outputs[key] = "\n".join(buf)
        elif "=" in line:
            key, value = line.split("=", 1)
            outputs[key] = value
        i += 1
    return outputs


def run_script(filename, *args, env=None, cwd=None):
    """Run a script with sys.executable and GITHUB_OUTPUT pointed at a temp file.

    Returns (exit code, outputs dict, combined stdout+stderr)."""
    with tempfile.TemporaryDirectory() as tmp:
        out_file = os.path.join(tmp, "github_output")
        open(out_file, "w").close()
        full_env = dict(os.environ)
        for key in ("GITHUB_ACTOR", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_SERVER_URL", "AUDIT_FILE",
                    "BASELINE_BRANCH", "SOURCE_PATH"):
            full_env.pop(key, None)
        full_env.update(env or {})
        full_env["GITHUB_OUTPUT"] = out_file
        full_env["PYTHONIOENCODING"] = "utf-8"
        proc = subprocess.run([sys.executable, os.path.join(SCRIPTS, filename), *args],
                              capture_output=True, text=True, encoding="utf-8", errors="replace",
                              env=full_env, cwd=cwd)
        with open(out_file, encoding="utf-8") as fh:
            outputs = parse_outputs(fh.read())
    return proc.returncode, outputs, proc.stdout + proc.stderr


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return path


def package_xml(types, version="66.0"):
    """Build a package.xml string from {type: [members]}."""
    body = []
    for name, members in types.items():
        body.append("    <types>")
        body += [f"        <members>{m}</members>" for m in members]
        body.append(f"        <name>{name}</name>")
        body.append("    </types>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n'
            + "\n".join(body) + ("\n" if body else "")
            + f"    <version>{version}</version>\n</Package>\n")
