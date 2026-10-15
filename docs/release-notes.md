# リリースノート

## v2.0.1（2026-10-15）

v2.0.0 の修正版。配布物は `pluto-fw-isdbt-v2.0.1-nano-8bit.frm` / `.dfu` / `SHA256SUMS.txt`（内容は v2.0.0 と同じ構成）。

### 変更点

- 出力フレームヘッダの窓開始サンプル番号（w2/w3）を本当に 64bit にした。v2.0.0 は下位 32bit だけで 528 秒ごとに一周し、
  BonDriver v1.3.0 では視聴開始から最長約 9 分で映像が止まっていた（v1.3.1 はホスト側で周回を補正しているので
  v2.0.0 のままでも動く。v2.0.1 ではファーム側でも直り、他のホストから使う場合も周回を気にしなくてよい）。
  `fw_version` は `v0.39-isdbt-2.0.1`。FPGA の資源・タイミングは v2.0.0 と同等（WNS +0.74 ns）
- 必要なホストは v2.0.0 と同じ（BonDriver_PlutoSDR v1.3.0 以降で FPGA 前段、v1.3.1 以降を推奨）

### チェックサム

```
9d3687ad2063b0d0bc39bb01b862d150a1f7b0372c3fcfe696944db02454dd0e  pluto-fw-isdbt-v2.0.1-nano-8bit.frm
591ee364547b39b6a944a7183515c7336a17ebf1553c774cd648b04093a60175  pluto-fw-isdbt-v2.0.1-nano-8bit.dfu
```

### ソース

- このリポジトリ タグ `v2.0.1`
- plutosdr-fw フォーク タグ `v0.39-isdbt-2.0.1`（hdl `5fe9004`、linux `f885cf9`。v2.0.0 から rtl の fe_win だけが変わった）

## v2.0.0（2026-10-15）

HamGeek PlutoSDR Nano（XC7Z010-CLG400 + AD9363）向け。GitHub Release の本文はこの節をそのまま使う。

### 配布物

| ファイル | 内容 |
|---|---|
| `pluto-fw-isdbt-v2.0.0-nano-8bit.frm` | **本命**。v1.0.0 の 8bit 転送 + サンプルカウンタに加えて、地デジの前段（GI 相関同期・8192 点 FFT・SP チャネル推定と等化）を FPGA で行い、等化済みキャリア（I/Q/CSI 各 8bit）を出力する。`pluto.frm` に改名してマスストレージ経由で書く |
| `pluto-fw-isdbt-v2.0.0-nano-8bit.dfu` | 同じ内容の DFU 形式（通常は不要） |
| `SHA256SUMS.txt` | チェックサム |

純正相当（16bit）に戻すときは v1.0.0 の `pluto-fw-isdbt-v1.0.0-nano-16bit.frm` を使う（基板は同じ）。
`boot.frm` は含まない（ベンダーのブートローダをそのまま使う。書き換え禁止）。

### 必要なホスト

BonDriver_PlutoSDR **v1.3.0 以降**で FPGA 前段が使われる（ini の `[SDR] FpgaEq=auto` が既定）。
v1.2.x の DLL でも 8bit 転送のファームとして従来どおり動く（前段は使われない）。v1.1.x 以前は不可。

### 中身

- FPGA（`rtl/`、[docs/design-v2.md](docs/design-v2.md)）: 公式設計から axi_iic / axi_spi / axi_tdd を外して空けた
  資源に、GI 相関同期（`isdbt_gi_corr` / `isdbt_sync`: 捕捉は 2 シンボルの周期性判定、追従は帰還なしの直線時間軸）、
  CFO 回転器、Xilinx FFT 8192（12bit、ブロック浮動小数点）、SP 等化器（`isdbt_eq`: 受信中 SP パス + AFC + CPE +
  線形補間、CSI 付き 8bit 出力、履歴 16 シンボル）、出力フレーマ、ADC レベル計を載せた。
  LUT 約 82 %、BRAM 56/60、DSP 68/80（XC7Z010）
- レジスタ（コア内 0x3000、MAGIC "ISDB"、**VERSION 4、CAPS 0x1F**）: MODE（0 raw / 3 同期 FFT 8bit / 4 等化済み
  キャリア）、EQ_CTRL（整数 CFO δ、AFC / CPE 有効）、SYNC_STATUS / EQ_STATUS / EQ_OMEGA / TIM_EST / TIM_DELTA、
  ADC_LEVEL（モード 3/4 中のホスト AGC 用）。レジスタ表は [rtl/isdbt_regs.v](rtl/isdbt_regs.v) の先頭
- Linux / rootfs は v1.0.0 と同じ（dts から iic / spi / tdd を外した）。`fw_version` は `v0.39-isdbt-2.0.0`
- 出力はモード 4 で 882 シンボル/s × 16.9 KB ≈ 14.9 MB/s（USB 2.0 で余裕あり）

### 実機での結果（Nano、地デジ物理 24ch）

- FPGA 前段 → ホスト後段（BonDriver v1.3.0）で MER A 26 / B 23 dB、RS 訂正不能 0、選局から約 5 秒でロック。
  ホスト全段復調（raw）と同等の受信品質で、PC 側の CPU は 2.7 コア → 1.1 コア
- TVTest で UHF の視聴・チャンネルスキャン、CATV（ISDB-C、こちらは raw のまま）の視聴を確認
- 帯域内 −30 dBFS（AGC 目標を下げた弱信号相当）でもロック（MER 18〜19 dB。raw ホストは 23 dB で、低レベルでの差は未解明）

### 既知の注意点

- v1.0.0 と同じく、AD936x 内蔵の slow_attack AGC は 8bit + 前置ゲインでクリップする。BonDriver は自動でソフト AGC
- モード 3 から 4 へ直接切り替えると時間軸がずれる。BonDriver はモード 0 を挟んで切り替える（他のソフトから
  使う場合は `isdbt-sdr/tools/fe_eq_test.py` の手順に従う）
- 出力フレームヘッダの窓開始サンプル番号（w2/w3）は 64bit 幅だが、**下位 32bit しか入っていない**（fe_win の
  sample_count が 32bit の連結で配線されている）。8.127 MSPS では 528 秒で一周するので、ホストは下位 32bit の周回を数えること
  （BonDriver v1.3.1 以降で対応。v1.3.0 は一周のたびに映像が止まり、選局し直すと復帰する）。次のファームで 64bit にする
- 本家 ADALM-PLUTO（clg225）には書かないこと（SDR が動かなくなる。純正 pluto.frm で戻せる）
- TX 経路は公式設計のまま残っている（動作未確認。本プロジェクトでは使わない）

### チェックサム

```
dd180ed4461a031fd70feb527c2bceb374a98a004b25702207ffb20d2c692cc7  pluto-fw-isdbt-v2.0.0-nano-8bit.frm
3856572bc1f6117b7370d0ebd9f3654ae57b004727e24b13c874cfa152b4bd2d  pluto-fw-isdbt-v2.0.0-nano-8bit.dfu
```

### ソース

- このリポジトリ タグ `v2.0.0`
- plutosdr-fw フォーク タグ `v0.39-isdbt-2.0.0`（`5bc1562`。hdl `5fe9004`（ブランチ isdbt）、linux `f885cf9`、
  buildroot / u-boot は v0.39 のまま）

## v1.0.0（2026-10-14）

HamGeek PlutoSDR Nano（XC7Z010-CLG400 + AD9363）向け。GitHub Release の本文はこの節をそのまま使う。

### 配布物

| ファイル | 内容 |
|---|---|
| `pluto-fw-isdbt-v1.0.0-nano-8bit.frm` | **本命**。8bit I/Q 転送（+6 dB 前置ゲイン）+ サンプルカウンタ。`pluto.frm` に改名してマスストレージ経由で書く |
| `pluto-fw-isdbt-v1.0.0-nano-16bit.frm` | 退路。公式 ADI 設計（16bit）を同じ基板向けにビルドしたもの。純正相当の動作 |
| `*.dfu` | 同じ内容の DFU 形式（`dfu-util -a firmware.dfu -D ...`）。通常は不要 |
| `SHA256SUMS.txt` | チェックサム |

`boot.frm` は含まない（ベンダーのブートローダをそのまま使う。書き換え禁止）。

### 必要なホスト

BonDriver_PlutoSDR **v1.2.0 以降**。古い DLL は 8bit 申告を受け付けない（16bit 版 frm なら動く）。

### 中身

- FPGA: 公式 ADI pluto デザイン + 実測ピン配置（JTAG バウンダリスキャン）+ pack8（12→8bit、丸め・飽和、
  シフト 3）+ util_cpack2 8bit + axi_ad9361 コアのデータ型申告（CHAN_USR_CNTRL_1 = 8/8）+
  サンプルカウンタブロック（コア内 0x3000: MAGIC "ISDB" / VERSION 1 / CNT / OVF_CNT / DROP_CNT / FORMAT）
- Linux: ADI v0.39 系カーネル + cf_axi_adc がコアの申告を読んで scan-element を `le:s8/8` にするパッチ
- その他は plutosdr-fw v0.39 と同じ（libiio 0.26 の iiod、RNDIS、マスストレージ更新）
- `fw_version` は `v0.39-isdbt-1.0.0`

### 実機での結果（Nano、地デジ物理 24ch）

- 公称 8.127 MSPS で MER 24〜26 dB（16bit 版と同等）、30 分連続受信でハードドロップ 0・再接続 0
- 飽和試験（ホストが 20 MSPS を指定）でカウンタの捨てたサンプル数が到着レートとの差分に一致
- 温度: AD936x 36.8 °C、Zynq 約 50 °C（30 分後、室温）

### 既知の注意点

- AD936x 内蔵の slow_attack AGC は 8bit + 前置ゲインでクリップする（約 1%）。BonDriver v1.2.0 は
  8bit 申告時に自動でソフト AGC に切り替える。他のソフトから使う場合は manual ゲインにすること
- 本家 ADALM-PLUTO（clg225）には書かないこと（SDR が動かなくなる。純正 pluto.frm で戻せる）
- TX 経路は公式設計のまま残っている（動作未確認。本プロジェクトでは使わない）

### ソース

- このリポジトリ タグ `v1.0.0`
- plutosdr-fw フォーク タグ `v0.39-isdbt-1.0.0`（hdl `ec69b24`、linux `8a62d50`、buildroot / u-boot は v0.39 のまま）
