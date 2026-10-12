# SPDX-License-Identifier: MIT
# Zynq-7000 の boot.bin（BootROM ブートイメージ）パーサ / パーティション抽出。
# JTAG 復旧（docs/jtag-recovery.md）で vendor-boot-backup.bin から FSBL と u-boot を
# 取り出し、ロード/実行アドレスを得るために使う。
#
# フォーマットの根拠: Xilinx UG585 (Zynq-7000 TRM) 6.3.2 BootROM Header、
# UG821 (SW Developers Guide) の Boot Image Layout。
#   0x20: Width Detection 0xAA995566 / 0x24: "XNLX" / 0x30: FSBL source offset
#   0x34: FSBL length / 0x38: FSBL load addr / 0x3C: FSBL exec addr
#   0x98: Image Header Table offset / 0x9C: Partition Header Table offset
#   パーティションヘッダ（0x40 バイト/個）: w0 暗号化長 w1 平文長 w2 総長（いずれも word 単位）
#   w3 load addr / w4 exec addr / w5 データ offset（word）/ w6 属性 / w15 checksum
import struct
import sys
from pathlib import Path


def words(blob, off, n):
    return struct.unpack_from(f"<{n}I", blob, off)


def parse(path: Path, outdir: Path | None):
    blob = path.read_bytes()
    (wdet,) = words(blob, 0x20, 1)
    (ident,) = words(blob, 0x24, 1)
    if wdet != 0xAA995566 or ident != 0x584C4E58:  # "XNLX"
        raise SystemExit(f"not a Zynq boot image (0x20=0x{wdet:08X} 0x24=0x{ident:08X})")
    src, length, load, exec_ = words(blob, 0x30, 4)
    print(f"FSBL: offset=0x{src:X} len={length} load=0x{load:X} exec=0x{exec_:X}")
    if outdir:
        (outdir / "fsbl.bin").write_bytes(blob[src:src + length])
        print(f"  -> fsbl.bin ({length} bytes)")

    (pht_off,) = words(blob, 0x9C, 1)
    print(f"partition header table at 0x{pht_off:X}")
    i = 0
    while True:
        off = pht_off + i * 0x40
        w = words(blob, off, 16)
        if w[0] == 0 and w[1] == 0 and w[2] == 0:   # 終端（全ゼロ or チェックサムのみ）
            break
        if all(x == 0xFFFFFFFF for x in w[:4]):
            break
        data_off = w[5] * 4
        plain_len = w[1] * 4
        print(f"partition {i}: data=0x{data_off:X} len={plain_len} "
              f"load=0x{w[3]:X} exec=0x{w[4]:X} attr=0x{w[6]:08X}")
        if outdir:
            name = outdir / f"part{i}_load{w[3]:08X}.bin"
            name.write_bytes(blob[data_off:data_off + plain_len])
            print(f"  -> {name.name}")
        i += 1
        if i > 8:
            break


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: zynq_bootbin.py <boot.bin|backup.bin> [outdir]")
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    parse(Path(sys.argv[1]), out)
