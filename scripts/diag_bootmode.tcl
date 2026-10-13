# 診断: SLCR BOOT_MODE (0xF800025C) と PC を読む。
# BOOT_MODE[3:0]: 0 = JTAG, 1 = QSPI（Zynq-7000 TRM 6.3.3 / B.28 SLCR）
connect -url tcp:127.0.0.1:3121
after 1500
targets -set -nocase -filter {name =~ "*A9*#0"}
catch {stop}
after 300
puts ">>> PC: [rrd pc]"
puts ">>> BOOT_MODE: [mrd 0xF800025C]"
puts ">>> REBOOT_STATUS: [mrd 0xF8000258]"
con
