# PlutoSDR Nano (HamGeek, XC7Z010-CLG400 + AD9363) — AD9361 インターフェースのピン配置
#
# 由来: 2026-10-14 に JTAG バウンダリスキャン（SAMPLE/PRELOAD のみ、ピン非駆動）で実測した
#       結果。手順と根拠は docs/pinout-nano.md、スクリプトは scripts/bscan/。
#       ADI 公式 projects/pluto/system_constr.xdc（xc7z010clg225）の AD9361 部分を
#       置き換えるもの。PS 側（MIO / DDR / PS_CLK など）はパッケージ固定なので書かない。
#
# 確度:
#   [A] 刺激に対する応答で一意に確定（データ線はビット番号まで）
#   [B] 消去法 + 回路上の制約で確定（rx_clk: トグル入力 14 本中、唯一のクロック対応ピン）
#   [C] 2 候補のどちらか不明（enable / txnrx。どちらも現行設計では L 固定駆動なので入替えても無害）
#   [-] 未同定。公式設計のポートはこの基板向けトップでは削除する（docs/pinout-nano.md）
#
# 全ピン Bank 34 / 35（VCCO 1.8 V）。IOSTANDARD は公式と同じ LVCMOS18。

# ---- RX（AD9361 → FPGA）----
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS18} [get_ports rx_clk_in]      ;# [B] IO_L13P_T2_MRCC_35
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS18} [get_ports rx_frame_in]    ;# [A] IO_L10P_T1_AD11P_35
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS18} [get_ports rx_data_in[0]]  ;# [A] IO_L3P_T0_DQS_AD1P_35
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS18} [get_ports rx_data_in[1]]  ;# [A] IO_L16N_T2_35
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS18} [get_ports rx_data_in[2]]  ;# [A] IO_L5P_T0_AD9P_35
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS18} [get_ports rx_data_in[3]]  ;# [A] IO_L18P_T2_AD13P_35
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS18} [get_ports rx_data_in[4]]  ;# [A] IO_L1N_T0_AD0N_35
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS18} [get_ports rx_data_in[5]]  ;# [A] IO_L15N_T2_DQS_AD12N_35
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS18} [get_ports rx_data_in[6]]  ;# [A] IO_L17N_T2_AD5N_35
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS18} [get_ports rx_data_in[7]]  ;# [A] IO_L1P_T0_AD0P_35
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS18} [get_ports rx_data_in[8]]  ;# [A] IO_L2N_T0_AD8N_35
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS18} [get_ports rx_data_in[9]]  ;# [A] IO_L4P_T0_35
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS18} [get_ports rx_data_in[10]] ;# [A] IO_L2P_T0_AD8P_35
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS18} [get_ports rx_data_in[11]] ;# [A] IO_L17P_T2_AD5P_35

# ---- TX（FPGA → AD9361）----
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS18} [get_ports tx_clk_out]      ;# [A] IO_L12P_T1_MRCC_35
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS18} [get_ports tx_frame_out]    ;# [A] IO_L4N_T0_35
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS18} [get_ports tx_data_out[0]]  ;# [A] IO_L16P_T2_35
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS18} [get_ports tx_data_out[1]]  ;# [A] IO_L14N_T2_AD4N_SRCC_35
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS18} [get_ports tx_data_out[2]]  ;# [A] IO_L18N_T2_AD13N_35
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS18} [get_ports tx_data_out[3]]  ;# [A] IO_L14P_T2_AD4P_SRCC_35
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS18} [get_ports tx_data_out[4]]  ;# [A] IO_L3N_T0_DQS_AD1N_35
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS18} [get_ports tx_data_out[5]]  ;# [A] IO_L10N_T1_AD11N_35
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS18} [get_ports tx_data_out[6]]  ;# [A] IO_L24P_T3_AD15P_35
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS18} [get_ports tx_data_out[7]]  ;# [A] IO_L12N_T1_MRCC_35
set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS18} [get_ports tx_data_out[8]]  ;# [A] IO_L9N_T1_DQS_AD3N_35
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS18} [get_ports tx_data_out[9]]  ;# [A] IO_L9P_T1_DQS_AD3P_35
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS18} [get_ports tx_data_out[10]] ;# [A] IO_L5N_T0_AD9N_35
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS18} [get_ports tx_data_out[11]] ;# [A] IO_L11P_T1_SRCC_35

# ---- 制御 ----
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS18 PULLTYPE PULLUP} [get_ports spi_csn] ;# [A] IO_L17N_T2_34
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS18} [get_ports spi_clk]   ;# [A] IO_L16N_T2_34
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS18} [get_ports spi_mosi]  ;# [A] IO_L16P_T2_34
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS18} [get_ports spi_miso]  ;# [A] IO_L17P_T2_34
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS18} [get_ports gpio_resetb] ;# [B] IO_L22N_T3_34（初期化後 H 固定の出力は csn 以外にこれだけ）
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS18} [get_ports enable]    ;# [C] IO_L15P_T2_DQS_34（T20/U20 のどちらか）
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS18} [get_ports txnrx]     ;# [C] IO_L15N_T2_DQS_34（T20/U20 のどちらか）

# 未同定 [-]: clk_out, gpio_en_agc, gpio_ctl[3:0], gpio_status[7:0], pl_gpio0..4
#   → この基板向け system_top では削除（または内部で未接続）にして、未知のピンを駆動しない。

# ---- クロック（公式と同じ）----
create_clock -name rx_clk    -period 16.27 [get_ports rx_clk_in]
create_clock -name clk_fpga_0 -period 10   [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[0]"]
create_clock -name clk_fpga_1 -period  5   [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[1]"]
create_clock -name spi0_clk   -period 40   [get_pins -hier */EMIOSPI0SCLKO]
set_input_jitter clk_fpga_0 0.3
set_input_jitter clk_fpga_1 0.15

set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_rx/i_up_adc_common/up_adc_gpio_out_int_reg[0]/C}]
set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_tx/i_up_dac_common/up_dac_gpio_out_int_reg[0]/C}]
