#!/bin/sh
# SPDX-License-Identifier: MIT
# buildroot の追加 post-build スクリプト（plutosdr-fw フォークの Makefile が
# BR2_ROOTFS_POST_BUILD_SCRIPT に board/pluto/post-build.sh の後ろとして渡す）。
# 環境変数 PLUTO_EXTRA_OVERLAY（絶対パス）が指すディレクトリを rootfs（$1 = TARGET_DIR）に重ねる。
# 起動スクリプト（S22fpga）などを buildroot 本体を改変せずに入れるためのもの。
set -e
TARGET_DIR=$1
if [ -n "$PLUTO_EXTRA_OVERLAY" ] && [ -d "$PLUTO_EXTRA_OVERLAY" ]; then
	echo "br-post-build: applying extra overlay $PLUTO_EXTRA_OVERLAY"
	cp -a "$PLUTO_EXTRA_OVERLAY"/. "$TARGET_DIR"/
	find "$TARGET_DIR/lib/firmware" -name .gitignore -delete 2>/dev/null || true
fi
