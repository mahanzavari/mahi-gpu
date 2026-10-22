#!/usr/bin/env python3
"""Split a Magic DRC report into macro-intrinsic (waivable) and integration errors.

  drc_waiver.py --report RUN/51-magic-drc/reports/drc.magic.rpt [--config flow/config.yaml]

A box is *waived* only if BOTH hold: (1) its rule also fires on the standalone OpenRAM macro
(flow/waivers/openram_2kb_macro_drc_rules.txt) and (2) it lies inside a macro instance box. Everything else is
an integration error and must be fixed. Exit code 1 if any integration error remains.
"""
import argparse, collections, re, sys

W, H = 683.1, 416.54          # sky130_sram_2kbyte_1rw1r_32x512_8 size (um)


def macro_origins(config):
    return [(float(a), float(b)) for a, b in re.findall(r'location:\s*\[\s*([\d.]+)\s*,\s*([\d.]+)\s*\]', open(config).read())]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--report', required=True); ap.add_argument('--config', default='flow/config.yaml')
    ap.add_argument('--rules', default='flow/waivers/openram_2kb_macro_drc_rules.txt')
    a = ap.parse_args()
    macro_rules = {l.rstrip('\n').split('\t', 1)[1] for l in open(a.rules) if l.strip() and not l.startswith('#')}
    origins = macro_origins(a.config)
    box = re.compile(r'^\s*([\d.]+)um\s+([\d.]+)um\s+([\d.]+)um\s+([\d.]+)um')
    waived, bad, cur = 0, collections.Counter(), None
    with open(a.report) as f:
        for l in f:
            m = box.match(l)
            if m:
                x = (float(m.group(1)) + float(m.group(3))) / 2; y = (float(m.group(2)) + float(m.group(4))) / 2
                inside = any(ox - 1 <= x <= ox + W + 1 and oy - 1 <= y <= oy + H + 1 for ox, oy in origins)
                if inside and cur in macro_rules: waived += 1
                else: bad[(cur, 'inside macro box' if inside else 'outside macros')] += 1
            elif l.strip() and not l.startswith(('-', '[')) : cur = l.strip()
    print(f'waived (macro-intrinsic): {waived}')
    print(f'integration errors      : {sum(bad.values())}  (raw boxes; Magic says divide by 3-4)')
    for (r, w), c in bad.most_common(): print(f'  {c:8d}  {r}  [{w}]')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
