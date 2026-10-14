#!/usr/bin/env python3
"""isdbt_gi_corr の出力（sync_corr.txt）を numpy の同じ計算（8bit 量子化入力）と照合する。
  python scripts/check_corr_sim.py <dir>   # dir に sync_stim.txt / sync_corr.txt / sync_stim.json
"""
import json
import sys
from pathlib import Path

import numpy as np

N, NG = 8192, 1024
d = Path(sys.argv[1])
def load_stim(path):
    """16 進 2 の補数 "iiii qqqq" → int64 (n, 2)"""
    v = np.array([int(t, 16) for t in path.read_text().split()], dtype=np.int64).reshape(-1, 2)
    return np.where(v >= 32768, v - 65536, v)


stim = load_stim(d / "sync_stim.txt")
corr = np.loadtxt(d / "sync_corr.txt", dtype=np.int64)
meta = json.loads((d / "sync_stim.json").read_text())


def pack8(v, shift=3):
    a = np.abs(v)
    r = (a + (1 << (shift - 1))) >> shift
    return np.clip(np.where(v < 0, -r, r), -128, 127)


xi = pack8(stim[:, 0])
xq = pack8(stim[:, 1])
x = xi + 1j * xq
n = len(x)
p = np.zeros(n, dtype=np.complex128)
p[N:] = x[N:] * np.conj(x[:-N])
c = np.cumsum(p)
c[NG:] = c[NG:] - c[:-NG]           # 移動和 Ng
# HDL: 出力は warm >= N+NG 以降。idx はサンプル番号
idx = corr[:, 0]
cre, cim, mag2 = corr[:, 1], corr[:, 2], corr[:, 3]
ref_re, ref_im = np.round(c.real[idx]), np.round(c.imag[idx])
print(f"corr samples {len(idx)}, idx range {idx.min()}..{idx.max()}")
print(f"re mismatch count {np.count_nonzero(cre != ref_re)}, im {np.count_nonzero(cim != ref_im)} / {len(idx)}")
bad = np.where((cre != ref_re) | (cim != ref_im))[0]
if len(bad):
    print("first bad:", [(int(idx[k]), int(cre[k]), int(ref_re[k]), int(cim[k]), int(ref_im[k])) for k in bad[:5]])
ref_mag = (ref_re.astype(np.int64) >> 12) ** 2 + (ref_im.astype(np.int64) >> 12) ** 2
print(f"mag2 mismatch {np.count_nonzero(mag2 != ref_mag)}")
# 真のピーク位置: useful_start − 1 + ... シンボル末尾 = useful_start + N − 1（有効部分の終わり）
peaks_truth = np.array(meta["useful_starts"]) + N - 1
m = np.abs(c)
for t in peaks_truth[:5]:
    t = int(round(t))
    seg = m[t - 100:t + 100]
    print(f"truth peak {t}: argmax within ±100 at {t - 100 + int(np.argmax(seg))}, |c| {seg.max():.0f}, median |c| {np.median(m[t-4000:t+4000]):.0f}")
