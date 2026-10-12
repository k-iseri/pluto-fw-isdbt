# SPDX-License-Identifier: MIT
# recover_nano_xvc.sh から呼ばれる xsdb 側の復旧処理（XVC 経由）。
# 流れは recover_nano.tcl と同じ: vendor FSBL → vendor u-boot を RAM 実行 → 自動 DFU。
set here [file dirname [file normalize [info script]]]
set parts [file normalize "$here/../recovery/vendor-boot-parts"]

connect -url tcp:127.0.0.1:3121
after 2000
puts [jtag targets]
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
puts ">>> vendor u-boot running. SLAVE 側に DFU (0456:b674) が出るはず"
