# SPDX-License-Identifier: MIT
# Pluto Nano クローンの JTAG 復旧（docs/jtag-recovery.md 参照）。
# 前提: ベンダー boot バックアップから scripts/zynq_bootbin.py で抽出した
#   recovery/vendor-boot-parts/fsbl.bin               (load/exec 0x0)
#   recovery/vendor-boot-parts/part1_load04000000.bin (u-boot, load/exec 0x4000000)
# 使い方: Vivado 環境で  xsdb recover_nano.tcl
# （WSL から USB JTAG を使う場合は usbipd attach 済みであること）
#
# 流れ: CPU 停止 → ベンダー FSBL を OCM(0x0) へ → 実行（DDR 初期化）
#       → 停止 → ベンダー u-boot を DDR(0x4000000) へ → 実行
#       → u-boot は QSPI の itb（tezuka 残骸、lzma）を起動できず自動で DFU モードに入る
#       → ホストから dfu-util で vendor-boot-backup.bin / 自ビルド pluto.dfu を書き戻す

set here [file dirname [file normalize [info script]]]
set parts [file normalize "$here/../recovery/vendor-boot-parts"]

connect
targets -set -nocase -filter {name =~ "*A9*#0"}
stop
puts ">>> loading vendor FSBL to OCM 0x0"
dow -data "$parts/fsbl.bin" 0x0
rwr pc 0
con
puts ">>> FSBL running (DDR init)... waiting 4 s"
after 4000
stop
puts ">>> loading vendor u-boot to 0x4000000"
dow -data "$parts/part1_load04000000.bin" 0x4000000
rwr pc 0x4000000
con
puts ">>> vendor u-boot running. QSPI の itb 起動に失敗して自動で DFU に入るはず"
puts ">>> ホスト側で 'USB download gadget' (0456:b674) の出現を確認して dfu-util で復元する"
