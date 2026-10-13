# SPDX-License-Identifier: MIT
# 実機で成功した復旧シーケンス（2026-10-13）。recover_nano_xvc.sh から呼ぶ。
# 前提: POR 時に short JTAG パッドをピンセットで短絡（ラッチ後に離す）し BOOT_MODE=0 にしておく。
# rst -processor では周辺が初期化されないため、やり直す際は rst -system を使う（docs/jtag-recovery.md）。
set parts "/mnt/c/Users/water/pluto-fw-isdbt/recovery/vendor-boot-parts"

connect -url tcp:127.0.0.1:3121
after 2000
targets -set -nocase -filter {name =~ "*A9*#0"}
catch {stop}
after 500
puts ">>> processor reset"
rst -processor
after 1000
catch {stop}
puts ">>> PC after reset: [rrd pc]"
puts ">>> loading vendor FSBL to OCM 0x0"
dow -data "$parts/fsbl.bin" 0x0
rwr pc 0
con
after 4000
catch {stop}
puts ">>> PC after FSBL run: [rrd pc]"
puts ">>> loading vendor u-boot to 0x4000000"
dow -data "$parts/part1_load04000000.bin" 0x4000000
rwr pc 0x4000000
con
puts ">>> u-boot resumed. 10 s 待って状態確認"
after 10000
catch {stop}
puts ">>> PC in u-boot phase: [rrd pc]"
con
puts ">>> done (running)"
