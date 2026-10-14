#!/usr/bin/env python3
"""isdbt_eq の表（sin/cos、逆数、パイロット符号）を Verilog の関数として生成する → rtl/isdbt_eq_tables.vh

  python scripts/gen_eq_tables.py

- sincos_tab(i): i = 位相の上位 10bit（turns）→ {sin16, cos16}（±32767 = 1.0、表の中点で評価）
- recip_tab(i): m = 0.5 + (i + 0.5)/2048 → (1/m − 1)·2^16 を丸め（16bit）
- pilot_sign_tab(k): キャリア k のパイロット w_k（STD-B31 図 3-31、g(x) = x^11 + x^9 + 1、全 1 初期化）。1 = 負
"""
import numpy as np
from pathlib import Path

out = Path(__file__).resolve().parents[1] / "rtl" / "isdbt_eq_tables.vh"
lines = ["// 自動生成: scripts/gen_eq_tables.py（手で編集しない）", "// SPDX-License-Identifier: MIT", ""]
lines.append("function [31:0] sincos_tab(input integer i);")
lines.append("  case (i)")
for i in range(1024):
    th = 2 * np.pi * (i + 0.5) / 1024
    c = int(np.clip(round(np.cos(th) * 32767), -32768, 32767)) & 0xFFFF
    s = int(np.clip(round(np.sin(th) * 32767), -32768, 32767)) & 0xFFFF
    lines.append(f"    {i}: sincos_tab = 32'h{s:04X}{c:04X};")
lines.append("    default: sincos_tab = 32'd0;")
lines.append("  endcase")
lines.append("endfunction")
lines.append("")
lines.append("function [15:0] recip_tab(input integer i);")
lines.append("  case (i)")
for i in range(1024):
    m = 0.5 + (i + 0.5) / 2048
    f = int(np.clip(round((1.0 / m - 1.0) * 65536), 0, 65535))
    lines.append(f"    {i}: recip_tab = 16'd{f};")
lines.append("    default: recip_tab = 16'd0;")
lines.append("  endcase")
lines.append("endfunction")
lines.append("")
# PRBS
reg = 0b11111111111
w = []
for k in range(5617):
    w.append(reg & 1)
    new = ((reg >> 2) ^ reg) & 1
    reg = (reg >> 1) | (new << 10)
lines.append("function pilot_sign_tab(input integer k);")
lines.append("  case (k)")
for k in range(5617):
    if w[k]:
        lines.append(f"    {k}: pilot_sign_tab = 1'b1;")
lines.append("    default: pilot_sign_tab = 1'b0;")
lines.append("  endcase")
lines.append("endfunction")
out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
print(f"wrote {out} ({sum(w)} negative pilots of 5617)")
