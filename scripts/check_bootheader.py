# Zynq-7000 ブートヘッダのチェックサム検証（UG585 6.3.2: 0x48 = ~(sum of 0x20..0x44)）
import struct
import sys

for path in sys.argv[1:]:
    b = open(path, "rb").read(0x100)
    words = struct.unpack_from("<10I", b, 0x20)   # 0x20..0x44 の 10 ワード
    s = sum(words) & 0xFFFFFFFF
    want = (~s) & 0xFFFFFFFF
    (got,) = struct.unpack_from("<I", b, 0x48)
    ok = "OK " if got == want else "BAD"
    print(f"{ok} {path}")
    print(f"     width=0x{words[0]:08X} ident=0x{words[1]:08X} enc=0x{words[2]:08X}")
    print(f"     fsbl_src=0x{words[4]:X} fsbl_len=0x{words[5]:X} load=0x{words[6]:X} exec=0x{words[7]:X} total=0x{words[8]:X}")
    print(f"     checksum: stored=0x{got:08X} calc=0x{want:08X}")
