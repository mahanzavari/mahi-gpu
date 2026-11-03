#!/usr/bin/env python3
"""mahi disassembler. Output reassembles with mahias.py to the identical words, for any input:
non-canonical words (unknown opcode, or bits set outside the format's fields) come out as `.word`.

    python sw/asm/mahidis.py kernel.hex [-f auto|hex|hex128|bin] [--no-labels] [--no-addr]
"""
import argparse, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'isa'))
from mahi_isa import ISA


def sext16(v): return v - 0x10000 if v & 0x8000 else v


def operand(tok, f, label):
    if tok in ('rd', 'rc', 'rv'): return f'r{f["rd"]}'
    if tok in ('rs', 'rt'): return f'r{f[tok]}'
    if tok == 'imm': return str(sext16(f['imm16']))
    if tok == 'uimm20': return f'{f["imm20"]:#x}'
    if tok == 'target': return label(f['imm16'])
    if tok == '[rs]': return f'[r{f["rs"]}]'
    if tok == '[rs+imm]':
        off = sext16(f['imm16'])
        return f'[r{f["rs"]}]' if off == 0 else f'[r{f["rs"]}{off:+d}]'
    raise AssertionError(tok)


def disasm_word(w, label=str):
    """Text for one word (without labels), or None if it is not a canonical encoding."""
    ins, f, stray = ISA.decode(w)
    if ins is None or stray: return None
    if ins.name == 'BR':
        cond = ISA.nzp_text(f['nzp'])
        return f'BR{cond} {label(f["imm16"])}' if cond else f'BR 0, {label(f["imm16"])}'
    ops = ', '.join(operand(t, f, label) for t in ins.syntax)
    return f'{ins.name} {ops}'.rstrip()


def targets(words):
    out = set()
    for w in words:
        ins, f, stray = ISA.decode(w)
        if ins is not None and not stray and ins.name in ('BR', 'CALL') and f['imm16'] < len(words):
            out.add(f['imm16'])
    return out


def disassemble(words, labels=True, addresses=True):
    tg = targets(words) if labels else set()
    label = (lambda a: f'L{a}' if a in tg else str(a))
    lines = []
    for a, w in enumerate(words):
        if a in tg: lines.append(f'L{a}:')
        text = disasm_word(w, label)
        if text is None:
            ins, _, stray = ISA.decode(w)
            why = f'unknown opcode {ISA.get(w, "op")}' if ins is None else f'{ins.name} with stray bits {stray:#010x}'
            text, note = f'.word {w:#010x}', why
        else:
            note = ''
        cmt = '  '.join(x for x in (f'{a:04x}: {w:08x}' if addresses else '', note) if x)
        lines.append(f'    {text:<28} ; {cmt}' if cmt else f'    {text}')
    return '\n'.join(lines) + '\n'


def read_words(path, fmt='auto'):
    if fmt == 'auto':
        fmt = 'bin' if path.endswith('.bin') else 'hex'
    if fmt == 'bin':
        data = open(path, 'rb').read()
        if len(data) % 4: raise ValueError(f'{path}: size {len(data)} is not a multiple of 4')
        return [int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4)]
    words = []
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        t = line.split('//')[0].strip().replace('_', '')
        if not t or t.startswith('@'):
            if t: raise ValueError(f'{path}:{n}: address records (@) are not supported')
            continue
        if len(t) == 8 and fmt in ('hex', 'auto'): words.append(int(t, 16))
        elif len(t) == 32 and fmt in ('hex', 'hex128'):
            words += [int(t[i:i + 8], 16) for i in (24, 16, 8, 0)]     # word 0 is the rightmost
        else:
            raise ValueError(f'{path}:{n}: expected 8 or 32 hex digits, got {t!r}')
    return words


def main(argv=None):
    ap = argparse.ArgumentParser(description='mahi disassembler')
    ap.add_argument('src')
    ap.add_argument('-f', '--format', choices=['auto', 'hex', 'hex128', 'bin'], default='auto')
    ap.add_argument('-o', '--output')
    ap.add_argument('--no-labels', action='store_true')
    ap.add_argument('--no-addr', action='store_true')
    a = ap.parse_args(argv)
    text = disassemble(read_words(a.src, a.format), not a.no_labels, not a.no_addr)
    if a.output:
        with open(a.output, 'w', newline='\n') as f: f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
