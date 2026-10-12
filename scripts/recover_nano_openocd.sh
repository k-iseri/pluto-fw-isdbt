#!/bin/bash
# SPDX-License-Identifier: MIT
# OpenOCD + FT232H での Pluto Nano 復旧（docs/jtag-recovery.md 参照）。
# 前提: 基板の「short JTAG」パッドをショートして電源投入（BootROM が JTAG 待ちで停止）。
#       usbipd で FT232H (0403:6014) を WSL へ attach 済み。
# 動作: vendor FSBL を OCM(0x0) で実行（DDR 初期化）→ vendor u-boot を 0x4000000 で実行
#       → u-boot が QSPI の itb 起動に失敗して自動で DFU モードに入る
#       →（SLAVE 側 USB に 0456:b674 が出る）→ dfu-util で書き戻し
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PARTS="$HERE/../recovery/vendor-boot-parts"

openocd -f "$HERE/ft232h-zynq.cfg" \
  -c "init" \
  -c "targets zynq.cpu0" \
  -c "halt" \
  -c "echo {>>> loading vendor FSBL to OCM 0x0}" \
  -c "load_image $PARTS/fsbl.bin 0x0 bin" \
  -c "resume 0x0" \
  -c "echo {>>> FSBL running (DDR init), waiting 4 s}" \
  -c "sleep 4000" \
  -c "halt" \
  -c "echo {>>> loading vendor u-boot to 0x4000000}" \
  -c "load_image $PARTS/part1_load04000000.bin 0x4000000 bin" \
  -c "resume 0x4000000" \
  -c "echo {>>> vendor u-boot running; expect auto-DFU on SLAVE port. Ctrl-C to exit openocd}" \
  -c "sleep 8000" \
  -c "shutdown"
