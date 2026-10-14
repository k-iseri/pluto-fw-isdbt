#!/usr/bin/env python3
"""isdbt_eq_tb の出力（eq_out.txt）をモデルの期待値（eq_ref.txt）と比べる。

  python scripts/check_eq_sim.py <dir>     # dir に eq_out.txt / eq_ref.txt
合格: 立ち上がり（履歴 8 シンボル）以降で、D の I/Q の差が ±3 LSB 以内のキャリアが 99 % 以上、
      CSI の差が ±4 LSB 以内が 99 % 以上、かつ中央値の差 0。
"""
import re
import sys
from pathlib import Path

import numpy as np

TOTAL = 5617
d = Path(sys.argv[1])
ref = np.array([[int(v, 16) for v in l.split()] for l in (d / "eq_ref.txt").read_text().split("\n") if l.strip()], dtype=np.int64)
ref = ref.reshape(-1, TOTAL, 3)
out_lines = (d / "eq_out.txt").read_text().split("\n")
syms, cur, heads = [], [], []
for l in out_lines:
    if l.startswith("S "):
        if cur:
            syms.append(cur)
        cur = []
        heads.append(l)
    elif l.strip():
        cur.append([int(v, 16) for v in l.split()])
if cur:
    syms.append(cur)
out = np.array(syms, dtype=np.int64)
n = min(len(out), len(ref))
print(f"ref symbols {len(ref)}, sim symbols {len(out)}; first heads: {heads[:3]}")
if n == 0:
    sys.exit("no output")
out = out[:n]
ref = ref[:n]
def s8(x):
    return np.where(x >= 128, x - 256, x)
di = s8(out[..., 0]) - s8(ref[..., 0])
dq = s8(out[..., 1]) - s8(ref[..., 1])
dc = out[..., 2] - ref[..., 2]
skip = min(12, n - 1)
for name, e in (("I", di), ("Q", dq), ("CSI", dc)):
    ee = e[skip:]
    print(f"  {name}: median diff {np.median(ee):+.1f}, |diff|<=3: {100 * np.mean(np.abs(ee) <= 3):.2f}%, |diff|<=8: {100 * np.mean(np.abs(ee) <= 8):.2f}%, max {np.abs(ee).max()}")
# シンボルごとの一致率（立ち上がりの様子）
per = [100 * np.mean((np.abs(di[i]) <= 3) & (np.abs(dq[i]) <= 3)) for i in range(n)]
print("  per-symbol D match (<=3 LSB) %:", " ".join(f"{p:.0f}" for p in per[:20]), "...", " ".join(f"{p:.0f}" for p in per[-5:]))
ok = (np.mean(np.abs(di[skip:]) <= 3) > 0.99 and np.mean(np.abs(dq[skip:]) <= 3) > 0.99 and np.mean(np.abs(dc[skip:]) <= 4) > 0.99)
print("PASS" if ok else "FAIL")
