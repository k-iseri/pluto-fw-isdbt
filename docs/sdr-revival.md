# SDR 再稼働の構成（2026-10-13 時点の暫定運用）

ブートローダはベンダー品のまま（不可侵）、itb は **公式ビットストリーム**（ベンダー u-boot が受理する）で起動し、
**Linux 起動後に S22fpga がボード固有の PL イメージを fpga_manager でロードし直す**構成。
これで AD9361 が probe され、ISDB-T 受信（MER 18.5 dB / 17 Mbps / bad 0、物理 24ch）まで動作確認済み。

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
| `overlay/lib/firmware/pluto-pl.bin` | ボード固有 PL イメージ（現状 tezuka nano の bit を byte-swap .bin 化） | **GPL-3 成果物。リポジトリに含めない**（.gitignore） |
| `buildroot/board/pluto/post-build.sh` のフック | `PLUTO_EXTRA_OVERLAY` を rootfs に重ねる | `patches/buildroot-post-build-overlay.patch`（buildroot は未フォーク） |
| itb | **必ず Makefile（scripts/pluto.its、config@0〜@10）で生成** | — |

## ビルド

```
cd plutosdr-fw
env -i HOME=$HOME PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  PLUTO_EXTRA_OVERLAY=/path/to/pluto-fw-isdbt/overlay SKIP_LEGAL=1 \
  make VIVADO_SETTINGS=/nonexistent build/pluto.frm build/pluto.dfu
```
- `VIVADO_SETTINGS=/nonexistent`: Vivado 導入後は Makefile が xsct（Vitis）を要求する経路に入るため、
  公式 XSA の bit を使う経路を強制する
- `SKIP_LEGAL=1`: legal-info（全ソース取得）を省略
- `env -i`: WSL が継承する Windows PATH（空白入り）を buildroot が拒否するため

## .bin の作り方（.bit → byte-swapped .bin）

zynq-fpga ドライバは .bit ヘッダ無し・32bit 単位でバイトスワップされた .bin を要求する
（sync word 0xAA995566 が先頭 128 バイト内に 66 55 99 AA として現れる）。
`.bit` のヘッダ（a/b/c/d/e セクション）を剥がし、4 バイトごとに反転する（recovery 内の変換スクリプト参照）。

## 判明した落とし穴（時系列）

1. 手組みの its（config@0 のみ）はベンダー u-boot に拒否される（adi_hwref が config@N を選ぶ）
2. PL 再ロード後、起動時に probe 済みの dma-axi-dmac は IP リセットを知らない → DMA が dequeue timeout
3. iiod は起動時に IIO デバイスを列挙する → cf-ad9361-lpc の出現を待ってから S23udc へ
4. `S23udc restart` や iiod の kill は USB 複合ガジェット全体を落とす（戻らないことがある）
5. 同期失敗（windows_failed）は「信号なし」でも出る → **受信テスト前にアンテナ接続を確認**
6. Pico の JTAG 配線経由で寄生給電される → 電源断は Pico の USB も抜く

## 今後（v1 自作ファームへ）

- 自作 HDL には依然ボードの XDC（ピン配置）が必要。tezuka nano の PL が動くことは確認できたので、
  ピン配置は存在する（F5OEO / HamGeek に提供依頼、または動作中 PL に対するバウンダリスキャンで実測）
- 得られ次第: 公式 pluto プロジェクト + ボード XDC + v1 変更（RX 専用・8bit パッキング・サンプルカウンタ）を
  Vivado 2023.2 でビルドし、`pluto-pl.bin` を自作ビットストリームに差し替える（S22fpga の仕組みはそのまま使える）
