# PlutoSDR Nano の FPGA ピン配置をバウンダリスキャンで実測する

2026-10-14。HamGeek 製 PlutoSDR Nano（XC7Z010-CLG400 + AD9363）には回路図も XDC も無い。
tezuka_fw（F5OEO、GPL-3）の nano 向けビットストリームはこの基板で動く（docs/sdr-revival.md）が、
その XDC は公開されていない。自前の HDL（design-v1.md）を作るには AD9361 ↔ FPGA の配線が要るので、
**tezuka の PL を動かしたまま JTAG バウンダリスキャンでピンの実値を観測し**、刺激への応答から
信号を特定した。結果は [hdl/plutosdr-nano/system_constr.xdc](../hdl/plutosdr-nano/system_constr.xdc)。

## 方法

- JTAG は docs/jtag-recovery.md と同じ Raspberry Pi Pico WH（xvc-pico）。ただし hw_server / xsdb は
  使わず、`scripts/bscan/xvcjtag.py` が XVC プロトコルで直接 TAP を叩く（1 回の取り込み 2〜7 ms）。
- 流す命令は IDCODE / BYPASS / **SAMPLE/PRELOAD だけ**。EXTEST は使わない（ピンを一切駆動しない）。
  SAMPLE はデバイスの動作に影響しないので、SDR が受信中のまま何度でも取れる。
- BSDL は Vivado 同梱 `data/parts/xilinx/zynq/public/bsdl/xc7z010_clg400.bsd`
  （IR 6 bit、バウンダリレジスタ 770 セル、IO ピン 100 本。各 IO は control / output3 / input の 3 セル）。
- チェーン: TDI → ARM DAP (0x4ba00477, IR 4) → xc7z010 (0x13722093, IR 6) → TDO。
- 刺激は Pluto に ssh して与える（root/analog）。1 回の試験は「取り込み開始 → 1 秒後に刺激 → 取り込み終了」
  （`run_stim.sh`）。解析は `bs_analyze.py` で、ピンごとに control（1 = 出力無効 = 入力）、
  出力値 / 入力値の平均、連続取り込み間の変化回数を出す。

### 刺激と判定

| 対象 | 刺激 | 判定 |
|---|---|---|
| 全体像 | なし（受信中） | トグルする入力 14 本 = rx_clk + rx_frame + rx_data×12。トグル出力 2 本 = tx_clk / tx_frame。H 固定出力 2 本 = spi_csn / resetb。L 固定出力 16 本 = tx_data×12 ほか |
| rx_clk | — | 14 本のうちクロック対応（MRCC/SRCC）ピンは H16 だけ |
| SPI | `direct_reg_access` でアドレス 0x000 と 0x3FF を連続読み出し | csn: H 固定出力のうち落ちる方（Y19）。miso: トグルする入力（Y18）。0x000 読み出しで一度もトグルしない出力が mosi（V20）、常にトグルするのが clk（W20） |
| tx_data[k] | `iio_writedev -c` で I=Q=(1<<k)<<4 の定数サンプルを巡回送信 | H になる出力が 1 本ずつ（12 回） |
| tx_frame / tx_clk | DAC コア CNTRL_2（0x48）の R1_MODE ビットを一時的に 0 にする | HDL（axi_ad9361_cmos_if.v）上 frame が H 固定になる。止まった方が frame（D20）、残りが clk（K17）。終了後 0x20 に戻す |
| rx_data[k] | AD9361 `loopback`=1（デジタル TX→RX）で上と同じ定数送信 | H になる入力が 1 本ずつ（12 回）。全 1 / 全 0 送信でデータ線が静止し、残ってトグルする入力が rx_clk（H16）と rx_frame（K19） |

AD9361 側の設定（Pluto 標準）: reg 0x010 = 0xC8（PP Tx/Rx Swap IQ、Rx Frame Pulse Mode）、
0x012 = 0x42（Swap Ports、Full Port）。I=Q で送っているのでスワップはビット番号に影響しない。

## 結果

| 信号 | ピン | 機能名 | 確度 |
|---|---|---|---|
| rx_clk_in | H16 | IO_L13P_T2_MRCC_35 | B（消去法 + CC ピン） |
| rx_frame_in | K19 | IO_L10P_T1_AD11P_35 | A |
| rx_data_in[11:0] | J20 B19 D19 A20 C20 H20 F20 B20 G19 E18 G18 E17 | （[11] → [0] の順） | A |
| tx_clk_out | K17 | IO_L12P_T1_MRCC_35 | A |
| tx_frame_out | D20 | IO_L4N_T0_35 | A |
| tx_data_out[11:0] | L16 E19 L19 L20 K18 K16 J19 D18 J18 G20 H18 G17 | （[11] → [0] の順） | A |
| spi_csn | Y19 | IO_L17N_T2_34 | A |
| spi_clk | W20 | IO_L16N_T2_34 | A |
| spi_mosi | V20 | IO_L16P_T2_34 | A |
| spi_miso | Y18 | IO_L17P_T2_34 | A |
| gpio_resetb | W19 | IO_L22N_T3_34 | B（初期化後 H 固定の出力は csn 以外これだけ） |
| enable / txnrx | T20 / U20 | IO_L15P/N_T2_DQS_34 | C（どちらがどちらか不明。両方 L 固定駆動） |

全て Bank 34 / 35（1.8 V）。公式 Pluto（clg225）とは完全に別配置で、流用できる行は無い。

未同定: clk_out、gpio_en_agc、gpio_ctl[3:0]、gpio_status[7:0]、pl_gpio0..4。
tezuka の設計で入力かつ H 固定のピンが 11 本ある（N17 N18 N20 P14 P15 P16 R19 T17 T19 U13 U18）ので
gpio_status（AD9361 CTRL_OUT）や clk_out はこの中にあると思われるが、非侵襲で動かす手段が無いので
未確定。**v1 の HDL ではこれらのポートをトップから外す**（未知のピンを出力として駆動しない）。
enable / txnrx は FDD かつ SPI 制御の ENSM では使われず、現行設計でも両方 L なので、
入れ替わっていても動作に影響しない（TDD は使わない）。

## 再現手順

```
# WSL（Pico を usbipd で attach 済み、xvcd-pico 起動済み、hw_server は止める）
cd scripts/bscan
python3 bsdl_parse.py /opt/Xilinx/Vivado/2023.2/data/parts/xilinx/zynq/public/bsdl/xc7z010_clg400.bsd xc7z010_clg400.json
python3 xvcjtag.py xc7z010_clg400.json 200 base.txt          # 200 回取り込み
python3 bs_analyze.py xc7z010_clg400.json base.txt           # ピンごとの統計
./run_stim.sh spi 1500 0.004 'for i in $(seq 400); do cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain; done'
python3 bs_analyze.py xc7z010_clg400.json spi.txt base.txt   # 差分列で反応したピンを見る
```

定数サンプルのファイル（I=Q=(1<<k)<<4 を 4096 サンプル、int16 LE 交互）は Python で作って scp し、
Pluto 側で `iio_writedev -c -b 4096 cf-ad9361-dds-core-lpc < /tmp/bitK.bin &` → `sleep 4` → `kill`
（busybox に `timeout` は無い）。

## 落とし穴

- `jtag targets` の順と IDCODE の読み出し順は逆。リセット直後の DR を流すと先に出るのが TDO 側
  （xc7z010）。BSDL のセル 0 も TDO 側で最初に出る。
- hw_server が XVC を掴んだままだと自前クライアントは繋がらない（`pkill -x hw_server`）。
- 取り込みの瞬間は非同期なので、クロックとフレームのように同周期・同位相の信号は統計では区別できない。
  何かを一時的に止める（R1_MODE）か、全 1 / 全 0 データでデータ線を静止させる。
- DDR 1R1T CMOS では tx_frame も rx_frame もクロックと同じ周期（50% デューティ）。
- PL コアのレジスタは `direct_reg_access` に 0x80000000 を足したアドレスで触る（cf_axi_adc / cf_axi_dds 共通）。
- 2 ms/回の取り込みでも SPI バースト（数 µs）はまれにしか捕まらない。1500 回で 50〜100 回。
