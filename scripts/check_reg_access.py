# SPDX-License-Identifier: MIT
# cf-ad9361-lpc の AXI コアレジスタを usb: 経由の iio_device_reg_read で読めるか確認する
# （docs/design-v1.md の VERIFY V3。純正ファームのままで実行できる）。
# カウンタブロック実装後は --offset 0x8000 等で マジック 0x49534442 の確認にも使う。
#
# 実行例（isdbt-sdr の venv を使う。libiio1.dll が .venv\Scripts にある前提）:
#   $env:PATH = "C:\Users\water\isdbt-sdr\.venv\Scripts;" + $env:PATH
#   C:\Users\water\isdbt-sdr\.venv\Scripts\python.exe scripts\check_reg_access.py
#
# 実機確認済み: 2026-10-12、純正 fw v0.39、PCORE version 0x000A0300（axi_ad9361 v10.3）。
import argparse

import iio

# ADI カーネル drivers/iio/adc/cf_axi_adc_core.c の DEBUGFS_DRA_PCORE_REG_MAGIC。
# これを立てると debugfs_reg_access が SPI フォワードでなく AXI コア直読みになる。
PCORE_MAGIC = 0x80000000


def main() -> None:
    ap = argparse.ArgumentParser(description="cf-ad9361-lpc PCORE register read check")
    ap.add_argument("--uri", default="usb:")
    ap.add_argument("--offset", type=lambda s: int(s, 0), action="append",
                    help="読むオフセット（複数可）。省略時は 0x0000(version)/0x0004/0x000C(scratch)")
    args = ap.parse_args()
    offsets = args.offset or [0x0000, 0x0004, 0x000C]

    ctx = iio.Context(args.uri)
    print("context:", ctx.description)
    dev = ctx.find_device("cf-ad9361-lpc")
    if dev is None:
        raise SystemExit("cf-ad9361-lpc が見つからない（Pluto 系か確認）")
    names = list(dev.debug_attrs.keys())
    print("debug attrs:", names)
    if "direct_reg_access" not in names:
        raise SystemExit("direct_reg_access が無い: この経路ではレジスタを読めない")
    for off in offsets:
        v = dev.reg_read(PCORE_MAGIC | off)
        print(f"pcore reg 0x{off:04X} = 0x{v:08X}")


if __name__ == "__main__":
    main()
