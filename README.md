# pluto-fw-isdbt

PlutoSDR 互換機（Zynq-7010 + AD9363）を ISDB-T 受信専用チューナーとして使うための
カスタムファームウェア。ホスト側の受信ソフトウェア
[BonDriver_PlutoSDR](https://github.com/k-iseri/BonDriver_PlutoSDR) と対で使う
（純正ファームでも動くが、本ファームで USB 2.0 の帯域余裕と障害検出が改善する）。

**状態: 設計段階。** 設計は [docs/design-v1.md](docs/design-v1.md) を参照。
対象基板（HamGeek PlutoSDR Nano、XC7Z010-**CLG400**）の AD9361 ピン配置は公式 Pluto と全く違うので
JTAG バウンダリスキャンで実測した（[docs/pinout-nano.md](docs/pinout-nano.md)、
XDC は [hdl/plutosdr-nano/system_constr.xdc](hdl/plutosdr-nano/system_constr.xdc)、
スクリプトは [scripts/bscan/](scripts/bscan/)）。

## ロードマップ

| 版 | スコープ | 状態 |
|---|---|---|
| v1 | **RX 専用化 + 8bit サンプル転送 + ドロップ検出カウンタ**（USB 2.0 で公称 8.127 MSPS 受信、帯域余裕 ~2 倍、サンプル落ちのハード確定検出） | 設計中 |
| v2+ | 検討のみ: フル復調の FPGA 化（TS 直接出力）。Zynq-7020 機（Pluto+ / LibreSDR）が本来の土俵 | 未着手 |

## 構成（予定）

```
pluto-fw-isdbt/
├── plutosdr-fw/   ← submodule（analogdevicesinc/plutosdr-fw のフォーク、v0.39 起点）
│    └─ hdl / linux / buildroot / u-boot-xlnx（フォーク。改変は hdl と linux のみ）
├── rtl/           ← 自作 HDL（8bit パッキング、サンプルカウンタ）… MIT
├── scripts/       ← ビルドラッパ
└── docs/          ← 設計メモ
```

## ライセンス

このリポジトリのオリジナル部分（`rtl/`、スクリプト、ドキュメント）は **MIT**。
ビルドされるファームウェアイメージは GPL-2.0（Linux / U-Boot）や
ADI のデュアルライセンス（HDL）のコンポーネントを含む。詳細は [NOTICE.md](NOTICE.md)。
カーネルへのパッチは GPL-2.0（MIT ではない）ことに注意。
