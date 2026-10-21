"""ISA encoding + golden reference interpreter for the mahi GPU (ASIC profile).

The interpreter decodes the same 32-bit machine words the DUT executes, so it is
independent of whatever produced them. Semantics are taken from decoder.sv,
alu.sv, pc.sv, registers.sv and lsu.sv. Each thread runs independently: this is
valid for programs without inter-thread communication (no shared mem, atomics,
SYNC, or overlapping stores), which is what the random generator emits.
"""
import os
M = 0xFFFFFFFF

OP = dict(NOP=0, BR=1, CMP=2, ADD=3, SUB=4, MUL=5, DIV=6, LDR=7, STR=8, CONST=9, SYNC=10,
          LDSH=11, STSH=12, CALL=13, RET=14, EXIT=15, ATOM_ADD=16, AND=17, OR=18, XOR=19,
          SHL=20, SHR=21, MOD=22, MIN=23, MAX=24, ABS=25, NEG=26, MAC=27, ATOM_CAS=28,
          LUI=29, POPCNT=30, CLZ=31, BREV=32, FADD=33, FSUB=34, FMUL=35, FMA=36)
NAME = {v: k for k, v in OP.items()}
FPOPS = ['FADD', 'FSUB', 'FMUL', 'FMA']
BINOPS = ['ADD', 'SUB', 'MUL', 'AND', 'OR', 'XOR', 'SHL', 'SHR', 'MIN', 'MAX']
UNOPS = ['ABS', 'NEG', 'POPCNT', 'CLZ', 'BREV']


def s32(x):
    x &= M
    return x - (1 << 32) if x & 0x80000000 else x


def sext16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


# ---- encoders ---------------------------------------------------------------
def enc_R(op, rd, rs, rt):
    return (OP[op] << 26) | (rd << 21) | (rs << 16) | (rt << 11)


def enc_I(op, rd, rs, imm):
    return (OP[op] << 26) | (rd << 21) | (rs << 16) | (imm & 0xFFFF)


def enc_BR(nzp, target):
    return (OP['BR'] << 26) | (nzp << 23) | (target & 0xFFFF)


def enc_CALL(target):
    return (OP['CALL'] << 26) | (target & 0xFFFF)


def enc_RET():
    return OP['RET'] << 26


def enc_EXIT():
    return OP['EXIT'] << 26


def enc_LUI(rd, imm20):
    return (OP['LUI'] << 26) | (rd << 21) | ((imm20 & 0xFFFFF) << 1)


# ---- ALU ----------------------------------------------------------------------
# MAHI_NO_DIV=1: DIV/MOD return 0 like the synthesized ASIC ALU (alu.sv without USE_COMB_DIV, limitation L2).
NO_DIV = os.environ.get('MAHI_NO_DIV') == '1'

def alu(op, a, b, rdv=0):
    if op == 'ADD': return (a + b) & M
    if op == 'SUB': return (a - b) & M
    if op == 'MUL': return (s32(a) * s32(b)) & M
    if op == 'DIV': return 0 if NO_DIV else (a // b) & M     # unsigned; generator guarantees b != 0
    if op == 'MOD': return 0 if NO_DIV else (a % b) & M
    if op == 'AND': return a & b
    if op == 'OR': return a | b
    if op == 'XOR': return a ^ b
    if op == 'SHL': return (a << b) & M if b < 32 else 0
    if op == 'SHR': return a >> b if b < 32 else 0
    if op == 'MIN': return a if s32(a) < s32(b) else b
    if op == 'MAX': return a if s32(a) > s32(b) else b
    if op == 'ABS': return (-s32(a)) & M if s32(a) < 0 else a
    if op == 'NEG': return (-s32(a)) & M
    if op == 'MAC': return (s32(rdv) + s32(a) * s32(b)) & M
    if op == 'POPCNT': return bin(a).count('1')
    if op == 'CLZ': return 32 - a.bit_length()
    if op == 'BREV': return int(format(a, '032b')[::-1], 2)
    raise ValueError(op)


# ---- bit-exact port of rtl/fp32_fma.sv ---------------------------------------
# Truncating (no rounding), denormals flush to zero, no Inf/NaN handling: an
# exponent of 255 is treated as an ordinary number. Mirrors the 4-stage datapath.
FP_ONE = 0x3F800000
FP_OP = {'FMA': 0, 'FADD': 1, 'FMUL': 2, 'FSUB': 3}


def fma_bits(op, a, b, c):
    o = FP_OP[op]
    if o == 0: ea_, eb_, ec_ = a, b, c
    elif o == 1: ea_, eb_, ec_ = a, FP_ONE, b
    elif o == 2: ea_, eb_, ec_ = a, b, 0
    else: ea_, eb_, ec_ = a, FP_ONE, b ^ 0x80000000
    def parts(x):
        e = (x >> 23) & 0xFF
        return x >> 31, e, ((1 << 23) | (x & 0x7FFFFF)) if e else 0
    sa, ea, fa = parts(ea_); sb, eb, fb = parts(eb_); sc, ec, fc = parts(ec_)
    mult = fa * fb                                  # 48 bits
    exp_ab = ea + eb - 127                          # signed
    sign_ab = sa ^ sb
    ab_full = mult << 24                            # 72-bit aligned product
    c_full = fc << 47                               # 72-bit aligned addend
    m72 = (1 << 72) - 1
    if exp_ab > ec:
        target = exp_ab; sh = (exp_ab - ec) & 0x3FF
        ab = ab_full & m72; cc = 0 if sh >= 72 else (c_full >> sh)
    else:
        target = ec; sh = (ec - exp_ab) & 0x3FF
        cc = c_full & m72; ab = 0 if sh >= 72 else (ab_full >> sh)
    if sign_ab == sc:
        total, sign = ab + cc, sign_ab
    elif ab >= cc:
        total, sign = ab - cc, sign_ab
    else:
        total, sign = cc - ab, sc
    if total == 0:
        nfract, nexp = 0, 0
    else:
        shamt = 72 - (total.bit_length() - 1)
        shifted = (total << shamt) & ((1 << 73) - 1)
        nfract = (shifted >> 49) & 0xFFFFFF
        nexp = target + 2 - shamt
    if nexp <= 0: return sign << 31
    if nexp >= 255: return (sign << 31) | (0xFF << 23)
    return (sign << 31) | (nexp << 23) | (nfract & 0x7FFFFF)


class Fault(Exception):
    pass


class Machine:
    """Interprets one program for N threads. Threads are generators that yield at SYNC, so
    barrier phases are modelled exactly; between barriers threads run one after another,
    which is valid because the generator keeps phases race-free."""

    SHARED_WORDS = 64

    def __init__(self, words, mem, nthreads=8, block_id=0, max_steps=200000):
        self.w, self.mem, self.n, self.bid, self.max_steps = words, mem, nthreads, block_id, max_steps
        self.shared = {}

    def load(self, a):
        if not 0 <= a < 1024: raise Fault(f'load addr {a}')
        return self.mem.get(a, 0)

    def thread(self, tid, out):
        r = [0] * 32
        r[29], r[30], r[31] = self.bid, self.n, tid
        nzp, pc, stack, steps = 0, 0, [], 0
        w = self.w
        while True:
            steps += 1
            if steps > self.max_steps: raise Fault(f'thread {tid} did not terminate')
            if pc >= len(w): raise Fault(f'thread {tid} pc {pc} out of program')
            i = w[pc]
            op = NAME.get(i >> 26)
            rd, rs, rt, imm = (i >> 21) & 31, (i >> 16) & 31, (i >> 11) & 31, i & 0xFFFF
            nxt = pc + 1
            if op in ('ADD', 'SUB', 'MUL', 'AND', 'OR', 'XOR', 'SHL', 'SHR', 'MIN', 'MAX', 'MAC'):
                v = alu(op, r[rs], r[rt], r[rd])
                if rd < 29: r[rd] = v
            elif op in ('DIV', 'MOD'):
                if r[rt] == 0: raise Fault('div by zero')
                if rd < 29: r[rd] = alu(op, r[rs], r[rt])
            elif op in UNOPS:
                if rd < 29: r[rd] = alu(op, r[rs], 0)
            elif op in FPOPS:
                v = fma_bits(op, r[rs], r[rt], r[rd])
                if rd < 29: r[rd] = v
            elif op == 'CONST':
                if rd < 29: r[rd] = sext16(imm) & M
            elif op == 'LUI':
                if rd < 29: r[rd] = (((i >> 1) & 0xFFFFF) << 12) & M
            elif op == 'CMP':
                a, b = r[rs], r[rt]
                nzp = (4 if a < b else 0) | (2 if a == b else 0) | (1 if a > b else 0)   # unsigned
            elif op == 'BR':
                if (nzp & ((i >> 23) & 7)) != 0: nxt = sext16(imm) & 0xFFFF
            elif op == 'CALL':
                stack.append(pc + 1); nxt = imm
            elif op == 'RET':
                nxt = stack.pop()
            elif op == 'LDR':
                v = self.load((r[rs] + sext16(imm)) & M)
                if rd < 29: r[rd] = v
            elif op == 'STR':
                a = (r[rs] + sext16(imm)) & M
                if not 0 <= a < 1024: raise Fault(f'store addr {a}')
                self.mem[a] = r[rd]          # STR value register is in the rd slot
            elif op == 'LDSH':
                a = r[rs]
                if not 0 <= a < self.SHARED_WORDS: raise Fault(f'shared load addr {a}')
                if rd < 29: r[rd] = self.shared.get(a, 0)
            elif op == 'STSH':
                a = r[rs]
                if not 0 <= a < self.SHARED_WORDS: raise Fault(f'shared store addr {a}')
                self.shared[a] = r[rd]
            elif op == 'ATOM_ADD':
                a = r[rs]
                if not 0 <= a < 1024: raise Fault(f'atomic addr {a}')
                old = self.mem.get(a, 0)
                self.mem[a] = (old + r[rt]) & M
                if rd < 29: r[rd] = old       # order-dependent: generator never observes it
            elif op == 'SYNC':
                yield 'SYNC'
            elif op == 'EXIT':
                out[tid] = r
                return
            elif op == 'NOP':
                pass
            else:
                raise Fault(f'unsupported opcode {i >> 26} at pc {pc}')
            pc = nxt

    def run(self):
        out = {}
        gens = {t: self.thread(t, out) for t in range(self.n)}
        while gens:
            waiting, finished = [], []
            for t, g in list(gens.items()):
                try:
                    next(g); waiting.append(t)
                except StopIteration:
                    finished.append(t); del gens[t]
            if waiting and finished:
                raise Fault('barrier reached by only a subset of threads (others exited)')
        return [out[t] for t in range(self.n)]
