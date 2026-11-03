#!/usr/bin/env python3
"""Tests for the assembler and disassembler.   python sw/asm/test_asm.py [--words N] [--seeds N]

  * round trip: assemble(disassemble(words)) == words for every opcode, for random 32-bit words (including
    unknown opcodes and stray bits) and for the random generator's programs (ASIC/scripts/gen.py);
  * independent oracle: hand-written source checked against the golden model's encoders (ASIC/scripts/isa.py);
  * the existing kernels assemble to the same words as the old assembler/assembler.py;
  * every error and warning path.
"""
import argparse, os, random, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'ASIC', 'scripts'))
from mahias import assemble, AsmError, to_hex128
from mahidis import disassemble, read_words
from mahi_isa import ISA
import isa as g

fails = []
def check(cond, what):
    if not cond: fails.append(what)


def roundtrip(words, what):
    text = disassemble(words)
    try:
        back = assemble(text, what).words
    except AsmError as e:
        fails.append(f'{what}: disassembly does not reassemble: {e.errors[:3]}'); return
    if back != words:
        bad = next(i for i, (a, b) in enumerate(zip(back + [None] * len(words), words)) if a != b)
        fails.append(f'{what}: word {bad} {words[bad]:#010x} came back as {back[bad] if bad < len(back) else None}')


def test_opcodes(r):
    for ins in ISA.instrs:
        for _ in range(200):
            f = {k: r.getrandbits(ISA.width(k)) for k in ins.fields}
            roundtrip([ISA.encode(ins.name, **f)], f'opcode {ins.name} {f}')


def test_random_words(r, n):
    words = [r.getrandbits(32) for _ in range(n)]
    for i in range(0, n, 1000): roundtrip(words[i:i + 1000], f'random words {i}..')


def test_generator(seeds):
    import gen
    for s in range(seeds):
        roundtrip(gen.Gen(s).build(), f'gen.py seed {s}')


ORACLE = [
    ('ADD r1, r2, r3', g.enc_R('ADD', 1, 2, 3)),
    ('add R1,R2,R3', g.enc_R('ADD', 1, 2, 3)),
    ('ABS r4, r5', g.enc_R('ABS', 4, 5, 0)),
    ('NEG r4, tid', g.enc_R('NEG', 4, 31, 0)),
    ('MAC r1, r2, r3', g.enc_R('MAC', 1, 2, 3)),
    ('FMA r7, r2, r3', g.enc_R('FMA', 7, 2, 3)),
    ('CMP r9, r10', g.enc_R('CMP', 0, 9, 10)),
    ('CONST r6, -2', g.enc_I('CONST', 6, 0, -2)),
    ('CONST r6, 0x7fff', g.enc_I('CONST', 6, 0, 0x7FFF)),
    ('LUI r5, 0x3F800', g.enc_LUI(5, 0x3F800)),
    ('LDR r1, [r2-3]', g.enc_I('LDR', 1, 2, -3)),
    ('LDR r1, [r2]', g.enc_I('LDR', 1, 2, 0)),
    ('LDR r1, r2, 7', g.enc_I('LDR', 1, 2, 7)),
    ('STR r5, [r28+17]', g.enc_I('STR', 5, 28, 17)),
    ('STR r5, r0, 0', g.enc_I('STR', 5, 0, 0)),
    ('LDSH r4, [r3]', g.enc_R('LDSH', 4, 3, 0)),
    ('STSH r2, r31, 0', g.enc_R('STSH', 2, 31, 0)),
    ('ATOM_ADD r26, [r20], r1', g.enc_R('ATOM_ADD', 26, 20, 1)),
    ('ATOM_ADD r26, r20, r1', g.enc_R('ATOM_ADD', 26, 20, 1)),
    ('ATOM_CAS r3, [r4], r5', g.enc_R('ATOM_CAS', 3, 4, 5)),
    ('BRzp 12', g.enc_BR(3, 12)),
    ('BR 7, 12', g.enc_BR(7, 12)),
    ('BR np, 12', g.enc_BR(5, 12)),
    ('CALL 300', g.enc_CALL(300)),
    ('RET', g.enc_RET()), ('EXIT', g.enc_EXIT()), ('SYNC', g.OP['SYNC'] << 26), ('NOP', 0),
    ('MOV r1, r2', g.enc_R('OR', 1, 2, 2)),
    ('LI r1, -5', g.enc_I('CONST', 1, 0, -5)),
    ('LI r1, 0x40490000', g.enc_LUI(1, 0x40490)),
    ('.word 0xdeadbeef', 0xDEADBEEF),
]


def test_oracle():
    for src, want in ORACLE:
        try:
            got = assemble(src).words
            check(got == [want], f'{src!r} -> {[hex(w) for w in got]}, golden-model encoder gives {want:#010x}')
        except AsmError as e:
            fails.append(f'{src!r}: {e.errors}')


def test_program_features():
    src = """
        .equ N, 4
        .set BASE, 0x100
    start:  CONST r1, N*2          // labels may share a line
            JMP end
            BRnzp start ; comment
    mid:    .word 1, -1
            .org 8
    end:    LDR r2, [r1 + (BASE - 1)]
            CALL mid
    """
    p = assemble(src)
    want = [g.enc_I('CONST', 1, 0, 8), g.enc_R('CMP', 0, 0, 0), g.enc_BR(2, 8), g.enc_BR(7, 0), 1, 0xFFFFFFFF, 0, 0,
            g.enc_I('LDR', 2, 1, 0xFF), g.enc_CALL(4)]
    check(p.words == want, f'program features: {[hex(w) for w in p.words]}')
    check(p.symbols['end'] == 8 and p.symbols['mid'] == 4 and p.symbols['N'] == 4, f'symbols {p.symbols}')
    check(len(p.listing().splitlines()) == len(want), 'listing has one line per word')


ERRORS = [
    ('CONST r1, 40000', 'out of range'),
    ('LDR r1, [r2+40000]', 'out of range'),
    ('LUI r1, 0x100000', 'out of range'),
    ('BR 8, 0', 'out of range'),
    ('BRx 0', 'unknown instruction'),
    ('FOO r1', 'unknown instruction'),
    ('ADD r1, r2', 'takes 3 operand'),
    ('ADD r1, r2, r32', 'expected a register'),
    ('CONST r1, missing', "undefined symbol 'missing'"),
    ('LDSH r1, [r2+1]', 'has no address offset'),
    ('STSH r1, r2, 4', 'has no address offset'),
    ('x: NOP\nx: NOP', 'defined twice'),
    ('r3: NOP', 'register or mnemonic'),
    ('.org 1\nNOP\n.org 0', 'behind'),
    ('LI r1, 0x12345', 'needs LUI + CONST + OR'),
    ('CONST r1, 1/0', 'division by zero'),
    ('CONST r1, __import__', 'undefined symbol'),
    ('CONST r1, (lambda: 1)()', 'unsupported expression'),
    ('.bogus 1', 'unknown directive'),
]


def test_errors():
    for src, msg in ERRORS:
        try:
            assemble(src, 't.asm'); fails.append(f'{src!r} assembled; expected error containing {msg!r}')
        except AsmError as e:
            check(any(msg in x for x in e.errors), f'{src!r}: errors {e.errors} lack {msg!r}')
            check(all(x.startswith('t.asm:') for x in e.errors), f'{src!r}: error without file:line: {e.errors}')
    try:
        assemble('NOP\n' * 513, 'big.asm', profile='asic_mini'); fails.append('513 words fit asic_mini')
    except AsmError as e:
        check('exceed the 512-word' in e.errors[0], f'size error text: {e.errors}')
    assemble('NOP\n' * 512, 'ok.asm', profile='asic_mini')
    w = assemble('ADD r31, r1, r2\nSTR r31, [r0]').warnings
    check(len(w) == 1 and 'read-only' in w[0], f'read-only write warning: {w}')


def test_kernels():
    """New assembler == old assembler on every existing kernel, and kernels round-trip."""
    kernels = [os.path.join(REPO, 'assembler', 'kernels', k) for k in sorted(os.listdir(os.path.join(REPO, 'assembler', 'kernels')))]
    kernels.append(os.path.join(REPO, 'assembler', 'program.asm'))
    with tempfile.TemporaryDirectory() as d:
        for k in kernels:
            p = assemble(open(k, encoding='utf-8').read(), k)
            roundtrip(p.words, os.path.basename(k))
            old = os.path.join(d, 'old.hex')
            subprocess.run([sys.executable, os.path.join(REPO, 'assembler', 'assembler.py'), k, old], check=True, capture_output=True)
            check(open(old).read().lower().split() == to_hex128(p.words).split(), f'{os.path.basename(k)}: differs from assembler/assembler.py')
            with open(os.path.join(d, 'k.hex'), 'w') as f: f.write(to_hex128(p.words))
            words = read_words(os.path.join(d, 'k.hex'), 'hex128')
            check(words[:len(p.words)] == p.words and not any(words[len(p.words):]), f'{k}: hex128 read-back')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--words', type=int, default=50000)
    ap.add_argument('--seeds', type=int, default=200)
    a = ap.parse_args()
    r = random.Random(1)
    tests = [('opcodes', lambda: test_opcodes(r)), ('random words', lambda: test_random_words(r, a.words)),
             ('gen.py programs', lambda: test_generator(a.seeds)), ('golden-model oracle', test_oracle),
             ('program features', test_program_features), ('errors', test_errors), ('kernels', test_kernels)]
    for name, t in tests:
        n = len(fails); t()
        print(f'{name:22s} {"ok" if len(fails) == n else f"{len(fails) - n} FAIL"}')
    for f in fails[:30]: print('FAIL', f)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
