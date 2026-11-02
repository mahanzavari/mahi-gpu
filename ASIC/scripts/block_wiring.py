#!/usr/bin/env python3
"""Block-to-block wiring of a placed design: which blocks talk to which, and how much wire that costs.

  block_wiring.py --netlist RUN/06-yosys-synthesis/gpu_asic_top.nl.v --def RUN/final/def/gpu_asic_top.def \
                  --lef <std-cell.lef> <macro.lef> --out-matrix wiring_matrix.png --out-map wiring_map.png

Blocks are the inferred labels of die_map.py (same caveats), plus each SRAM macro and the IO pins as their own nodes.
For every net of the synthesized netlist (global nets above --max-fanout, i.e. clock/reset/enables, are skipped):
  nets[A,B] += 1 for every pair of blocks the net touches;
  wire[A,B] += its half-perimeter wirelength in the final placement, split evenly over the pairs it touches.
The matrix shows the net counts (the floorplan's adjacency wish-list); the map draws block centroids joined by lines
whose width is the net count and whose shade is the wire it costs, so long thick lines are what the floorplan should
shorten. Also printed: for every macro pin edge, which blocks its nets go to (input for macro orientation).
"""
import argparse, collections, itertools, math, os, re, sys
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import die_map as dm

RAMP = ['#f7f9fc', '#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95', '#0d366b']
INK, MUTED, SURFACE, GRID = (26, 26, 25), (110, 110, 105), (252, 252, 250), (225, 225, 220)
IO = 'IO pins'


def hex2rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def ramp(t):
    t = min(max(t, 0.0), 1.0) * (len(RAMP) - 1); i = min(int(t), len(RAMP) - 2); f = t - i
    a, b = hex2rgb(RAMP[i]), hex2rgb(RAMP[i + 1])
    return tuple(round(a[k] + (b[k] - a[k]) * f) for k in range(3))


def norm(n):
    return n.lstrip('\\').replace('\\', '').strip()


def def_pins(path):
    txt = open(path).read(); sec = txt[txt.index('\nPINS'):txt.index('END PINS')]
    pins = {}
    for st in sec.split(';')[1:]:
        m = re.search(r'\+\s+NET\s+(\S+)', st); p = re.search(r'(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)', st)
        u = re.search(r'\+\s+USE\s+(\w+)', st)
        if m and p and not (u and u.group(1) in ('POWER', 'GROUND')): pins[norm(m.group(1))] = (int(p.group(1)), int(p.group(2)))
    return pins


def lef_pin_sides(lef, macro):
    """pin name (bus bit stripped) -> side of the macro its first shape sits on."""
    t = open(lef).read(); m = re.search(r'MACRO %s(.*?)(?:END %s|END LIBRARY|\Z)' % (re.escape(macro), re.escape(macro)), t, re.S)
    body = m.group(1); W, H = map(float, re.search(r'SIZE ([\d.]+) BY ([\d.]+)', body).groups())
    sides = {}
    for pm in re.finditer(r'PIN (\S+)(.*?)END \1', body, re.S):
        r = re.search(r'RECT\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)', pm.group(2))
        if not r: continue
        x, y = (float(r.group(1)) + float(r.group(3))) / 2, (float(r.group(2)) + float(r.group(4))) / 2
        d = {'left': x, 'right': W - x, 'bottom': y, 'top': H - y}
        sides[pm.group(1)] = min(d, key=d.get)
    return sides


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--netlist', required=True); ap.add_argument('--def', dest='deff', required=True)
    ap.add_argument('--lef', nargs='+', required=True)
    ap.add_argument('--out-matrix', required=True); ap.add_argument('--out-map', required=True)
    ap.add_argument('--max-fanout', type=int, default=64); ap.add_argument('--title', default='Block wiring')
    a = ap.parse_args()

    inst = dm.parse_netlist(a.netlist); lab, _ = dm.infer_labels(inst)
    sizes = dm.lef_sizes(a.lef); die, units, comps = dm.parse_def(a.deff)
    pos, macros = {}, {}
    for name, ty, x, y, o in comps:
        w, h = sizes.get(ty, (0, 0))
        if o in ('E', 'W', 'FE', 'FW'): w, h = h, w
        pos[norm(name)] = (x / units + w / 2, y / units + h / 2)
        if 'sram' in ty: macros[norm(name)] = (ty, x / units, y / units, w, h, o)
    pins = {n: (x / units, y / units) for n, (x, y) in def_pins(a.deff).items()}
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units
    def edge(x, y):
        dd = {'W': x, 'E': dw - x, 'S': y, 'N': dh - y}; return f'{IO} ({min(dd, key=dd.get)})'
    pin_blk = {n: edge(*xy) for n, xy in pins.items()}

    block = {}
    for n, (ty, _) in inst.items():
        k = norm(n)
        if 'sram' in ty: block[k] = dm.macro_label(k)
        elif n in lab: block[k] = lab[n]
    sram_sides = {}
    for k, (ty, *_r) in macros.items():
        for lf in a.lef:
            if ty in open(lf).read(): sram_sides[ty] = lef_pin_sides(lf, ty)

    net_cells = collections.defaultdict(list)          # net -> [(cell key, pin)]
    for n, (ty, pinmap) in inst.items():
        for p, net in pinmap.items():
            bits = [(p, net)]
            if net.strip().startswith('{'):                  # bus concatenation (macro pins): MSB first
                parts = [x.strip() for x in net.strip()[1:-1].split(',')]
                bits = [(f'{p}[{len(parts) - 1 - i}]', x) for i, x in enumerate(parts)]
            for pb, nb in bits:
                if nb and not nb.startswith(("1'", "0'")): net_cells[norm(nb)].append((norm(n), pb))
    nets, wire = collections.Counter(), collections.Counter()
    side_use = collections.defaultdict(collections.Counter)      # (macro label, side) -> block -> nets
    for net, cl in net_cells.items():
        if len(cl) > a.max_fanout: continue
        blks = {block[c] for c, _ in cl if c in block}
        pts = [pos[c] for c, _ in cl if c in pos]
        if net in pins: blks.add(pin_blk[net]); pts.append(pins[net])
        if len(blks) < 2: continue
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        hpwl = (max(xs) - min(xs) + max(ys) - min(ys)) if pts else 0
        pairs = list(itertools.combinations(sorted(blks), 2))
        for pr in pairs: nets[pr] += 1; wire[pr] += hpwl / len(pairs)
        for c, p in cl:
            if c in macros:
                sd = sram_sides[macros[c][0]]; side = sd.get(p, sd.get(re.sub(r'\[\d+\]', '', p), '?')); ml = block[c]
                for b in blks - {ml}: side_use[(ml, side)][b] += 1

    # ---- centroids (median of each block's placed cells; macros at their centre; IO at its pins' mean)
    pts = collections.defaultdict(list)
    for k, b in block.items():
        if k in pos: pts[b].append(pos[k])
    cen = {b: tuple(np.median(np.array(v), 0)) for b, v in pts.items()}
    for e in set(pin_blk.values()): cen[e] = tuple(np.median(np.array([pins[n] for n, b in pin_blk.items() if b == e]), 0))
    for k, (ty, x, y, w, h, o) in macros.items(): cen[block[k]] = (x + w / 2, y + h / 2)

    order = [l for _, l in dm.HIER if l in cen] + sorted({dm.macro_label(k) for k in macros}) + sorted(set(pin_blk.values()))
    order = list(dict.fromkeys(order))
    tot_n = collections.Counter(); [tot_n.update({p[0]: v, p[1]: v}) for p, v in nets.items()]
    order = [b for b in order if tot_n[b] > 0]

    # ---- text report
    print('Top block pairs by wire spent between them (HPWL, mm):')
    for (x, y), wv in wire.most_common(15):
        dist = (abs(cen[x][0] - cen[y][0]) + abs(cen[x][1] - cen[y][1])) / 1000
        print(f'  {wv / 1000:7.1f} mm  {nets[(x, y)]:6d} nets  centroids {dist:4.2f} mm apart   {x}  <->  {y}')
    print('Macro pin edges -> blocks (nets):')
    for (ml, side), c in sorted(side_use.items()):
        print(f'  {ml:14s} {side:6s} ' + ', '.join(f'{b} {v}' for b, v in c.most_common(4)))

    f, f_m, f_s = dm.fonts()
    short = lambda b: b.replace(' (Wishbone window)', '').replace(' / control', '').replace(' / tags', '')

    # ---- matrix
    n = len(order); cell, lw, top = 46, 300, 330
    img = Image.new('RGB', (lw + n * cell + 40, top + n * cell + 90), SURFACE); d = ImageDraw.Draw(img)
    d.text((20, 18), a.title + ': nets between blocks', fill=INK, font=f)
    mx = max(nets.values()); lg = lambda v: math.log10(1 + v) / math.log10(1 + mx)
    for i, bi in enumerate(order):
        d.text((lw - 10 - d.textlength(short(bi), font=f_s), top + i * cell + cell / 2 - 9), short(bi), fill=INK, font=f_s)
        tx = Image.new('RGBA', (300, 24), SURFACE + (0,)); ImageDraw.Draw(tx).text((0, 2), short(bi), fill=INK, font=f_s)
        tx = tx.rotate(60, expand=True); img.paste(tx, (int(lw + i * cell + cell / 2 - 6), top - tx.size[1] - 6), tx)
        for j, bj in enumerate(order):
            x0, y0 = lw + j * cell, top + i * cell
            v = 0 if i == j else nets.get(tuple(sorted((bi, bj))), 0)
            d.rectangle([x0 + 1, y0 + 1, x0 + cell - 1, y0 + cell - 1], fill=ramp(lg(v)) if i != j else GRID)
            if v: d.text((x0 + cell / 2, y0 + cell / 2), f'{v}' if v < 10000 else f'{v // 1000}k', fill=INK if lg(v) < 0.55 else SURFACE, font=f_s, anchor='mm')
    d.text((lw, top + n * cell + 16), 'Nets that connect each pair of blocks (synthesized netlist).', fill=MUTED, font=f_s)
    d.text((lw, top + n * cell + 36), f'Clock/reset and other nets with fanout > {a.max_fanout} skipped; shade is log-scaled.', fill=MUTED, font=f_s)
    img.save(a.out_matrix)

    # ---- die map with wiring lines
    px = 1500; s = px / dw; H = int(dh * s); m, tp, leg = 24, 64, 560
    img = Image.new('RGB', (px + 2 * m + leg, H + tp + 2 * m), SURFACE); d = ImageDraw.Draw(img, 'RGBA')
    X = lambda x: m + x * s; Y = lambda y: tp + H - y * s
    d.rectangle([X(0), Y(dh), X(dw), Y(0)], outline=MUTED, fill=(244, 244, 240))
    for k, b in block.items():                                   # faint block footprint
        if k in pos and b in dm.PALETTE:
            x, y = pos[k]; c = dm.PALETTE[b]; d.point((X(x), Y(y)), fill=c + (90,))
    for k, (ty, x, y, w, h, o) in macros.items():
        d.rectangle([X(x), Y(y + h), X(x + w), Y(y)], fill=(60, 60, 66, 255), outline=INK)
        d.text((X(x) + 6, Y(y + h) + 4), block[k], fill=SURFACE, font=f_s)
    wmax = max(wire.values())
    for (x, y), v in sorted(nets.items(), key=lambda kv: wire[kv[0]]):
        if v < 32: continue
        w = max(1, int(2 + 14 * math.log10(v) / math.log10(mx)))
        d.line([X(cen[x][0]), Y(cen[x][1]), X(cen[y][0]), Y(cen[y][1])], fill=ramp(0.25 + 0.75 * wire[(x, y)] / wmax) + (235,), width=w)
    for n, (x, y) in pins.items():                               # IO pins as ticks on the die edge
        d.rectangle([X(x) - 3, Y(y) - 3, X(x) + 3, Y(y) + 3], fill=INK + (255,))
    for b, (x, y) in cen.items():
        c = dm.PALETTE.get(b, (60, 60, 66)) if not b.startswith(IO) else INK
        d.ellipse([X(x) - 9, Y(y) - 9, X(x) + 9, Y(y) + 9], fill=c + (255,), outline=SURFACE, width=2)
        d.text((X(x) + 12, Y(y) - 8), short(b), fill=INK, font=f_s)
    d.text((m, 18), a.title + ': wiring between blocks', fill=INK, font=f)
    lx, ly = px + 2 * m, tp
    d.text((lx, ly), 'Line width = nets between the blocks', fill=INK, font=f_s); ly += 20
    d.text((lx, ly), 'Line shade = wire they use (HPWL)', fill=INK, font=f_s); ly += 26
    for k in range(240): d.line([lx + k, ly, lx + k, ly + 14], fill=ramp(0.25 + 0.75 * k / 239))
    d.text((lx, ly + 18), '0', fill=MUTED, font=f_s); d.text((lx + 240, ly + 18), f'{wmax / 1000:.0f} mm', fill=MUTED, font=f_s, anchor='ra')
    ly += 52; d.text((lx, ly), 'Most wire between blocks', fill=INK, font=f_s); ly += 22
    for (x, y), wv in wire.most_common(14):
        d.text((lx, ly), f'{wv / 1000:5.1f} mm', fill=INK, font=f_s)
        d.text((lx + 96, ly), f'{short(x)} - {short(y)}', fill=MUTED, font=f_s); ly += 19
    ly += 10; d.text((lx, ly), 'Dots: block centroid (median cell)', fill=MUTED, font=f_s); ly += 18
    d.text((lx, ly), 'Black squares: IO pins; IO nodes per die edge', fill=MUTED, font=f_s); ly += 18
    d.text((lx, ly), 'Pairs with fewer than 32 nets not drawn', fill=MUTED, font=f_s)
    img.save(a.out_map)
    print(f'wrote {a.out_matrix} and {a.out_map}')


if __name__ == '__main__':
    main()
