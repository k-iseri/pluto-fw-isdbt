#!/usr/bin/env python3
"""Parse a Xilinx BSDL file into a compact JSON description of the boundary register.

Output: {"entity":..., "ir_len":6, "bsr_len":770, "opcodes":{"SAMPLE":"000001",...},
         "cells":[{"i":0,"port":"IO_U19"|null,"pin":"U19"|null,"func":"input"|"output3"|"controlr"|"internal",
                   "ctrl":101|null,"dis":1|null}]}
"""
import json
import re
import sys

src = open(sys.argv[1], encoding="latin-1").read()

m = re.search(r"INSTRUCTION_LENGTH of (\w+)\s*:\s*entity is (\d+)", src)
entity, ir_len = m.group(1), int(m.group(2))
bsr_len = int(re.search(r"BOUNDARY_LENGTH of \w+\s*:\s*entity is (\d+)", src).group(1))

op_block = re.search(r"INSTRUCTION_OPCODE of \w+\s*:\s*entity is(.*?);", src, re.S).group(1)
opcodes = {k: v for k, v in re.findall(r"(\w+)\s+\((\d+)\)", op_block)}

# pin map: "PORT:PIN," or "PORT:(P1,P2,...)" — we only need single-pin ports
pm = re.search(r"PIN_MAP_STRING\s*:=(.*?);", src, re.S).group(1)
pm = "".join(re.findall(r'"([^"]*)"', pm))
pinmap = {}
for ent in re.finditer(r"(\w+):(\([^)]*\)|[A-Z]+\d+)", pm):
    port, pins = ent.group(1), ent.group(2)
    if not pins.startswith("("):
        pinmap[port] = pins

cells = []
for cm in re.finditer(r'"\s*(\d+)\s*\((BC_\d),\s*([^,]+),\s*(\w+),\s*([^,)]+)(?:,\s*(\d+),\s*(\d),\s*(\w))?\)', src):
    i = int(cm.group(1))
    port = cm.group(3).strip()
    port = None if port == "*" else port
    pin = None
    if port:
        pin = pinmap.get(port)
        if pin is None and port.startswith("IO_"):
            pin = port[3:]
    cells.append({"i": i, "port": port, "pin": pin, "func": cm.group(4),
                  "ctrl": int(cm.group(6)) if cm.group(6) else None,
                  "dis": int(cm.group(7)) if cm.group(7) else None})
cells.sort(key=lambda c: c["i"])
assert len(cells) == bsr_len, (len(cells), bsr_len)
assert [c["i"] for c in cells] == list(range(bsr_len))

json.dump({"entity": entity, "ir_len": ir_len, "bsr_len": bsr_len, "opcodes": opcodes, "cells": cells},
          open(sys.argv[2], "w"), indent=0)
io = sorted({c["pin"] for c in cells if c["pin"] and c["port"].startswith("IO_")})
print(f"{entity}: IR {ir_len}, BSR {bsr_len} cells, {len(io)} IO pins, {len(opcodes)} opcodes")
