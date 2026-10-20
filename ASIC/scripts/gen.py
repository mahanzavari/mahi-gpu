"""Constrained-random program generator for the mahi GPU (ASIC profile, 8 threads).

Programs are guaranteed to terminate and to be free of inter-thread races:
  * only forward branches + loops with a protected, bounded counter,
  * acyclic call graph (callees defined after callers), no loops inside functions
    (they would clobber the caller's loop counter),
  * every store goes to the thread's private region (R28 + off),
  * loads come from the read-only input region (0..127) or the private region,
  * no division by zero (divisor is OR'ed with 1), addresses stay < 1024.
Register map:  R0-R17 random pool | R18,R19 loop counters | R21=1 R22=3 | R24=127
               R25=63 R26=tmp | R27=0 | R28=private base | R29-R31 special.
Register state is made observable by dumping R0-R17 into the private region.
"""
import random
from isa import *

POOL = list(range(0, 18))
SRC = POOL + [30, 31, 27, 21, 22]
LOOPCNT = [18, 19]
C1, C3, C127, C63, TMP, ZERO, BASE = 21, 22, 24, 25, 26, 27, 28
PRIV_BASE, PRIV_STRIDE, INPUT_WORDS = 256, 64, 128
DUMP_WORDS = len(POOL)


class Gen:
    def __init__(self, seed, size=16):
        self.r = random.Random(seed)
        self.code = []              # list of ints or ('br'|'call', nzp, label) fixups
        self.labels = {}
        self.nlabel = 0
        self.size = size
        self.funcs = []             # label names of callable functions, in definition order
        self.stores_used = False

    # ---- emission helpers
    def emit(self, w): self.code.append(w)
    def new_label(self): self.nlabel += 1; return f'L{self.nlabel}'
    def place(self, l): self.labels[l] = len(self.code)
    def br(self, nzp, label): self.code.append(('br', nzp, label))
    def call(self, label): self.code.append(('call', 0, label))

    def jmp(self, label):
        self.emit(enc_R('CMP', 0, ZERO, ZERO))      # Z=1 -> BR 111 always taken, and safe if NZP unset
        self.br(7, label)

    def rd(self): return self.r.choice(POOL)
    def rs(self): return self.r.choice(SRC)

    # ---- statements
    def stmt_alu(self):
        c = self.r.random()
        if c < 0.55:
            self.emit(enc_R(self.r.choice(BINOPS), self.rd(), self.rs(), self.rs()))
        elif c < 0.65:
            self.emit(enc_R('MAC', self.rd(), self.rs(), self.rs()))
        elif c < 0.77:
            self.emit(enc_R(self.r.choice(UNOPS), self.rd(), self.rs(), 0))
        elif c < 0.87:
            self.emit(enc_R('OR', TMP, self.rs(), C1))                   # tmp = x | 1  (nonzero)
            self.emit(enc_R(self.r.choice(['DIV', 'MOD']), self.rd(), self.rs(), TMP))
        elif c < 0.95:
            self.emit(enc_I('CONST', self.rd(), 0, self.r.randint(-32768, 32767)))
        else:
            self.emit(enc_LUI(self.rd(), self.r.randint(0, 0xFFFFF)))

    def stmt_mem(self):
        c = self.r.random()
        if c < 0.30:
            self.emit(enc_I('LDR', self.rd(), ZERO, self.r.randrange(INPUT_WORDS)))        # input[imm]
        elif c < 0.50:
            self.emit(enc_R('AND', TMP, self.rs(), C127))                                    # input[x & 127]
            self.emit(enc_I('LDR', self.rd(), TMP, 0))
        elif c < 0.70:
            off = self.r.randrange(DUMP_WORDS, PRIV_STRIDE)
            self.emit(enc_I('STR', self.rs(), BASE, off)); self.stores_used = True          # priv[off] = x
        elif c < 0.85:
            self.emit(enc_I('LDR', self.rd(), BASE, self.r.randrange(DUMP_WORDS, PRIV_STRIDE)))
        else:                                                                                # data-dependent private
            self.emit(enc_R('AND', TMP, self.rs(), C63))
            self.emit(enc_R('ADD', TMP, TMP, BASE))
            if self.r.random() < 0.5: self.emit(enc_I('STR', self.rs(), TMP, 0))
            else: self.emit(enc_I('LDR', self.rd(), TMP, 0))

    def stmt_if(self, depth, in_func, loop_depth=0):
        then_l, end_l = self.new_label(), self.new_label()
        self.emit(enc_R('CMP', 0, self.rs(), self.rs()))
        self.br(self.r.choice([1, 2, 3, 4, 5, 6, 7]), then_l)
        self.block(depth + 1, self.r.randint(1, 4), in_func, loop_depth)   # else (fallthrough)
        self.jmp(end_l)
        self.place(then_l)
        self.block(depth + 1, self.r.randint(1, 4), in_func, loop_depth)
        self.place(end_l)

    def stmt_loop(self, depth, loop_depth):
        cnt = LOOPCNT[loop_depth]
        top = self.new_label()
        self.emit(enc_R('AND', cnt, self.rs(), C3))          # per-thread trip count 1..4
        self.emit(enc_R('ADD', cnt, cnt, C1))
        self.place(top)
        self.block(depth + 1, self.r.randint(2, 5), False, loop_depth + 1)
        self.emit(enc_R('SUB', cnt, cnt, C1))
        self.emit(enc_R('CMP', 0, cnt, ZERO))
        self.br(1, top)                                      # P: cnt > 0

    def stmt_call(self, depth):
        avail = [f for f in self.funcs]
        if avail: self.call(self.r.choice(avail))

    def block(self, depth, n, in_func=False, loop_depth=0):
        for _ in range(n):
            c = self.r.random()
            if depth < 2 and c < 0.14:
                self.stmt_if(depth, in_func, loop_depth)
            elif not in_func and loop_depth < 2 and depth < 2 and c < 0.20:
                self.stmt_loop(depth, loop_depth)
            elif c < 0.28 and self.funcs:
                self.stmt_call(depth)
            elif c < 0.55:
                self.stmt_mem()
            else:
                self.stmt_alu()

    # ---- whole program
    def build(self):
        r = self.r
        # functions are defined after main, but callers need the names up front
        nfunc = r.randint(0, 3)
        names = [f'F{i}' for i in range(nfunc)]
        # prologue
        self.emit(enc_I('CONST', ZERO, 0, 0))
        self.emit(enc_I('CONST', C1, 0, 1)); self.emit(enc_I('CONST', C3, 0, 3))
        self.emit(enc_I('CONST', C127, 0, 127)); self.emit(enc_I('CONST', C63, 0, 63))
        self.emit(enc_I('CONST', TMP, 0, PRIV_STRIDE)); self.emit(enc_R('MUL', BASE, 31, TMP))
        self.emit(enc_I('CONST', TMP, 0, PRIV_BASE)); self.emit(enc_R('ADD', BASE, BASE, TMP))
        for reg in POOL:                                     # thread-varying initial state
            self.emit(enc_I('CONST', reg, 0, r.randint(-32768, 32767)))
            if r.random() < 0.6: self.emit(enc_R('ADD', reg, reg, 31))
        # main body may call any function (callers precede callees: acyclic)
        self.funcs = names
        self.block(0, self.size)
        # epilogue: make registers observable
        for i, reg in enumerate(POOL): self.emit(enc_I('STR', reg, BASE, i))
        self.emit(enc_EXIT())
        # function bodies; function k may only call functions with index > k
        for k, name in enumerate(names):
            self.place(name)
            self.funcs = names[k + 1:]
            self.block(1, r.randint(3, 10), in_func=True)
            self.emit(enc_RET())
        return self.assemble()

    def assemble(self):
        out = []
        for w in self.code:
            if isinstance(w, tuple):
                kind, nzp, label = w
                tgt = self.labels[label]
                out.append(enc_BR(nzp, tgt) if kind == 'br' else enc_CALL(tgt))
            else:
                out.append(w)
        return out


def make_input(seed):
    r = random.Random(seed ^ 0x5EED)
    return [r.getrandbits(32) for _ in range(INPUT_WORDS)]


def write_hex(path, words):
    with open(path, 'w') as f:
        for w in words: f.write(f'{w & M:08x}\n')


if __name__ == '__main__':
    import sys
    seed = int(sys.argv[1]); g = Gen(seed)
    prog = g.build(); print(len(prog), 'words')
