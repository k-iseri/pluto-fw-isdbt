# pluto-fw-isdbt

PlutoSDR 互換機を ISDB-T / ISDB-C 受信用チューナーとして使うためのカスタムファームウェア。
ホスト側の [BonDriver_PlutoSDR](https://github.com/k-iseri/BonDriver_PlutoSDR)（TVTest / EDCB 用）と対で使う。
純正ファームのままでも BonDriver は動くが、本ファームを入れると:

- **I/Q を 8bit で転送**し、USB 2.0 で公称レート 8.127 MSPS をそのまま取り込める（純正 16bit は帯域が
  足りず 7/8 レートに落として運用している）。帯域余裕は約 2 倍。受信品質（MER）は 16bit と同等
  （+6 dB のデジタル前置ゲインで 8bit 量子化雑音を抑えている）
- **サンプル落ちを FPGA で数える**（捨てられたサンプル数と回数）。BonDriver のログ統計 `hw_dropped` に出る

## 対象基板（重要）

| 基板 | 対応 |
|---|---|
| **HamGeek PlutoSDR Nano**（XC7Z010-CLG400 + AD9363、USB-C ×2、"PlutoSDR Nano" 表記の小型クローン） | **対応**。ピン配置を JTAG バウンダリスキャンで実測した（[docs/pinout-nano.md](docs/pinout-nano.md)） |
| 本家 ADALM-PLUTO（XC7Z010-CLG225） | **非対応**（ピン配置が全く違う）。同じ改造を公式設計に適用すればビルドできるが未検証 |
| Pluto+ / LibreSDR（XC7Z020） | 非対応（未着手） |

誤って他の基板に書いても起動はするが SDR が動かなくなる。その場合はその基板の純正 `pluto.frm` を書き戻す。

## インストール

必要なもの: BonDriver_PlutoSDR **v1.2.0 以降**（古い DLL は 8bit の申告を受け付けない）。v2.0.0 の FPGA 前段
（同期・FFT・等化。PC 側の復調負荷が約 2.7 コア → 1.1 コア）を使うには **v1.3.0 以降**（それ以前の DLL でも 8bit 転送として動く）。

1. [Releases](https://github.com/k-iseri/pluto-fw-isdbt/releases) から `pluto-fw-isdbt-<版>-nano-8bit.frm` を取る
2. **現在のファームを控える**（下記「戻し方」参照。Nano の純正ファームはメーカーが公開していない）
3. ファイル名を `pluto.frm` に変えて、Pluto のマスストレージ（Windows では「PlutoSDR」ドライブ）にコピーし、
   ドライブを**取り出し（Eject）**する。本体の LED が 1〜2 分点滅して書き込み・再起動する
4. `iio_info -u usb:` の `fw_version` が `v0.39-isdbt-...` になっていれば完了。BonDriver はそのまま認識する
   （`[Debug] Log=1` のログに `sample format int8 (8bit firmware) -> fs 8126984 Hz` と出る）

**`boot.frm` / `boot.dfu` は配布しないし、書いてはいけない。** 本ファームは `pluto.frm`（カーネル・rootfs・FPGA）だけを
置き換え、ベンダーのブートローダ（FSBL / U-Boot）には触らない。ブートローダを壊すと JTAG でしか復旧できない
（[docs/jtag-recovery.md](docs/jtag-recovery.md)）。

## 戻し方

- 同梱の `pluto-fw-isdbt-<版>-nano-16bit.frm` は、同じ基板向けに公式 ADI 設計（16bit I/Q）を実測ピン配置で
  ビルドしたもの。純正相当の動作に戻したいときはこれを `pluto.frm` として書く
- メーカー出荷時のファームに戻したい場合は、書き込む前に自分で控えておく必要がある
  （ssh で `root@192.168.2.1`、パスワード `analog`、`cat /dev/mtd3 > /tmp/linux.bin` を scp で回収 など）。
  本家の `pluto.frm` は Nano では SDR が動かない

## 互換性

| ファーム | BonDriver v1.1.x 以前 | BonDriver v1.2.0 以降 |
|---|---|---|
| 純正（16bit） | 従来どおり | 従来どおり（7/8 レート） |
| pluto-fw-isdbt v1.0.0（8bit） | **不可**（サンプルサイズ 2 を拒否） | 公称レート + `hw_dropped` |
| pluto-fw-isdbt v2.0.0（8bit + FPGA 前段） | **不可** | v1.2.x: v1.0.0 と同じ動作。**v1.3.0 以降: FPGA 前段を自動で使用**（CPU 2.7 → 1.1 コア） |

ホストはファーム識別子ではなく scan-element の申告（`le:s8/8`）で動作を決める。
FPGA 側の識別・統計レジスタ（MAGIC "ISDB"、`0x3000`）の内容は [rtl/isdbt_regs.v](rtl/isdbt_regs.v) の先頭（v2。VERSION / CAPS で判別）。

## 中身

```
pluto-fw-isdbt/
├── plutosdr-fw/        submodule: analogdevicesinc/plutosdr-fw のフォーク（ブランチ isdbt、v0.39 起点）
│    ├── hdl/           フォーク: projects/pluto_nano（公式 pluto + 実測 XDC）、axi_ad9361 のデータ型申告とカウンタ
│    ├── linux/         フォーク: cf_axi_adc がコアの申告するサンプル幅を読む（28 行、GPL-2.0）
│    └── buildroot, u-boot-xlnx: 無改変
├── rtl/                自作 HDL（MIT）: pack8.v（12→8bit 丸め+飽和）、isdbt_sample_counter.v
├── hdl/plutosdr-nano/  実測ピン配置の XDC とピン表
├── overlay/            rootfs に重ねるファイル（S22fpga: PL 再ロードの退路）
├── scripts/            bscan/（バウンダリスキャン）、bit2bin.py、br-post-build.sh
└── docs/               design-v1.md（設計と実測結果）、pinout-nano.md、sdr-revival.md（ビルド手順）、jtag-recovery.md
```

ビルド手順は [docs/sdr-revival.md](docs/sdr-revival.md)（WSL2 + Vivado 2023.2）。

## ロードマップ

| 版 | 内容 | 状態 |
|---|---|---|
| v1.0 | 8bit 転送 + サンプルカウンタ（Nano） | **リリース**（2026-10-14。30 分連続受信でハードドロップ 0） |
| v2.0 | 地デジ前段の FPGA 化（GI 相関同期・8192 点 FFT・SP 等化、等化済みキャリアを 8bit で出力。[docs/design-v2.md](docs/design-v2.md)） | **リリース**（2026-10-15。ch 24 で MER A 26 / B 23 dB、BonDriver v1.3.0 の CPU 2.7 → 1.1 コア。v2.0.1 で窓開始番号を 64bit に） |
| v1.x | 本家 Pluto / Pluto+ 向けビルド（検証者募集）、RX 専用化（必要なら） | 未着手 |
| v3 | 後段（デインターリーブ・ビタビ・RS）の FPGA 化（TS 直接出力）。Zynq-7020 機が本来の土俵 | 検討のみ |

## ライセンス

このリポジトリのオリジナル部分（`rtl/`、`scripts/`、`overlay/`、ドキュメント）は **MIT**。
配布するファームウェアイメージには Linux カーネル（GPL-2.0、本プロジェクトのパッチ込み）、U-Boot、
Buildroot のユーザランド、ADI の HDL（ADI BSD / GPL-2.0 デュアル）が含まれる。対応ソースは
各フォーク（[plutosdr-fw](https://github.com/k-iseri/plutosdr-fw) / [hdl](https://github.com/k-iseri/hdl) /
[linux](https://github.com/k-iseri/linux)、ブランチ `isdbt`）とこのリポジトリのタグで再現できる。
詳細は [NOTICE.md](NOTICE.md)。Analog Devices とは無関係の非公式プロジェクト。
