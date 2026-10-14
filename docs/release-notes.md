# リリースノート

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
