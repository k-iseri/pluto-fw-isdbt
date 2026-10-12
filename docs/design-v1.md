# v1 設計メモ — RX 専用 + 8bit 転送 + ドロップ検出カウンタ

2026-10-12 起草。対象ボード: PlutoSDR nano 互換機（HamGeek、Zynq-7010 XC7Z010CLG400 +
AD9363、USB 2.0、実機は純正 fw v0.39 で稼働中）。

## 1. 目的

ISDB-T フルセグ受信（ホスト側: BonDriver_PlutoSDR / isdbtd）の USB 2.0 帯域問題を
ファームウェア側で解決する。

- 現状: 16bit I/Q × 公称 512/63 MHz（32.5 MB/s）は USB 2.0 実効スループット
  （実測 ~31.3 MB/s）に 3〜4% 足りず、**公称の 7/8 レート（7,111,111 Hz、28.4 MB/s）に
  落として運用**している（ホスト側リポジトリ docs/decisions.md 2026-10-10 の項）。
  動いてはいるが帯域余裕が ~9% しかなく、USB バスの競合や瞬間的な負荷に弱い。
- v1 のゴール: **8bit 転送で公称レート受信（16.3 MB/s、余裕 ~48%）**、
  サンプル落ちの**ハード確定検出**、不要な TX 経路の削除。

### スコープ外（v2 以降 / やらないこと）

- 復調処理のオフロード（FFT・等化・ビタビ等）。中間段はデータ量が減らず
  USB 問題に効かないため、やるなら TS 直接出力まで一気にやる（7020 機が前提）。
- DDC・レート変換（AD9361 内蔵 FIR で足りている）。
- TX 機能全般（ホスト側変調器はソフトウェアループバック専用。実送信はしない）。
- ISDB-C 対応はホスト側ソフトの課題であり、本ファームの関知外（8bit/RX 専用は
  そのまま ISDB-C 受信にも使える）。

## 2. ベースラインと確認済み事実

| 項目 | 内容 | 根拠 |
|---|---|---|
| ベース | plutosdr-fw **v0.39**（実機の現行 fw と同版。commit 9e90bce） | GitHub release ページ |
| ツール | **Vivado 2023.2**、Linux kernel 6.1 系（ADI ブランチ）、libiio v0.26（デバイス側） | v0.39 release notes |
| v0.39 の submodule ピン | hdl `065c8f18` / linux `f3da30df` / buildroot `e783aadc` / u-boot-xlnx `90401ce9`。**linux ピンは実機カーネル文字列 `6.1.0-...-gf3da30df6004` と一致**（実機は素の v0.39 と確定） | GitHub API + 実機 iio context（2026-10-12） |
| scan_type の出所 | cf-ad9361-lpc（cf_axi_adc ドライバ）の物理チャネルの scan_type（realbits/storagebits/shift）は **devicetree ではなくコンバータドライバの chip_info** から来る（`axiadc_channel_setup()` が `conv->chip_info->channel` をコピー）。AD9361 の場合の定義場所は `ad9361_conv.c` の channel マクロ | analogdevicesinc/linux `drivers/iio/adc/cf_axi_adc_core.c` を確認（2026-10-12） |
| 実行時 datatype 機構 | 同ドライバの user_logic チャネルは `ADI_REG_CHAN_USR_CNTRL_1` レジスタから sign/realbits/storagebits/shift を**実行時に読む**仕組みがある | 同上 |
| レジスタ直読み | cf_axi_adc は `debugfs_reg_access` を実装済み。`DEBUGFS_DRA_PCORE_REG_MAGIC` 付きアドレスで AXI コアレジスタを直接読み書きできる → libiio の `iio_device_reg_read()` が使える見込み | 同上 |
| util_cpack2 | `SAMPLE_DATA_WIDTH` パラメータあり（既定 16）。8 の指定は構文上可能 | analogdevicesinc/hdl `library/util_pack/util_cpack2/util_cpack2.v` を確認（2026-10-12） |
| 8bit 量子化の受信品質 | ホスト側 ref/ の ci8（8bit I/Q）end-to-end ループバックテストは通過済み。実波 8bit 録音の復調実績もあり | isdbt-sdr のテストと録音（2026-10-10） |

### VERIFY の結果（2026-10-12 調査。残件は状態列が「残」のもの）

| # | 項目 | 状態 | 結果 / 残作業 |
|---|---|---|---|
| V1 | pluto BD の RX データパス | **確認済み（v0.39 ピン hdl `065c8f18` で照合）** | `axi_ad9361 → (I0/Q0 は rx_fir_decimator 経由) → util_cpack2（4ch、幅パラメータは BD 未指定=既定16）→ axi_dmac（DMA_DATA_WIDTH_SRC=64、HP1）`。axi_ad9361 は 0x79020000（次の割当は 0x7C400000 なので後方は空き）。**`cpack/fifo_wr_overflow → axi_ad9361/adc_dovf` の接続が既にあり**、overflow はコアに報告されている（→ V8）。TX は `dac_dma(CYCLIC, HP2) → tx_upack → tx_fir_interpolator(x8) → axi_ad9361/dac_data` + **axi_tdd_0（v0.39 で追加）**。TDD は tdd_channel_1 が ADC DMA の sync も駆動しているので、削除時は sync の後始末が要る。残: axi_ad9361 の interconnect 割当幅（Vivado アドレスエディタで確認） |
| V2 | util_cpack2 の 8bit | **ほぼ確認** | `util_cpack2_impl` は全幅が SAMPLE_DATA_WIDTH から導出され 16 決め打ちなし（keep も 8 の倍数条件を満たす）。残: 下位の `pack_shell` / `ad_perfect_shuffle` の確認とシミュレーション |
| V3 | usb: 経由のレジスタ直読み | **実機確認済み** | 純正 fw v0.39 + libiio v1 Python で `cf-ad9361-lpc` に debug 属性 `direct_reg_access` あり。`reg_read(0x80000000\|offset)` で PCORE レジスタが読めた（0x0000 → 0x000A0300 = axi_ad9361 v10.3。MAGIC なしは AD9361 SPI 側へフォワードされるのも確認） |
| V4 | 追加 context attribute 機構 | 残 | V3 が通ったので優先度低（識別はカウンタブロックのマジックレジスタで足りる）。フォーク後に rootfs を見る |
| V5 | scan_type の定義箇所 | **確認済み（v0.39 ピン linux `f3da30df` で照合）** | `ad9361_conv.c` の `axiadc_chip_info_tbl`、`AIM_CHAN(_, _, 12, 'S')`。**マクロが storagebits=16 / shift=0 をハードコード**、実行時変更の機構は無し。**プロファイル選択は `ad9361_uses_rx2tx2(phy) ? ID_AD9361 : ID_AD9364` で、1R1T の Pluto は ID_AD9364（2ch）が選ばれる**（dtsi のラベルも cf_ad9364_adc_core_0）。パッチは storagebits を引数化したマクロ変種を足して **ID_AD9364（+保険で ID_AD9361）** を 8/8 化 |
| V6 | TX 削除の安全性 | **一部確認** | devicetree 確認: `cf-ad9361-lpc` reg = 0x79020000 **size 0x6000**、`cf-ad9361-dds-core-lpc` reg = **0x79024000 size 0x1000（lpc と同一 AXI 窓の内側！）**= DAC レジスタは独立コアではなく axi_ad9361 コア内蔵（+0x4000）。よって BD から消すのは tx_upack / dac_dma / tx_fir_interpolator で、axi_ad9361 の DAC レジスタ自体は残る → phy 初期化が壊れるリスクは当初想定より低い。残: dts から dds ノードを外した起動確認（検証計画 段階 1） |
| V7 | クローン機の個体差 | 残 | 段階 0（無改修リビルドの起動確認）で検出 |
| V8 | axi_ad9361 の overflow ステータス | **実機で大部分確認** | regmap: **UI_STATUS = バイト 0x0088、bit2 = UI_OVF（RW1C）**（adi_regmap_adc、v0.39 ピン hdl で確認）。実機（純正 fw、アイドル中）で read/write とも成功: UI_OVF は常時 1（取り込み停止中は消費者がいないので overflow し続ける = 正常）、W1C 直後も再セットされる。SCRATCH（バイト 0x0008）で write 経路の健全性も確認済み。**運用設計: ストリーム開始後にクリアし、取り込み中に定期読み。取り込み中に立つ = ドロップ発生**。残: 実ストリーミング中の挙動確認（健全時に立たないこと。検証計画 段階 0 に追加）。成立すればカスタム RTL は 64bit サンプルカウンタのみに縮む |

注: V1/V2/V5/V6 のソース確認は上流 **main ブランチ**で行った（2026-10-12）。フォーク作成時に
v0.39 がピンするコミットで差分がないか再確認する。

## 3. 改修内容

### 3.1 RX 専用化（TX 削除）

- BD から TX 側の axi_dmac・util_upack2・DAC インターフェース（axi_ad9361 の
  TX データポートは未接続化 or コア設定で無効化）を除去。
- devicetree から `cf-ad9361-dds-core-lpc` ノードを削除（V6）。
- ad9361-phy はそのまま（RX LO・ゲイン・レート設定はすべて phy 管轄）。
- 期待効果: BRAM / LUT / DSP の空きとタイミング余裕。v1 では空いた資源は使わない
  （将来の v2 とサンプルカウンタのための余地）。

### 3.2 8bit パッキング

**データフロー**: axi_ad9361 の RX 出力（I/Q 各 16bit コンテナ、実 12bit。I0/Q0 は
rx_fir_decimator 経由 — V1 確認済み）を新規モジュール `rtl/pack8.v`（MIT）で 8bit へ
量子化し、cpack（`SAMPLE_DATA_WIDTH=8` に変更）→ DMA に渡す。pack8 の挿入点は
decimator 出力/axi_ad9361 出力と cpack の 4 入力レーンの間。

- 量子化: 12bit [11:0] → 8bit。**算術右シフト 4 + 丸め（round-half-away-from-zero）+
  飽和**。単純切り捨てより ~0.5 LSB のバイアスを避ける。
- ヘッドルーム: 8bit の SQNR はフルスケールで ~50 dB。slow_attack AGC の
  バックオフ（~10 dB）を引いても ~38 dB で、64QAM 3/4 の所要 C/N（~20 dB）+
  実運用マージンに対して十分（ci8 end-to-end テスト通過の実績と整合）。
- 実装の選択肢（V1/V2 の結果で確定）:
  - 案 a: cpack の `SAMPLE_DATA_WIDTH=8` にし、pack8 は 16→8 の変換だけ行う（素直）。
  - 案 b: cpack は 16bit のまま、pack8 が 2 サンプルを 16bit レーンに詰める（cpack 改変不要だが
    チャネル境界の扱いが歪む。案 a が通らないときの代替）。
- **v1 は常時 8bit 固定**（16/8 切替レジスタは作らない）。切替が欲しい場面は
  「純正 fw に書き戻す」で足りる。ファームの複雑さとホスト側の分岐を増やさない。

**カーネル側の申告（ホスト自動適応の要）**:

- `ad9361_conv.c` の `AIM_CHAN` マクロは storagebits=16 をハードコード（V5 確認済み）。
  storagebits を引数化したマクロ変種を追加し、`axiadc_chip_info_tbl` の
  **ID_AD9364（1R1T の Pluto で実際に選ばれるプロファイル）と ID_AD9361** を
  realbits=8 / storagebits=8 / shift=0 にするパッチ（GPL-2.0）。
  → iiod / libiio の `iio_device_get_sample_size()` が 2ch 有効時に **2 バイト**を返し、
  ホストは申告ベースで自動適応できる。
- 方式 B（将来）: user_logic チャネルと同様に `ADI_REG_CHAN_USR_CNTRL_1` 相当から
  実行時取得にすれば「FPGA が正、カーネルは読むだけ」になり devicetree 分岐も消える。
  v1 では見送り（パッチが大きくなる）。V5 の確認時に工数を再評価。

**ホスト側（isdbt-sdr リポジトリ）の対応タスク**（本リポジトリの範囲外、連動して実施）:

- `rt/demod/sdr_source.cpp` の `ss != 4` チェックを「4 = s16 経路 / 2 = s8 経路」に拡張。
  s8 のスケールは 1/128（12bit [11:4] 相当なので、現行 s16 の 1/2048 と信号振幅が一致）。
- `tools/iq_record.py` も同様に申告ベースで ci8 録音に対応（SigMF は ci8 対応済み）。
- 既定 fs を接続先の申告で切り替え: 8bit 申告なら公称 8,126,984 Hz、16bit なら従来の 7/8。

### 3.3 ドロップ検出カウンタ

- overflow の検出自体は**コア既存の UI_STATUS（バイト 0x0088、bit2 UI_OVF、RW1C）で
  足りる見込み**（V8 実機確認済み。アイドル中は常時 1 が正常で、ストリーム開始後に
  クリアして取り込み中に監視する運用）。純正ファームでも使えるので、ホスト側は
  先行して UI_OVF 監視を実装できる。
- `rtl/sample_counter.v`（MIT）: ドロップの**定量化**（何サンプル欠けたか）のために、
  ADC サンプルクロックで動く **64bit フリーランニングサンプルカウンタ**を
  AXI-Lite の小さな独立レジスタブロックとして追加（overflow ラッチは UI_OVF があるので
  v1 では持たない）。
  独立ブロックにする理由: 上流（axi_ad9361 コア）への改変を避け、MIT のまま置けて、
  レジスタマップの衝突もない。
- レジスタマップ（案）:

  | offset | 内容 |
  |---|---|
  | 0x00 | マジック `0x49534442`("ISDB")— 本ファーム識別を兼ねる |
  | 0x04 | 版（v1 = 1） |
  | 0x08 / 0x0C | サンプルカウンタ下位 / 上位（読み出しは下位アクセスで上位をラッチ） |
  | 0x10 | overflow イベント数 |

- 読み出し経路（V3 実機確認を踏まえた設計）: cf_axi_adc の debugfs_reg_access は
  「devicetree の reg 窓を ioremap した領域 + (reg & 0xFFFF)」を読むので、
  **カウンタブロックを cf-ad9361-lpc の 64KB 以内の空きオフセットに置き、
  dts の reg サイズを広げれば、カーネル改変ゼロ（dts のみ）で `iio_device_reg_read()`
  から読める**。現状の窓は 0x79020000 size 0x6000 で、+0x4000〜0x4FFF は
  axi_ad9361 内蔵の DAC レジスタ（V6 確認）。カウンタブロックは interconnect の
  割当粒度を見て +0x8000（axi_ad9361 の割当 range が 0x8000 以下の場合）等に置き、
  dts reg を size 0x9000 以上へ拡張する。割当 range が 64KB 固定で同居不能なら、
  代替として専用の小さな platform driver + sysfs 属性（GPL-2.0 パッチ増）に切替。
  ホストは `iio_device_reg_read()` を BonDriver の status 取得周期（10 s）に同期して
  読み、受信済みサンプル総数との差分 = 確定ドロップ数として `rx_dropped_hw` を
  status JSON に追加。
- これが入ると、ホスト側 RateMonitor（実測レートによる推測検出）は「ハード検出の
  クロスチェック」に役割が変わる（削除はしない。純正 fw でも動く検出として残す）。

### 3.4 ファーム識別

- 第一手段: サンプルカウンタブロックのマジックレジスタ（3.3）。
- 補助: iiod の追加 context attribute（V4）が使えるなら `local,isdbt-fw = <版>` を追加。
  使えなければ見送り（必須ではない）。
- ホストはあくまで **scan-element の申告（サンプルサイズ）で動作を決める**。
  識別子は診断表示用。

## 4. リポジトリ / フォーク構成

1. GitHub に `analogdevicesinc/plutosdr-fw` のフォークを作り、`isdbt` ブランチを
   **タグ v0.39 から**切る。
2. 改変が要るのは `hdl`（BD・rtl 追加）と `linux`（ad9361_conv.c パッチ、devicetree）。
   それぞれフォークして v0.39 が指すコミットから `isdbt` ブランチを切り、
   plutosdr-fw フォークの `.gitmodules` をフォーク先 URL に変更。
   buildroot / u-boot-xlnx は無改変なので上流のまま。
3. 本リポジトリ（pluto-fw-isdbt）に plutosdr-fw フォークを submodule 追加し、
   `rtl/` は本リポジトリに置いて hdl 側からは相対参照（または hdl フォークに
   コピーを置かず Tcl で取り込む。V1 の BD 構造を見て決定）。

ライセンスの帰属（NOTICE.md と同じ）: `rtl/`・scripts・docs = MIT /
linux パッチ = GPL-2.0 / hdl 改変 = ADI デュアル。

## 5. ビルドと書き込み

- ビルドホスト: WSL2（Ubuntu 22.04）+ Vivado 2023.2 Linux 版（7010 は無償の
  Standard エディションで可）。ディスク ~80 GB、初回フルビルド数時間。
- 書き込み: `pluto.frm` を Pluto のマスストレージへコピー → eject で書き込み。
- 復旧手段（必ず先に確認）: 書き込み失敗・起動不能時は **DFU モード**
  （uboot の DFU、またはボタン押し起動）から純正 `pluto.dfu` を書き戻せる。
  v0.39 純正イメージ一式を手元に保存してから着手する。

## 6. 検証計画（段階ゲート。各段階が通るまで次へ進まない）

| 段階 | 内容 | 合格基準 |
|---|---|---|
| 0 | ~~V3 の事前確認~~（済: reg read/write とも usb: で動作確認）+ **UI_OVF のストリーミング中挙動確認**（健全時 0・飽和時 1。純正 fw で可能）+ 無改修の v0.39 を自前フルビルドして実機起動 | iio_info / 受信が純正配布版と同等、UI_OVF がドロップ指標として使える |
| 1 | RX 専用化のみ | 従来ホスト（16bit、7/8 レート）で TVTest 視聴が無劣化 |
| 2 | + サンプルカウンタ | reg_read でカウンタ読み出し、1 時間で (カウンタ増分) = (受信サンプル数) ± 0 |
| 3 | + 8bit パッキング（ホスト側 s8 対応と同時） | 公称 8.127 MSPS で rx_slow=0・ハードドロップ 0・TVTest 視聴、MER が 16bit 比 −0.5 dB 以内 |
| 4 | 長時間安定性 | 24 時間連続受信でドロップカウンタ 0、再接続 0 |

ホスト側の回帰: isdbt-sdr の `make test` / rt_test は従来どおり全通過を維持
（s8 経路の単体テストを sdr_source 側に追加）。

## 7. リスクと未決

- V2（cpack の 8bit）が NG の場合: 案 b（16bit レーンに 2 サンプル詰め）へ切替。
  DMA 以降は不透明なバイト列なので影響はカーネル申告の storagebits だけ。
- クローン機の個体差（V7）: 段階 0 で検出する。純正 fw が動いている以上リスクは低い。
- Vivado 2023.2 のタイミングクロージャ: RX 専用化で制約は軽くなる方向。
- 7010 の資源: v1 の追加分（pack8 + counter）は数百 LUT 規模で問題なし。
