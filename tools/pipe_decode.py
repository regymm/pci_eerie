#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-P
"""Decode a pipe.log produced by tb/pipe_mon.v.

Each line: <time> L<ltssm> T<eidle><k1><k0> <data16> R<valid><k1><k0> <data16>
Byte 0 (data[7:0]) is the earlier symbol on the wire.

Descrambles both directions, splits ordered sets / DLLPs / TLPs, checks
CRC16 / LCRC, and prints a readable trace.  Used as a golden reference for the
pci_eerie RTL conventions.
"""
import sys

K = {0xBC: 'COM', 0xFB: 'STP', 0x5C: 'SDP', 0xFD: 'END', 0xFE: 'EDB',
     0xF7: 'PAD', 0x1C: 'SKP', 0x3C: 'FTS', 0x7C: 'IDL', 0xFC: 'EIE'}


def lfsr_byte(l):
    """Return (scramble byte, next lfsr) for a 16-bit Galois LFSR as in spec."""
    out = 0
    for i in range(8):
        out |= ((l >> 15) & 1) << i
        fb = (l >> 15) & 1
        l = ((l << 1) & 0xFFFF)
        if fb:
            l ^= 0x0039  # taps x^5,x^4,x^3,1 -> bits 5,4,3,0
    return out, l


def crc32_pcie(data):
    c = 0xFFFFFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ (0xEDB88320 if c & 1 else 0)
    c ^= 0xFFFFFFFF
    return [c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF]


def crc16_dllp(data):
    c = 0xFFFF
    for b in data:
        for i in range(8):
            bit = (b >> i) & 1
            fb = ((c >> 15) & 1) ^ bit
            c = (c << 1) & 0xFFFF
            if fb:
                c ^= 0x100B
    c ^= 0xFFFF
    # Table 3-2: result bit i -> field bit (7-i) for i<8, (23-i) for i>=8
    field = 0
    for i in range(16):
        pos = (7 - i) if i < 8 else (23 - i)
        field |= ((c >> i) & 1) << pos
    return [(field >> 8) & 0xFF, field & 0xFF]


class Lane:
    def __init__(self, name):
        self.name = name
        self.lfsr = 0xFFFF
        self.os = None      # list of symbols of current ordered set
        self.ts_left = 0
        self.pkt = None
        self.pkt_kind = None
        self.out = []
        self.last_os = None
        self.os_rep = 0

    def flush_os(self, t):
        if self.os is None:
            return
        o = self.os
        self.os = None
        if len(o) >= 2 and o[1][1] and o[1][0] == 0x1C:
            desc = 'SKP x%d' % (len(o) - 1)
        elif len(o) >= 2 and o[1][1] and o[1][0] == 0x7C:
            desc = 'EIOS'
        elif len(o) >= 2 and o[1][1] and o[1][0] == 0x3C:
            desc = 'FTS'
        elif len(o) >= 16:
            ident = o[10][0]
            tsn = {0x4A: 'TS1', 0x45: 'TS2', 0xB5: 'TS1(inv)', 0xBA: 'TS2(inv)'}.get(ident, 'TS?%02x' % ident)
            f = lambda s: ('PAD' if s[1] and s[0] == 0xF7 else '%02x' % s[0])
            desc = '%s link=%s lane=%s nfts=%02x rate=%02x ctl=%02x' % (
                tsn, f(o[1]), f(o[2]), o[3][0], o[4][0], o[5][0])
        else:
            desc = 'OS? ' + ' '.join(('K' if k else '') + '%02x' % d for d, k in o)
        if desc == self.last_os:
            self.os_rep += 1
            return
        if self.os_rep:
            self.out.append((t, '   (previous x%d more)' % self.os_rep))
        self.os_rep = 0
        self.last_os = desc
        self.out.append((t, desc))

    def sym(self, t, d, k):
        # scrambler bookkeeping first
        if k and d == 0xBC:
            self.flush_os(t)
            self.lfsr = 0xFFFF
            self.os = [(d, k)]
            self.ts_left = -1   # decide on next symbol
            return
        if k and d == 0x1C:
            if self.os is not None:
                self.os.append((d, k))
                self.ts_left = 0          # SKP ordered set: no raw TS symbols follow
            return
        sb, nl = lfsr_byte(self.lfsr)
        self.lfsr = nl
        if self.os is not None:
            if self.ts_left == -1:
                if k and d in (0x7C, 0x3C):
                    self.ts_left = 2
                    self.os.append((d, k))
                    return
                if k and d == 0x1C:
                    return
                if not k or d == 0xF7:
                    self.ts_left = 14
                    self.os.append((d, k))
                    return
                self.flush_os(t)
            elif self.ts_left > 0:
                self.ts_left -= 1
                self.os.append((d, k))
                if self.ts_left == 0:
                    self.flush_os(t)
                return
            else:
                self.flush_os(t)
        if not k:
            d ^= sb
        if k and d in (0xFB, 0x5C):
            if self.pkt is not None:
                self.out.append((t, '!! start inside packet'))
            self.pkt = []
            self.pkt_kind = 'TLP' if d == 0xFB else 'DLLP'
            self.pkt_t = t
            return
        if k and d in (0xFD, 0xFE):
            if self.pkt is None:
                self.out.append((t, '!! END outside packet'))
                return
            self.report(self.pkt_t, self.pkt, d == 0xFE)
            self.pkt = None
            return
        if self.pkt is not None:
            if k:
                self.out.append((t, '!! K %02x inside packet' % d))
                self.pkt = None
            else:
                self.pkt.append(d)
            return
        if k:
            self.out.append((t, 'K %s' % K.get(d, '%02x' % d)))
        elif d != 0:
            self.out.append((t, 'idle? %02x' % d))

    def report(self, t, p, edb):
        if self.pkt_kind == 'DLLP':
            if len(p) != 6:
                self.out.append((t, '!! DLLP len %d' % len(p)))
                return
            ok = crc16_dllp(p[:4]) == p[4:6]
            ty = p[0]
            if ty == 0x00 or ty == 0x10:
                s = '%s seq=%d' % ('ACK' if ty == 0 else 'NAK', ((p[2] & 0xF) << 8) | p[3])
            elif (ty >> 4) in (4, 5, 6, 0xC, 0xD, 0xE, 8, 9, 0xA):
                nm = {4: 'InitFC1', 5: 'InitFC1', 6: 'InitFC1', 0xC: 'InitFC2', 0xD: 'InitFC2', 0xE: 'InitFC2',
                      8: 'UpdateFC', 9: 'UpdateFC', 0xA: 'UpdateFC'}[ty >> 4]
                tt = ['P', 'NP', 'Cpl'][(ty >> 4) & 3]
                hdr = ((p[1] & 0x3F) << 2) | (p[2] >> 6)
                dat = ((p[2] & 0xF) << 8) | p[3]
                s = '%s-%s hdr=%d data=%d' % (nm, tt, hdr, dat)
            else:
                s = 'DLLP type %02x' % ty
            self.out.append((t, 'DLLP %s crc=%s [%s]' % (s, 'ok' if ok else 'BAD(exp %s)' % bytes(crc16_dllp(p[:4])).hex(),
                                                           bytes(p).hex())))
        else:
            if len(p) < 6:
                self.out.append((t, '!! TLP too short'))
                return
            seq = ((p[0] & 0xF) << 8) | p[1]
            body = p[2:-4]
            ok = crc32_pcie(p[:-4]) == p[-4:]
            self.out.append((t, 'TLP seq=%d%s lcrc=%s %s' % (seq, ' (EDB)' if edb else '',
                                                           'ok' if ok else 'BAD(exp %s got %s)' % (bytes(crc32_pcie(p[:-4])).hex(), bytes(p[-4:]).hex()),
                                                           tlp_str(body))))


def tlp_str(b):
    if len(b) < 12:
        return 'short ' + bytes(b).hex()
    fmt = b[0] >> 5
    typ = b[0] & 0x1F
    ln = ((b[2] & 3) << 8) | b[3]
    names = {(0, 0): 'MRd32', (1, 0): 'MRd64', (2, 0): 'MWr32', (3, 0): 'MWr64', (0, 2): 'IORd', (2, 2): 'IOWr',
             (0, 4): 'CfgRd0', (2, 4): 'CfgWr0', (0, 5): 'CfgRd1', (2, 5): 'CfgWr1', (0, 0xA): 'Cpl', (2, 0xA): 'CplD'}
    nm = names.get((fmt, typ), 'Msg' if (typ >> 3) == 2 else 'fmt%d type%02x' % (fmt, typ))
    return '%s len=%d hdr=%s' % (nm, ln, ' '.join(bytes(b[i:i + 4]).hex() for i in range(0, len(b), 4)))


def main():
    fn = sys.argv[1] if len(sys.argv) > 1 else 'pipe.log'
    tx, rx = Lane('EP->RP'), Lane('RP->EP')
    for line in open(fn):
        f = line.split()
        if len(f) < 6 or 'x' in line or 'z' in line:
            continue
        t = int(f[0])
        tf, td, rf, rd = f[2], int(f[3], 16), f[4], int(f[5], 16)
        if tf[1] == '0':  # not electrical idle
            tx.sym(t, td & 0xFF, tf[3] == '1')
            tx.sym(t, td >> 8, tf[2] == '1')
        if rf[1] == '1':  # rx valid
            rx.sym(t, rd & 0xFF, rf[3] == '1')
            rx.sym(t, rd >> 8, rf[2] == '1')
    ev = [(t, 'TX', s) for t, s in tx.out] + [(t, 'RX', s) for t, s in rx.out]
    ev.sort(key=lambda e: e[0])
    for t, d, s in ev:
        print('%12.3f us %s %s' % (t / 1e6, d, s))


if __name__ == '__main__':
    main()
