#!/usr/bin/env python3
"""Rewrite 6502 branches that ca65 reports as out of range.

    python3 tools/fixbr.py src/kernel/cbm.s      (re-runs ca65 until clean)

`beq far` becomes `bne *+5 / jmp far`.
"""
import re
import subprocess
import sys

INV = {"beq": "bne", "bne": "beq", "bcc": "bcs", "bcs": "bcc",
       "bmi": "bpl", "bpl": "bmi", "bvc": "bvs", "bvs": "bvc"}


def errors(path, inc):
    r = subprocess.run(["ca65", "-I", inc, path, "-o", "/dev/null"], capture_output=True, text=True)
    return [int(m.group(1)) for m in re.finditer(re.escape(path) + r"\((\d+)\): Error: Range error", r.stderr)], r.stderr


def main(path, inc="src/kernel"):
    for _ in range(20):
        lines_bad, err = errors(path, inc)
        if not lines_bad:
            print(err.strip() or f"{path}: ok")
            return
        src = open(path).read().split("\n")
        for n in sorted(set(lines_bad), reverse=True):
            line = src[n - 1]
            m = re.match(r"^(\S*:)?(\s+)(b[a-z]{2})\s+(\S+)(.*)$", line)
            if not m or m.group(3) not in INV:
                print("cannot fix line", n, line)
                return
            label, ws, op, target, rest = m.groups()
            new = []
            if label:
                new.append(label)
            new.append(f"        {INV[op]} *+5")
            new.append(f"        jmp {target}{rest}")
            src[n - 1:n] = new
        open(path, "w").write("\n".join(src))


if __name__ == "__main__":
    main(*sys.argv[1:])
