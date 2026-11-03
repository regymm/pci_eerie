#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-P
"""Rewrite a FASM file into canonical form: every ranged assignment
   NAME[hi:lo] = W'bBITS   (or 'h / 'd / plain decimal)
becomes one NAME[i] line per set bit. Some fasm package builds (e.g. the textX fallback
parser) drop the range of such lines, which makes fasm2frames fail on multi-bit GT attributes.
usage: fasm_canon.py in.fasm > out.fasm"""
import re, sys

rng = re.compile(r"^(\S+)\[(\d+):(\d+)\]\s*=\s*(\S+)\s*$")
one = re.compile(r"^(\S+?)(\[\d+\])?\s*=\s*(\S+)\s*$")

def value(v):
    m = re.match(r"^(\d*)'([bhdo])([0-9a-fA-F_xXzZ]+)$", v)
    if not m:
        return int(v, 0)
    return int(m.group(3).replace("_", ""), {"b": 2, "h": 16, "d": 10, "o": 8}[m.group(2)])

for line in open(sys.argv[1]):
    s = line.split("#", 1)[0].strip()
    if not s:
        continue
    m = rng.match(s)
    if m:
        name, hi, lo, v = m.group(1), int(m.group(2)), int(m.group(3)), value(m.group(4))
        for i in range(hi - lo + 1):
            if (v >> i) & 1:
                print(f"{name}[{lo + i}]")
        continue
    m = one.match(s)
    if m:
        if value(m.group(3)) & 1:
            print(m.group(1) + (m.group(2) or ""))
        continue
    print(s)
