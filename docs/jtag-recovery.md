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

## ハードウェア

1. 1×6 ピンヘッダをはんだ付け(斜め挿しテンションでも短時間なら可)
2. Platform Cable USB II 互換(または Digilent HS2 等)を 1:1 で配線
   (VREF→3.3V、GND→GND、TMS/TCK/TDO/TDI はラベルどおり)
3. ボードは USB で PC に接続して給電しておく(ハング状態のままで OK)

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
