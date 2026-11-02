#!/usr/bin/env python3
"""Routing-congestion heat map of a run, from the global router's route guides.

  congestion_map.py --guide RUN/39-openroad-globalrouting/after_grt.guide --def RUN/final/def/gpu_asic_top.def \
                    --lef <macro.lef> [--drc RUN/45-openroad-detailedrouting/gpu_asic_top.drc] --out congestion.png

Every guide rectangle on a metal layer is one net crossing those gcells on that layer, so it takes about one track per
gcell. Demand per gcell is summed over met1-met5 and divided by the track supply (gcell / pitch, less the global
router's GRT_ADJUSTMENT); met1-met3 are taken as fully blocked over the SRAM macros. This is an estimate of the same
quantity the global router balances (it ignores per-cell pin blockages and the PDN), good for finding hot spots, not
for exact overflow counts - those are in the global-routing log ("Final congestion report").
"""
import argparse, os, re, sys
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import die_map as dm

PITCH = {'met1': 0.34, 'met2': 0.46, 'met3': 0.68, 'met4': 0.92, 'met5': 3.40}     # sky130 routing track pitch, um
RAMP = ['#f7f9fc', '#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95', '#0d366b']  # 0 -> 100% use
OVER = '#d03b3b'                                                                                   # > 100% and DRC
INK, MUTED, SURFACE = (26, 26, 25), (110, 110, 105), (252, 252, 250)


def hex2rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def colour(u):
    if u > 1.0: return hex2rgb(OVER)
    f = max(0.0, u) * (len(RAMP) - 1); i = min(int(f), len(RAMP) - 2); t = f - i
    a, b = hex2rgb(RAMP[i]), hex2rgb(RAMP[i + 1])
    return tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--guide', required=True); ap.add_argument('--def', dest='deff', required=True)
    ap.add_argument('--lef', nargs='+', required=True, help='macro LEF(s), for the macro outlines')
    ap.add_argument('--drc', help='detailed-routing .drc report to overlay'); ap.add_argument('--out', required=True)
    ap.add_argument('--bin', type=int, default=4, help='gcells per heat-map pixel block (default 4)')
    ap.add_argument('--adjust', type=float, default=0.15, help='GRT_ADJUSTMENT used by the run')
    ap.add_argument('--px', type=int, default=1600); ap.add_argument('--title', default='Routing congestion')
    a = ap.parse_args()

    die, units, comps = dm.parse_def(a.deff)
    sizes = dm.lef_sizes(a.lef)
    rects = []                                                     # (layer, x0, y0, x1, y1) in dbu
    with open(a.guide) as f:
        for line in f:
            p = line.split()
            if len(p) == 5 and p[4] in PITCH: rects.append((p[4], int(p[0]), int(p[1]), int(p[2]), int(p[3])))
    g = min(r[3] - r[1] for r in rects[:20000])                    # gcell size = smallest guide edge
    nx, ny = -(-(die[2] - die[0]) // g), -(-(die[3] - die[1]) // g)
    dem = {L: np.zeros((ny, nx)) for L in PITCH}
    for L, x0, y0, x1, y1 in rects:
        dem[L][(y0 - die[1]) // g:(y1 - die[1]) // g, (x0 - die[0]) // g:(x1 - die[0]) // g] += 1
    cap = {L: np.full((ny, nx), (g / units) / PITCH[L] * (1 - a.adjust)) for L in PITCH}
    macros = []
    for name, ty, x, y, o in comps:
        if 'sram' not in ty or ty not in sizes: continue
        w, h = sizes[ty]
        if o in ('E', 'W', 'FE', 'FW'): w, h = h, w
        x0, y0 = (x - die[0]) / units, (y - die[1]) / units; macros.append((name, x0, y0, w, h))
        sl = (slice(int(y0 * units // g), int((y0 + h) * units // g) + 1), slice(int(x0 * units // g), int((x0 + w) * units // g) + 1))
        for L in ('met1', 'met2', 'met3'): cap[L][sl] = 0
        cap['met4'][sl] *= 0.5
    D = sum(dem.values()); C = sum(cap.values())
    b = a.bin; ny2, nx2 = ny // b, nx // b
    Db = D[:ny2 * b, :nx2 * b].reshape(ny2, b, nx2, b).sum((1, 3))
    Cb = C[:ny2 * b, :nx2 * b].reshape(ny2, b, nx2, b).sum((1, 3))
    U = np.where(Cb > 0, Db / np.maximum(Cb, 1e-9), 0)
    lay = {L: dem[L].sum() / max(cap[L].sum(), 1) for L in PITCH}
    hot = (U > 0.8).sum()

    # ---- drawing
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units
    s = a.px / dw; W, H = a.px, int(dh * s)
    m, top, leg = 24, 64, 360
    img = Image.new('RGB', (W + 2 * m + leg, H + top + m + 40), SURFACE)
    d = ImageDraw.Draw(img); f, _, f_s = dm.fonts()
    heat = np.zeros((ny2, nx2, 3), np.uint8)
    for j in range(ny2):
        for i in range(nx2): heat[ny2 - 1 - j, i] = colour(U[j, i])
    hm = Image.fromarray(heat).resize((int(nx2 * b * g / units * s), int(ny2 * b * g / units * s)), Image.NEAREST)
    img.paste(hm, (m, top + H - hm.size[1]))
    Y = lambda y: top + H - y * s
    for name, x0, y0, w, h in macros:
        d.rectangle([m + x0 * s, Y(y0 + h), m + (x0 + w) * s, Y(y0)], outline=INK, width=2)
        d.text((m + x0 * s + 6, Y(y0 + h) + 4), dm.macro_label(name), fill=INK, font=f_s)
    d.rectangle([m, top, m + W, top + H], outline=MUTED, width=1)
    ndrc = 0
    if a.drc and os.path.exists(a.drc):
        for mm in re.finditer(r'bbox = \(\s*([\d.]+),\s*([\d.]+)\s*\) - \(\s*([\d.]+),\s*([\d.]+)', open(a.drc).read()):
            cx, cy = (float(mm[1]) + float(mm[3])) / 2, (float(mm[2]) + float(mm[4])) / 2; ndrc += 1
            d.ellipse([m + cx * s - 5, Y(cy) - 5, m + cx * s + 5, Y(cy) + 5], outline=hex2rgb(OVER), width=2)
    d.text((m, 18), a.title, fill=INK, font=f)

    # ---- legend: colour bar, per-layer use, DRC count
    lx, ly = W + 2 * m, top
    d.text((lx, ly), 'Estimated track use per gcell', fill=INK, font=f_s); ly += 26
    for k in range(200):
        d.line([lx, ly + 200 - k, lx + 24, ly + 200 - k], fill=colour(k / 199))
    for v in (0, 0.25, 0.5, 0.75, 1.0):
        d.text((lx + 32, ly + 200 - v * 199 - 7), f'{int(v * 100)}%', fill=MUTED, font=f_s)
    ly += 214
    d.rectangle([lx, ly, lx + 24, ly + 14], fill=hex2rgb(OVER)); d.text((lx + 32, ly - 1), 'over 100% (overflow)', fill=INK, font=f_s)
    ly += 24
    if a.drc:
        d.ellipse([lx + 6, ly + 1, lx + 18, ly + 13], outline=hex2rgb(OVER), width=2)
        d.text((lx + 32, ly - 1), f'routing DRC marker ({ndrc})', fill=INK, font=f_s); ly += 24
    d.rectangle([lx, ly, lx + 24, ly + 14], outline=INK, width=2); d.text((lx + 32, ly - 1), 'SRAM macro', fill=INK, font=f_s)
    ly += 40
    d.text((lx, ly), 'Average use by layer', fill=INK, font=f_s); ly += 22
    for L, v in lay.items():
        d.text((lx, ly), f'{L}', fill=MUTED, font=f_s); d.rectangle([lx + 60, ly + 3, lx + 60 + 200, ly + 13], outline=MUTED)
        d.rectangle([lx + 60, ly + 3, lx + 60 + 200 * min(v, 1), ly + 13], fill=hex2rgb(RAMP[5]))
        d.text((lx + 268, ly), f'{100 * v:.0f}%', fill=INK, font=f_s); ly += 20
    ly += 16
    d.text((lx, ly), f'gcell {g / units:.1f} um, shown in {b}x{b} blocks', fill=MUTED, font=f_s); ly += 18
    d.text((lx, ly), f'blocks above 80%: {hot}', fill=MUTED, font=f_s)
    img.save(a.out)
    print(f'wrote {a.out}: gcell {g / units} um, {len(rects)} guide rects, blocks >80%: {hot}, '
          + ', '.join(f'{L} {100 * v:.0f}%' for L, v in lay.items()) + (f', DRC markers {ndrc}' if a.drc else ''))


if __name__ == '__main__':
    main()
