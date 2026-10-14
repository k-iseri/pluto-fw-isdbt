#!/usr/bin/env python3
"""isdbt_sync の検証用スティミュラス: isdbt-sdr の合成 ISDB-T 信号（cf32、公称レート）に
周波数オフセットとサンプルクロック偏差を掛け、12bit I/Q（int16、[-2047, 2047]）のテキストにする。

  python scripts/make_sync_stimulus.py <in.sigmf-data> <out_dir> --symbols 40 --cfo-hz 3000 --ppm -16

出力: <out_dir>/sync_stim.txt（1 行 "I Q"）、<out_dir>/sync_stim.json（真のシンボル境界など）
numpy のみ（ref/ 不要）。
"""
import argparse
import json
from pathlib import Path

import numpy as np

N, NG = 8192, 1024
T = N + NG
FS = 512e6 / 63


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sigmf_data")
    ap.add_argument("out_dir")
    ap.add_argument("--symbols", type=int, default=40)
    ap.add_argument("--skip-symbols", type=int, default=10, help="先頭を捨てる（境界の位相をずらす）")
    ap.add_argument("--offset", type=int, default=777, help="先頭に足す追加サンプル数（境界が 0 に来ないように）")
    ap.add_argument("--cfo-hz", type=float, default=3000.0)
    ap.add_argument("--ppm", type=float, default=-15.6, help="受信クロック偏差（負 = 受信側が遅い）")
    ap.add_argument("--rms", type=float, default=180.0, help="出力の RMS（12bit LSB）")
    ap.add_argument("--cn-db", type=float, default=30.0)
    ap.add_argument("--seamless", action="store_true",
                    help="巡回送信（実機ループバック）用: 長さを T の整数倍にし、CFO を継ぎ目で連続になる値に丸め、ppm は 0")
    ap.add_argument("--tx-bin", action="store_true", help="TX 用の int16 I,Q 交互（12bit を [15:4]）の sync_stim.bin も書く")
    args = ap.parse_args()
    if args.seamless:
        args.ppm = 0.0
        L = args.symbols * T
        args.cfo_hz = round(args.cfo_hz / (FS / L)) * (FS / L)
        args.offset = 0

    x = np.fromfile(args.sigmf_data, dtype=np.complex64)
    n_need = (args.symbols + args.skip_symbols + 2) * T
    x = x[: n_need].astype(np.complex128)
    # CFO
    n = np.arange(len(x))
    x = x * np.exp(2j * np.pi * args.cfo_hz / FS * n)
    # クロック偏差: 受信側のサンプル間隔が (1 + ppm·1e-6) 倍 → 入力位置 t_k = k·(1+ppm·1e-6)
    ratio = 1.0 + args.ppm * 1e-6
    k = np.arange(int(len(x) / ratio) - 2)
    t = k * ratio
    xr = np.interp(t, n, x.real) + 1j * np.interp(t, n, x.imag)
    # 先頭を捨てて境界の位相をずらす
    start = args.skip_symbols * T + args.offset
    xr = xr[start:]
    if args.seamless:
        xr = xr[: args.symbols * T]
    # 雑音
    rng = np.random.default_rng(7)
    p = np.mean(np.abs(xr) ** 2)
    noise = (rng.standard_normal(len(xr)) + 1j * rng.standard_normal(len(xr))) * np.sqrt(p / 2 / (10 ** (args.cn_db / 10)))
    xr = xr + noise
    # スケール・量子化
    g = args.rms / np.sqrt(np.mean(np.abs(xr) ** 2))
    xi = np.clip(np.round(xr.real * g), -2047, 2047).astype(np.int16)
    xq = np.clip(np.round(xr.imag * g), -2047, 2047).astype(np.int16)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    # xsim の $fscanf は "%d %d" で両方負の行（"-36 -154"）を読めない（r=1 で止まる）ので、16bit 2 の補数の
    # 16 進で書く（"%h %h"）。CRLF も避ける
    with open(out / "sync_stim.txt", "w", newline="\n") as f:
        for a, b in zip(xi.astype(np.int64), xq.astype(np.int64)):
            f.write(f"{a & 0xFFFF:04x} {b & 0xFFFF:04x}\n")
    # 真のシンボル境界（出力サンプル番号）: 元信号のシンボル m は [m·T, (m+1)·T)。出力サンプル k は
    # 入力位置 start + k·ratio を見る → 有効部分の開始（m·T + NG）が出力のどこに来るか
    bounds = []
    for m in range(args.skip_symbols, args.skip_symbols + args.symbols + 1):
        k_useful = ((m * T + NG) - start) / ratio
        if 0 <= k_useful < len(xi):
            bounds.append(k_useful)
    if args.tx_bin:
        txb = np.empty(2 * len(xi), dtype="<i2")
        txb[0::2] = (xi.astype(np.int64) << 4).astype(np.int16)
        txb[1::2] = (xq.astype(np.int64) << 4).astype(np.int16)
        txb.tofile(out / "sync_stim.bin")
    meta = {"n_samples": int(len(xi)), "cfo_hz": args.cfo_hz, "cfo_bins": args.cfo_hz / (FS / N),
            "ppm": args.ppm, "useful_starts": bounds, "T_out": T / ratio, "rms": args.rms}
    (out / "sync_stim.json").write_text(json.dumps(meta, indent=1))
    print(f"wrote {len(xi)} samples, {len(bounds)} symbol boundaries, cfo {meta['cfo_bins']:.3f} bins, T_out {T / ratio:.3f}")


if __name__ == "__main__":
    main()
