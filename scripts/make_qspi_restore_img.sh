#!/bin/bash
# SPDX-License-Identifier: MIT
# QSPI フラッシュ（W25Q256、32MiB）へ直接書き込むための復旧イメージを組み立てる。
# flashrom + SOIC クリップ（FT232H の ft2232_spi か CH341A）で使う。
#
# パーティション（実機 dmesg で確認済み）:
#   0x0000000-0x00FFFFF qspi-fsbl-uboot ← recovery/vendor-boot-backup.bin（1MiB ちょうど）
#   0x0100000-0x011FFFF qspi-uboot-env  ← recovery/vendor-ubootenv-backup.bin（128KiB）
#   0x0120000-0x01FFFFF qspi-nvmfs     ← 触らない（較正値などの jffs2。flashrom の -i から除外）
#   0x0200000-0x1FFFFFF qspi-linux     ← 自ビルド v0.39 の itb（ベンダー u-boot で起動実績あり）
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REC="$HERE/../recovery"
ITB="$HOME/pluto-fw-isdbt/plutosdr-fw/build/pluto.itb"
OUT="$REC/qspi-restore.img"
LAYOUT="$REC/qspi-layout.txt"

test -f "$REC/vendor-boot-backup.bin" || { echo "missing vendor-boot-backup.bin"; exit 1; }
test -f "$REC/vendor-ubootenv-backup.bin" || { echo "missing vendor-ubootenv-backup.bin"; exit 1; }
test -f "$ITB" || { echo "missing $ITB (make build/pluto.frm を先に)"; exit 1; }

# 32MiB を 0xFF で埋める（未書き込み領域はフラッシュの消去状態に合わせる）
python3 - "$OUT" << 'EOF'
import sys
open(sys.argv[1], "wb").write(b"\xff" * (32 * 1024 * 1024))
EOF
dd if="$REC/vendor-boot-backup.bin" of="$OUT" bs=64K conv=notrunc status=none
dd if="$REC/vendor-ubootenv-backup.bin" of="$OUT" bs=64K seek=16 conv=notrunc status=none   # 0x100000
dd if="$ITB" of="$OUT" bs=64K seek=32 conv=notrunc status=none                              # 0x200000

cat > "$LAYOUT" << 'EOF'
0x000000:0x0fffff boot
0x100000:0x11ffff env
0x200000:0xdfffff fw
EOF

ls -l "$OUT" "$LAYOUT"
echo
echo "書き込み（ボードは両方の USB を抜いて完全に無電源で。クリップ装着後）:"
echo "  FT232H: flashrom -p ft2232_spi:type=232H -l $LAYOUT -i boot -i env -i fw --noverify-all -w $OUT"
echo "  CH341A: flashrom -p ch341a_spi            -l $LAYOUT -i boot -i env -i fw --noverify-all -w $OUT"
echo "（まず -r read.bin で現状読み出しが通るか確認してから -w すること）"
