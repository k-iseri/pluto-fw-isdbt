# Pluto Nano クローンの JTAG 復旧手順

状況(2026-10-12): tezuka-nano の boot.frm(FSBL + u-boot)を書き込んだところ、
FSBL の DDR 初期化がこの個体と合わずブート最初期でハング(USB 完全沈黙、
基板の DFU ボタンも u-boot 未到達のため効かない)。

## 前提(確保済みの材料)

- `recovery/vendor-boot-backup.bin` — ベンダー FSBL + u-boot の完全バックアップ
  (壊す前に DFU upload で取得。**この個体で確実に動く唯一のブートローダ**)
- `recovery/vendor-boot-parts/` — 上記から `scripts/zynq_bootbin.py` で抽出した
  `fsbl.bin`(load/exec 0x0)と `part1_load04000000.bin`(u-boot、load/exec 0x4000000)
- `plutosdr-fw/build/pluto.dfu`(WSL 側)— 自ビルド v0.39(ベンダー u-boot で起動実績あり)
- 基板の JTAG 穴: `3.3V TMS TCK TDO TDI GND`(シルク順)

## 追加判明事項(2026-10-12)

- 基板裏に **`short JTAG / open QSPI`** のブートモードパッドあり。ショートして電源投入すると
  BootROM が JTAG 待ちで停止する(壊れた FSBL を読まない)→ **復旧時はショート推奨**
- 基板左側に **UART 用 USB コネクタ(CH340、1a86:7523)**あり。usbipd で WSL へ渡すと
  /dev/ttyUSB0(115200)。FSBL(リリースビルド)は無出力なので沈黙 = u-boot 未到達の意味
- OpenOCD + FT232H でも復旧可能(Vivado プローブ不要)。`scripts/ft232h-zynq.cfg` と
  `scripts/recover_nano_openocd.sh` を使う。Ubuntu の openocd 0.11 の zynq_7000.cfg は
  7z010(PL TAP id 0x13722093)対応・ターゲット名 `zynq.cpu0`

## ハードウェア

- 経路 A(FT232H + OpenOCD): `scripts/ft232h-zynq.cfg` の配線表どおり
  (AD0→TCK、AD1→TDI、AD2→TDO、AD3→TMS、GND→GND。**3.3V は繋がない**)
- 経路 B(Vivado 直結プローブ): Platform Cable USB II 互換等を 1:1 で配線
  (VREF→3.3V、GND→GND、TMS/TCK/TDO/TDI はラベルどおり)
- いずれも 1×6 ピンヘッダをはんだ付け(斜め挿しテンションでも短時間なら可)
- ボードは SLAVE 側 USB で給電(「short JTAG」パッドをショートして挿す)

## 手順

1. Vivado(/opt/Xilinx/Vivado/2023.2)インストール済みの WSL で hw_server を使う。
   USB JTAG ケーブルを WSL に渡す: 管理者 PowerShell で
   `usbipd bind --busid <ケーブルの BUSID>` →
   `usbipd attach --wsl --busid <BUSID>`(Platform Cable は 03fd:000d 等)
2. 復旧スクリプト実行:
   ```
   source /opt/Xilinx/Vivado/2023.2/settings64.sh
   xsdb /mnt/c/Users/water/pluto-fw-isdbt/scripts/recover_nano.tcl
   ```
3. 「USB download gadget」(0456:b674)が Windows に出たら、Pluto 本体の USB を
   WSL へ attach して書き戻し:
   ```
   dfu-util -a boot.dfu -D recovery/vendor-boot-backup.bin      # ベンダー boot 復元
   dfu-util -a firmware.dfu -D plutosdr-fw/build/pluto.dfu      # 自ビルド v0.39
   dfu-util -e
   ```
   → 抜き挿しで「起動 + ssh 可(SDR は未復旧)」の管理可能な状態に戻る。

## ルート C: QSPI フラッシュ直接書き込み(JTAG 不要。2026-10-12 追加)

基板表の Winbond **W25Q256**(32MiB)を SOIC テストクリップで挟み、flashrom で
`recovery/qspi-restore.img` を書けばブートローダごと復旧できる(BIOS 復旧と同じ定番手法)。

- イメージ生成: `scripts/make_qspi_restore_img.sh`(生成済み。boot = ベンダーバックアップ、
  env = ベンダーバックアップ、0x200000 = 自ビルド v0.39 itb。**nvmfs(較正値)は
  レイアウトで除外し書かない**)
- プログラマ: FT232H(flashrom `ft2232_spi:type=232H`)または CH341A(`ch341a_spi`)
- 手順: **両方の USB を抜いて完全無電源** → クリップ装着 → まず `-r` で読めることを確認 →
  スクリプト末尾に表示される `-w` コマンドで書き込み → クリップを外して USB 接続
- 注意: flashrom 1.2 でチップが `W25Q256JV` と一意に検出されない場合は
  `-c "W25Q256.V"` を付ける。in-circuit 書き込みはプログラマの 3.3V が基板に回り込み
  不安定になる個体があるので、読み出し検証 → 失敗するようなら JTAG(ルート A/B)に切替

## うまくいかない場合の分岐

- **手順 2 で con 後に u-boot が DFU に入らない**: tezuka の u-boot が QSPI から
  先に飛んでいる等。xsdb で `stop` → もう一度 u-boot の dow から再試行。
  FSBL 実行待ち(after 4000)を 2000/8000 に変えると挙動が変わることがある。
- **MMU/キャッシュ状態で u-boot がクラッシュ**: `rst -processor` してから
  FSBL ロードからやり直す(BootROM は再実行されない)。
- **JTAG が見えない**: 配線(特に GND と VREF)、ケーブルのドライバ
  (WSL では hw_server がそのまま認識。Windows 側 Vivado Lab でも可)。

## 根本復旧(SDR を動かす)への道

boot 復元後も firmware(itb)側の SDR は「このボードのピン配置に合うビットストリーム」
が無いと動かない。候補:
1. **販売元から出荷ファームを入手**(依頼済み/依頼する)— 最良。bitstream + dts が正解データ
2. tezuka のソースから nano 用カーネルを **zImage でビルド**し、tezuka の
   bitstream/dts/rootfs と組み合わせてベンダー u-boot で起動できる itb に再梱包
   (boot は書き換えない)。ただし tezuka nano は DDR 安定性の既知問題あり
   (tezuka_fw/doc/crashnano.md)で、この個体と設計が同一かも未確認
3. 自作 v1: tezuka の nano XDC からピン配置(事実情報)を転記して公式構成の HDL を
   このボード向けにビルド(Vivado 導入後)

**追記（2026-10-13 夜）**: Pico を配線したままだと **JTAG 信号線経由で基板が寄生給電**され、
両 USB を抜いても POWER/DONE が点いたまま（= 電源断にならない）。電源断の手順は
「Pico の USB を抜く → 板の両 USB を抜く → 10 秒 → UART → SLAVE → 最後に Pico の USB」。
