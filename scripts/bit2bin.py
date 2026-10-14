#!/usr/bin/env python3
"""Vivado の .bit を Linux fpga_manager（zynq-fpga）が受け付ける .bin に変換する。

.bit の先頭にあるヘッダ（フィールド a〜d: 設計名・部品・日時）を落とし、フィールド e の
ビットストリーム本体を 32 bit 単位でバイトスワップする（zynq-fpga ドライバは先頭 128 バイト以内に
スワップ後の同期ワード 66 55 99 AA があることを要求する）。

usage: bit2bin.py in.bit out.bin
"""
import struct
import sys

src = open(sys.argv[1], "rb").read()
pos = 0
# 先頭: 2 バイト長 + 9 バイトのマジック + 2 バイト長 + 'a'
hdr_len = struct.unpack(">H", src[pos:pos + 2])[0]
pos += 2 + hdr_len
pos += 2  # 'a' の前の 0x0001
info = {}
while True:
    key = src[pos:pos + 1]
    pos += 1
    if key == b"e":
        length = struct.unpack(">I", src[pos:pos + 4])[0]
        pos += 4
        body = src[pos:pos + length]
        break
    length = struct.unpack(">H", src[pos:pos + 2])[0]
    pos += 2
    info[key.decode()] = src[pos:pos + length].rstrip(b"\0").decode(errors="replace")
    pos += length
assert len(body) % 4 == 0, len(body)
out = bytearray(len(body))
for i in range(0, len(body), 4):
    out[i:i + 4] = body[i:i + 4][::-1]
sync = out.find(bytes.fromhex("665599AA"))
assert 0 <= sync < 128, f"sync word not found in first 128 bytes (offset {sync})"
open(sys.argv[2], "wb").write(out)
print(f"{info.get('a','?')} part={info.get('b','?')} {info.get('c','?')} {info.get('d','?')}: {len(out)} bytes, sync @ {sync}")
