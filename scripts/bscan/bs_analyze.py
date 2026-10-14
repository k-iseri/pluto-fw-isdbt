#!/usr/bin/env python3
"""Summarise boundary-scan SAMPLE captures per IO pin.

usage: bs_analyze.py bsdl.json samples.txt [baseline.txt]
For each IO pin prints: ctrl (1 = output disabled = input), out value mean, in value mean,
number of changes between consecutive captures. With a baseline file, also prints the
delta of change counts so that stimulus-induced activity stands out.
"""
import json
import sys

bsdl = json.load(open(sys.argv[1]))
cells = bsdl["cells"]


def load(path):
    return [[int(c) for c in line.strip()] for line in open(path) if line.strip()]


def stats(samples):
    n = len(samples)
    pins = {}
    for c in cells:
        if not c["pin"] or not c["port"].startswith("IO_"):
            continue
        p = pins.setdefault(c["pin"], {})
        col = [s[c["i"]] for s in samples]
        ones = sum(col)
        chg = sum(1 for a, b in zip(col, col[1:]) if a != b)
        if c["func"] == "input":
            p["in"] = ones / n
            p["in_chg"] = chg
        elif c["func"] == "output3":
            p["out"] = ones / n
            p["out_chg"] = chg
            p["ctrl_cell"] = c["ctrl"]
    for c in cells:
        if c["func"] == "controlr":
            for p in pins.values():
                if p.get("ctrl_cell") == c["i"]:
                    col = [s[c["i"]] for s in samples]
                    p["ctrl"] = sum(col) / n
    return pins


samples = load(sys.argv[2])
pins = stats(samples)
base = stats(load(sys.argv[3])) if len(sys.argv) > 3 else None
print(f"{len(samples)} captures")


def key(pin):
    return (pin[0], int(pin[1:]))


print(f"{'pin':5} {'dir':4} {'ctrl':>5} {'out':>5} {'in':>5} {'in_chg':>7} {'out_chg':>8}" + ("  d_in_chg d_out_chg" if base else ""))
for pin in sorted(pins, key=key):
    p = pins[pin]
    d = "out" if p.get("ctrl", 1) < 0.5 else ("in" if p.get("ctrl", 1) > 0.5 else "mix")
    line = f"{pin:5} {d:4} {p.get('ctrl', -1):5.2f} {p.get('out', -1):5.2f} {p.get('in', -1):5.2f} {p.get('in_chg', 0):7d} {p.get('out_chg', 0):8d}"
    if base:
        b = base[pin]
        line += f"  {p.get('in_chg', 0) - b.get('in_chg', 0):8d} {p.get('out_chg', 0) - b.get('out_chg', 0):9d}"
    print(line)
