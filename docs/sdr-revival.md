# SDR 再稼働の構成（2026-10-13 暫定 → 2026-10-14 自前 PL に置換）

ブートローダはベンダー品のまま（不可侵）、itb は **公式ビットストリーム**（ベンダー u-boot が受理する）で起動し、
**Linux 起動後に S22fpga がボード固有の PL イメージを fpga_manager でロードし直す**構成。
これで AD9361 が probe され、ISDB-T 受信（MER 18.5 dB / 17 Mbps / bad 0、物理 24ch）まで動作確認済み。

2026-10-14 からは PL イメージが tezuka の借り物ではなく **自前ビルド**（hdl フォーク `projects/pluto_nano` =
公式 ADI 設計 + [バウンダリスキャンで実測したピン配置](pinout-nano.md)）になり、MER 25 dB / 17 Mbps / bad 0。
フラッシュ済みイメージは `recovery/pluto-v0.39-S22fpga-nano-r1.frm`（ビルド r1）。

```
BootROM → vendor FSBL → vendor u-boot ──(公式 bit を PL へ)──→ Linux
   Linux: S21misc → S22fpga ─┬─ fpga_manager で /lib/firmware/pluto-pl.bin をロード
                             ├─ dma-axi-dmac / cf_axi_adc / cf_axi_dds を unbind→bind（IP リセット後の再初期化）
                             ├─ ad9361 (spi0.0) を bind、cf-ad9361-lpc の出現を待つ
                             └─→ S23udc が iiod を起動（この時点で IIO デバイスが揃っている）
```

## 構成要素

| 要素 | 内容 | ライセンス / 配布 |
|---|---|---|
| `overlay/etc/init.d/S22fpga` | PL 再ロード + ドライバ再バインド | MIT（本リポジトリ） |
| `overlay/lib/firmware/pluto-pl.bin` | ボード固有 PL イメージ。2026-10-14 からは hdl フォーク `projects/pluto_nano` の自前ビルド（`scripts/bit2bin.py` で .bin 化）。それ以前は tezuka nano の bit（GPL-3） | ビルド成果物なのでリポジトリに含めない（.gitignore）。`recovery/pluto-pl-nano-r1.bin` に保管 |
| `scripts/br-post-build.sh` | `PLUTO_EXTRA_OVERLAY` を rootfs に重ねる（plutosdr-fw フォークの Makefile が `PLUTO_EXTRA_POST_BUILD` で buildroot に渡す） | MIT（本リポジトリ）。buildroot は未フォークのまま無改変 |
| itb | **必ず Makefile（scripts/pluto.its、config@0〜@10）で生成** | — |

## ビルド

```
cd plutosdr-fw
R=/path/to/pluto-fw-isdbt
rm -f build/system_top.xsa build/system_top.bit     # XSA を差し替えるとき
env -i HOME=$HOME PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  PLUTO_EXTRA_OVERLAY=$R/overlay PLUTO_EXTRA_POST_BUILD=$R/scripts/br-post-build.sh SKIP_LEGAL=1 \
  make VIVADO_SETTINGS=/nonexistent XSA_FILE=hdl/projects/pluto_nano/pluto_nano.sdk/system_top.xsa \
       build/pluto.frm build/pluto.dfu
```
- `XSA_FILE=...`: 自前ビルドの XSA を使う（2026-10-14 の r3b 以降）。itb に自前の bit が入り、ベンダー u-boot が
  起動時にロードするので **Linux での PL 再ロード（S22fpga）は不要**になった。S22fpga は overlay に
  `lib/firmware/pluto-pl.bin` があるときだけ動く退路として残してあり、AD9361 が probe 済みなら何もしない
- `VIVADO_SETTINGS=/nonexistent`: Vivado 導入後は Makefile が xsct（Vitis）を要求する経路に入るため、
  XSA の bit をそのまま使う経路を強制する（XSA_FILE 未指定なら公式リリースの XSA をダウンロード）
- `PLUTO_EXTRA_POST_BUILD`: plutosdr-fw フォークの Makefile が buildroot の post-build スクリプトに連結する
  （buildroot 本体は改変しない。以前の `patches/buildroot-post-build-overlay.patch` は廃止）
- `SKIP_LEGAL=1`: legal-info（全ソース取得）を省略
- `env -i`: WSL が継承する Windows PATH（空白入り）を buildroot が拒否するため
- `buildroot/output/target` は前回の内容が残るので、overlay からファイルを消したときは target 側も消す

## .bin の作り方（.bit → byte-swapped .bin）

zynq-fpga ドライバは .bit ヘッダ無し・32bit 単位でバイトスワップされた .bin を要求する
（sync word 0xAA995566 が先頭 128 バイト内に 66 55 99 AA として現れる）。
`.bit` のヘッダ（a/b/c/d/e セクション）を剥がし、4 バイトごとに反転する: `scripts/bit2bin.py in.bit out.bin`。

## 自前 PL のビルドと書き込み（2026-10-14）

```
# WSL。hdl フォーク（ブランチ isdbt）の projects/pluto_nano を Vivado 2023.2 でビルド（約 20 分）
cd plutosdr-fw/hdl/projects/pluto_nano
env -i HOME=$HOME PATH=/opt/Xilinx/Vivado/2023.2/bin:/usr/bin:/bin XILINX_VIVADO=/opt/Xilinx/Vivado/2023.2 make
unzip -o pluto_nano.sdk/system_top.xsa system_top.bit -d /tmp/nano
python3 scripts/bit2bin.py /tmp/nano/system_top.bit overlay/lib/firmware/pluto-pl.bin
# 上の「ビルド」の make で pluto.frm を作る（itb の bit は公式のまま。S22fpga が自前 PL に差し替える）
```
書き込みは DFU を使わなくても、Windows で PlutoSDR のマスストレージ（F: など）に `pluto.frm` をコピーして
**取り出し（Eject）**すれば本体が自分でフラッシュして再起動する（LED 点滅 1〜2 分）。

ビルド時に踏んだ点:
- 公式 pluto は PS7 の自動生成 XDC（`system_sys_ps7_0.xdc`）を無効化して自前の clg225 用制約を書いているが、
  clg400 では自動生成をそのまま使う（PS 専用ピンに PACKAGE_PIN は不要。「pin に iostandard を設定できない」
  CRITICAL WARNING が大量に出るが無害）
- `axi_iic` を BD の `iic_rtl` インターフェースのまま外に出すと wrapper が IOBUF を生成し、ピン未割当で
  placer が `IO Clock Placer failed` で落ちる。BD 側で scl/sda の i/o/t を個別ポートにし、トップで入力を 1 に固定する
- 同定できなかったポート（clk_out, gpio_en_agc, gpio_ctl, gpio_status, pl_gpio0..4）はトップから削除。
  EMIO GPIO の該当ビットは内部でループバック（ad9361 ドライバは RESETB しか実際には使わない）

## 判明した落とし穴（時系列）

1. 手組みの its（config@0 のみ）はベンダー u-boot に拒否される（adi_hwref が config@N を選ぶ）
2. PL 再ロード後、起動時に probe 済みの dma-axi-dmac は IP リセットを知らない → DMA が dequeue timeout
3. iiod は起動時に IIO デバイスを列挙する → cf-ad9361-lpc の出現を待ってから S23udc へ
4. `S23udc restart` や iiod の kill は USB 複合ガジェット全体を落とす（戻らないことがある）
5. 同期失敗（windows_failed）は「信号なし」でも出る → **受信テスト前にアンテナ接続を確認**
6. Pico の JTAG 配線経由で寄生給電される → 電源断は Pico の USB も抜く

## 今後（v1 自作ファームへ）

- ピン配置は実測で解決した（pinout-nano.md）。`projects/pluto_nano` を起点に v1 の変更
  （RX 専用化・8bit パッキング・サンプルカウンタ、design-v1.md）を入れ、同じ経路で `pluto-pl.bin` を差し替える
- 整理候補: itb に自前 bit を直接入れて S22fpga の再ロードを不要にする（plutosdr-fw の Makefile は
  `hdl/projects/$(TARGET)` の XSA から bit を取るので、TARGET=pluto_nano か XSA の差し替えで対応できるはず）
