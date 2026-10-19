"""Print the Postgres start command built from pgvector-tune.sh.

    python3 to-start-command.py            # print the start command
    python3 to-start-command.py --check    # exit 1 if template.json differs

The script is joined into one line (comments and blank lines dropped, lines
joined with "; " unless they end in then/do/else) and wrapped in the image's
own entrypoint chain: tini -> bash -c '<script>' -> wrapper.sh postgres ...
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "pgvector-tune.sh"
TEMPLATE = HERE.parent.parent / "template.json"
PREFIX = "/usr/bin/tini -g -- /bin/bash -c '"
SUFFIX = "' pgvector-start postgres -p 5432 -c listen_addresses=*"
OPENERS = ("then", "do", "else")


def build() -> str:
    lines = []
    for raw in SCRIPT.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "'" in line or "\\" in line:
            raise SystemExit(f"single quote or backslash not allowed: {line}")
        lines.append(line)
    out = ""
    for i, line in enumerate(lines):
        out += line
        if i < len(lines) - 1:
            out += " " if line.split()[-1] in OPENERS else "; "
    return PREFIX + out + SUFFIX


def main() -> int:
    command = build()
    if "--check" in sys.argv:
        current = json.loads(TEMPLATE.read_text(encoding="utf-8"))["services"]["Postgres"]["startCommand"]
        if current != command:
            print("template.json startCommand is out of date; run without --check and paste the output")
            return 1
        print(f"OK: template.json startCommand matches pgvector-tune.sh ({len(command)} chars)")
        return 0
    print(command)
    return 0


if __name__ == "__main__":
    sys.exit(main())
