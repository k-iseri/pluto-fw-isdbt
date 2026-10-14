#!/usr/bin/env python3
"""Minimal Xilinx Virtual Cable (XVC) client with a JTAG TAP state machine and
boundary-scan SAMPLE capture for a chain of [ARM DAP (IR 4)] + [xc7z010 PL TAP (IR 6)].

Read-only: only IDCODE / BYPASS / SAMPLE instructions are ever shifted. No EXTEST.
"""
import json
import socket
import struct
import sys
import time


class Xvc:
    def __init__(self, host="127.0.0.1", port=2542):
        self.s = socket.create_connection((host, port), timeout=10)
        self.s.sendall(b"getinfo:")
        self.info = self._recv_until(b"\n").decode()
        self.maxvec = int(self.info.strip().split(":")[1])

    def _recv_until(self, term):
        buf = b""
        while not buf.endswith(term):
            c = self.s.recv(1)
            if not c:
                raise IOError("xvc closed")
            buf += c
        return buf

    def _recvn(self, n):
        buf = b""
        while len(buf) < n:
            c = self.s.recv(n - len(buf))
            if not c:
                raise IOError("xvc closed")
            buf += c
        return buf

    def settck(self, ns):
        self.s.sendall(b"settck:" + struct.pack("<I", ns))
        return struct.unpack("<I", self._recvn(4))[0]

    def shift(self, tms_bits, tdi_bits):
        """tms_bits/tdi_bits: lists of 0/1, same length. Returns list of tdo bits."""
        n = len(tms_bits)
        assert n == len(tdi_bits)
        out = []
        # chunk so that each byte vector stays well under maxvec
        step = min(n, (self.maxvec // 2 - 8) * 8) if n else 0
        for off in range(0, n, max(step, 1)):
            tm = tms_bits[off:off + step]
            td = tdi_bits[off:off + step]
            k = len(tm)
            nb = (k + 7) // 8
            tmb = bytearray(nb)
            tdb = bytearray(nb)
            for i in range(k):
                if tm[i]:
                    tmb[i >> 3] |= 1 << (i & 7)
                if td[i]:
                    tdb[i >> 3] |= 1 << (i & 7)
            self.s.sendall(b"shift:" + struct.pack("<I", k) + bytes(tmb) + bytes(tdb))
            r = self._recvn(nb)
            out.extend((r[i >> 3] >> (i & 7)) & 1 for i in range(k))
        return out


class Tap:
    """Keeps the TAP in Run-Test/Idle between operations."""

    def __init__(self, xvc):
        self.x = xvc

    def reset(self):
        self.x.shift([1] * 6 + [0], [0] * 7)  # -> TLR -> RTI

    def _shift_reg(self, to_shift, bits):
        """to_shift: TMS path from RTI to Shift-xR. Returns tdo bits of the shift."""
        n = len(bits)
        tms = to_shift + [0] * (n - 1) + [1] + [1, 0]  # ... Exit1 -> Update -> RTI
        tdi = [0] * len(to_shift) + list(bits) + [0, 0]
        tdo = self.x.shift(tms, tdi)
        return tdo[len(to_shift):len(to_shift) + n]

    def shift_ir(self, bits):
        return self._shift_reg([1, 1, 0, 0], bits)

    def shift_dr(self, bits):
        return self._shift_reg([1, 0, 0], bits)


def bits_from_int(v, n):
    return [(v >> i) & 1 for i in range(n)]


def int_from_bits(bits):
    v = 0
    for i, b in enumerate(bits):
        v |= b << i
    return v


class Chain:
    """Chain description built empirically from IDCODEs after reset.
    devs: list from TDO side to TDI side: [(idcode, irlen)]"""
    IRLEN = {0x0ba00477: 4, 0x03722093: 6}

    def __init__(self, tap):
        self.tap = tap
        tap.reset()
        raw = tap.shift_dr([1] * 96)  # after TLR every device presents IDCODE (LSB=1)
        devs = []
        i = 0
        while i + 32 <= 96:
            if raw[i] != 1:
                break
            idc = int_from_bits(raw[i:i + 32])
            if idc == 0xFFFFFFFF:
                break
            devs.append(idc & 0x0FFFFFFF)
            i += 32
        self.devs = devs  # devs[0] is nearest TDO (its bits come out first)
        self.irlens = [self.IRLEN[d] for d in devs]

    def describe(self):
        return " -> ".join(f"{d:#010x}(ir{l})" for d, l in zip(self.devs[::-1], self.irlens[::-1])) + " -> TDO"

    def set_ir(self, target_idx, opcode_bits):
        """Load opcode into devs[target_idx], BYPASS into the rest."""
        stream = []
        for k, (d, l) in enumerate(zip(self.devs, self.irlens)):
            stream += opcode_bits if k == target_idx else [1] * l
        cap = self.tap.shift_ir(stream)
        return cap

    def dr_window(self, target_idx, nbits):
        """Shift a DR where the target is nbits long and the others are 1-bit bypass.
        Returns the target's bits (bit 0 = first out of the target = cell 0)."""
        pre = target_idx            # bypass bits ahead of the target (nearer TDO)
        post = len(self.devs) - 1 - target_idx
        total = pre + nbits + post
        raw = self.tap.shift_dr([0] * total)
        return raw[pre:pre + nbits]


def load_bsdl(path):
    return json.load(open(path))


def main():
    bsdl = load_bsdl(sys.argv[1])
    x = Xvc()
    print("xvc:", x.info.strip())
    tap = Tap(x)
    ch = Chain(tap)
    print("chain: TDI ->", ch.describe())
    tgt = [k for k, d in enumerate(ch.devs) if d == 0x03722093]
    if not tgt:
        sys.exit("no xc7z010 in chain")
    tgt = tgt[0]
    # IR capture check: 7-series IR capture value ends in ...01, ARM DAP captures 0001
    cap = ch.set_ir(tgt, bits_from_int(int(bsdl["opcodes"]["IDCODE"], 2), bsdl["ir_len"]))
    print("ir capture:", "".join(str(b) for b in cap[::-1]))
    idc = ch.dr_window(tgt, 32)
    print(f"idcode via IR: {int_from_bits(idc):#010x}")
    # SAMPLE: capture BSR
    ch.set_ir(tgt, bits_from_int(int(bsdl["opcodes"]["SAMPLE"], 2), bsdl["ir_len"]))
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    out = sys.argv[3] if len(sys.argv) > 3 else None
    interval = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    t0 = time.time()
    samples = []
    for k in range(n):
        samples.append(ch.dr_window(tgt, bsdl["bsr_len"]))
        if interval:
            time.sleep(interval)
    dt = time.time() - t0
    print(f"{n} captures in {dt:.2f} s ({dt / n * 1000:.0f} ms each)")
    if out:
        with open(out, "w") as f:
            for s in samples:
                f.write("".join(str(b) for b in s) + "\n")
        print("wrote", out)


if __name__ == "__main__":
    main()
