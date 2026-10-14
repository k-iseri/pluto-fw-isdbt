#!/usr/bin/env python3
"""isdbt_sync_tb の結果（sync_events.txt、sync_out.txt）を真値（sync_stim.json）と照合する。

  python scripts/check_sync_sim.py <dir>   # dir に sync_stim.json / sync_events.txt / sync_out.txt
"""
import json
import re
import sys
from pathlib import Path

import numpy as np

N, NG, MARGIN = 8192, 1024, 128
d = Path(sys.argv[1])
meta = json.loads((d / "sync_stim.json").read_text())
truth = np.array(meta["useful_starts"]) - MARGIN          # FPGA が開くべき窓の開始（小数）
ev = []
for line in (d / "sync_events.txt").read_text().splitlines():
    m = re.match(r"start (\d+) locked (\d) cfo_inc (-?\d+) peak (\d+) at (\d+)", line)
    if m:
        ev.append(tuple(int(v) for v in m.groups()))
ev = np.array(ev)
print(f"events {len(ev)}, truth boundaries {len(truth)}, cfo {meta['cfo_bins']:.3f} bins, ppm {meta['ppm']}")
if len(ev) == 0:
    sys.exit("no events")
starts = ev[:, 0]
# 各イベントを最も近い真値に対応づけ（真値の範囲外のイベントは除く）
errs = []
for s in starts:
    if s < truth.min() - 200 or s > truth.max() + 200:
        continue
    k = np.argmin(np.abs(truth - s))
    errs.append(s - truth[k])
errs = np.array(errs)
# 合格: 窓が GI の内側（真の有効部分開始に対して −(Ng−margin) 〜 0、実用上は [−200, +60]）に収まり、揺れが小さい
print(f"start error vs truth [samples]: mean {errs.mean():.2f}, std {errs.std():.2f}, min {errs.min():.2f}, max {errs.max():.2f} (n={len(errs)})")
print(f"first 6 starts: {starts[:6].tolist()}  diffs: {np.diff(starts[:7]).tolist()}")
print(f"locked flags: first {ev[:, 1][:5].tolist()} ... last {ev[:, 1][-3:].tolist()}")
frac = meta["cfo_bins"] - round(meta["cfo_bins"])
inc_expect = -frac / N * 2 ** 32
inc_last = ev[-1, 2]
print(f"cfo_inc: last {inc_last}, expected {inc_expect:.0f} (frac {frac:.4f} bins) -> estimate {-inc_last * N / 2 ** 32:.4f} bins")
# DMA 出力のヘッダ
w = np.array([int(l, 16) for l in (d / "sync_out.txt").read_text().split()], dtype=np.uint32) if (d / "sync_out.txt").exists() else np.array([], dtype=np.uint32)
hdrs = []
i = 0
while i + 8 + N <= len(w):
    if w[i] != 0x49534254:
        i += 1
        continue
    hdrs.append((int(w[i + 2]) | (int(w[i + 3]) << 32), int(w[i + 4]), int(np.int32(w[i + 6])), int(w[i + 7])))
    i += 8 + N
print(f"dma frames {len(hdrs)}; first {hdrs[:3]}")
ok = (len(ev) >= 0.8 * len(truth) and errs.min() > -200 and errs.max() < 60 and errs[5:].std() < 8
      and abs(-inc_last * N / 2 ** 32 - frac) < 0.02 and ev[-1, 1] == 1)
print("PASS" if ok else "FAIL")
