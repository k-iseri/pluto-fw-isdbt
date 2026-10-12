#!/bin/bash
# SPDX-License-Identifier: MIT
# Raspberry Pi Pico (xvc-pico) + Vivado xsdb での Pluto Nano 復旧（ルート A'）。
# 前提:
#   - Pico に recovery/xvcPico-pico.uf2 を書き込み済み（Pico 2 なら xvcPico-pico2.uf2。
#     BOOTSEL を押しながら USB 接続 → RPI-RP2 ドライブに uf2 をドラッグ）
#   - 配線: Pico GP16→TDI / GP17→TDO / GP18→TCK / GP19→TMS / GND→GND（3.3V は繋がない）
#   - ボードは「short JTAG」パッドをショートして SLAVE USB で給電（BootROM が JTAG 待ち）
#   - usbipd で Pico（xvcPico）を WSL へ attach 済み
#   - ~/xvc-pico/daemon/xvcd-pico ビルド済み、Vivado 2023.2 導入済み
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PARTS="$HERE/../recovery/vendor-boot-parts"
source /opt/Xilinx/Vivado/2023.2/settings64.sh

echo ">>> starting xvcd-pico (XVC daemon, port 2542)"
sudo pkill -f xvcd-pico 2>/dev/null || true
sudo "$HOME/xvc-pico/daemon/xvcd-pico" > /tmp/xvcd.log 2>&1 &
sleep 2
grep -q . /tmp/xvcd.log && head -3 /tmp/xvcd.log

echo ">>> starting hw_server with XVC auto-open"
pkill -f hw_server 2>/dev/null || true
hw_server -d -e "set auto-open-servers xilinx-xvc:localhost:2542" -e "set auto-open-ports 1"
sleep 2

echo ">>> running xsdb recovery"
xsdb "$HERE/recover_nano_xvc.tcl"
