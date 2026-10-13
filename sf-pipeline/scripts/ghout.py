#!/usr/bin/env python3
"""ghout.py — read one value from a file in $GITHUB_OUTPUT format.

Composite actions run a script with GITHUB_OUTPUT pointed at a scratch file, then pick the
values they need with this, so two scripts in one step can never overwrite each other's
outputs. Handles both `key=value` lines and `key<<DELIM ... DELIM` blocks; the LAST
occurrence of a key wins, as it does in GitHub Actions.

Usage: ghout.py <file> <key>          prints the value ('' when absent)
"""

import sys


def read_outputs(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return values
    i = 0
    while i < len(lines):
        line = lines[i]
        head = line.split("=", 1)[0]
        if "<<" in line and "=" not in line.split("<<", 1)[0]:
            key, delim = line.split("<<", 1)
            buf = []
            i += 1
            while i < len(lines) and lines[i] != delim:
                buf.append(lines[i])
                i += 1
            values[key] = "\n".join(buf)
        elif "=" in line and head:
            key, value = line.split("=", 1)
            values[key] = value
        i += 1
    return values


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    sys.stdout.write(read_outputs(argv[0]).get(argv[1], ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
