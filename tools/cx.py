#!/usr/bin/env python3
"""Make a page-relocatable c64os executable (CX format).

The program is linked twice, at origin $0000 and $0100. Bytes that differ
by exactly one are high bytes of absolute addresses; their offsets form the
relocation table. The loader adds the load page to each of them.

Usage: cx.py A.bin B.bin LABELS OUT
  LABELS is an ld65 -Ln file (gives __BSS_SIZE__).

Format: "CX", version 1, image size (2), bss size (2), reloc count (2),
        image, reloc offsets (2 each). All little-endian.
"""
import re
import struct
import sys


def relocs(a, b):
    if len(a) != len(b):
        raise ValueError("builds differ in size")
    out = []
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            if (x + 1) & 0xff != y:
                raise ValueError(f"offset {i:#x}: {x:#x} vs {y:#x} is not a high byte")
            out.append(i)
    return out


def make_cx(a, b, bss):
    r = relocs(a, b)
    hdr = b"CX" + bytes([1]) + struct.pack("<HHH", len(a), bss, len(r))
    return hdr + bytes(a) + b"".join(struct.pack("<H", o) for o in r)


def bss_size(labels_text):
    m = re.search(r"al ([0-9A-Fa-f]+) \.__BSS_SIZE__", labels_text)
    return int(m.group(1), 16) if m else 0


def main():
    a, b, labels, out = sys.argv[1:5]
    with open(a, "rb") as f:
        da = f.read()
    with open(b, "rb") as f:
        db = f.read()
    with open(labels) as f:
        bss = bss_size(f.read())
    with open(out, "wb") as f:
        f.write(make_cx(da, db, bss))


if __name__ == "__main__":
    main()
