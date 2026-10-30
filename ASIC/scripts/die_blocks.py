#!/usr/bin/env python3
"""One panel per block: each RTL block's (inferred) cells highlighted on a dim copy of the whole die.

  die_blocks.py --def RUN/31-openroad-detailedrouting/gpu_asic_top.def --netlist RUN/06-yosys-synthesis/gpu_asic_top.nl.v \
                --lef <std-cell.lef> <macro.lef> --out docs/figures/die_blocks.png

Companion to die_map.py (same inference, same caveats): the combined map blends blocks that the flat placer interleaves;
here each block is shown on its own so its footprint is readable. The memory-side blocks (caches, L2 pieces, controllers,
glue) also get a combined panel, since they are one tightly coupled cluster around the SRAM macros.
"""
import argparse, collections, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import die_map as dm

MEM = ['D-cache (L1)', 'I-cache (L1)', 'L2 control / tags', 'L2 data engine', 'L2 victim write buffer',
       'Memory controllers', 'Host memory glue (Wishbone window)']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--def', dest='deff', required=True); ap.add_argument('--netlist', required=True)
    ap.add_argument('--lef', nargs='+', required=True); ap.add_argument('--out', required=True)
    ap.add_argument('--panel', type=int, default=560, help='panel size in pixels'); ap.add_argument('--cols', type=int, default=4)
    ap.add_argument('--title', default='')
    a = ap.parse_args()

    inst = dm.parse_netlist(a.netlist)
    lab, _ = dm.infer_labels(inst)
    sizes = dm.lef_sizes(a.lef)
    die, units, comps = dm.parse_def(a.deff)
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units
    P = a.panel; sc = P / max(dw, dh)
    H, W = int(dh * sc) + 1, int(dw * sc) + 1

    cells, macros = [], []                                   # cells: (label|None, x, y, w, h)
    for name, ty, x, y, o in comps:
        if ty not in sizes: continue
        w, h = sizes[ty]
        if o in ('E', 'W', 'FE', 'FW'): w, h = h, w
        xu, yu = (x - die[0]) / units, (y - die[1]) / units
        if 'sram' in ty: macros.append((name, xu, yu, w, h)); continue
        if '__fill' in ty or '__decap' in ty or '__tap' in ty: continue
        cells.append((lab.get(name), xu, yu, w, h))

    def raster(select):
        """grey context for every cell + bright colour for the selected ones"""
        img = np.zeros((H, W, 3), np.uint8); img[:] = (16, 16, 20)
        def paint(x, y, w, h, col):
            x0, x1 = int(x * sc), max(int((x + w) * sc), int(x * sc) + 1); y0, y1 = int(y * sc), max(int((y + h) * sc), int(y * sc) + 1)
            img[max(H - y1, 0):max(H - y0, 0), max(x0, 0):min(x1, W)] = col
        for l, x, y, w, h in cells:
            if not select(l): paint(x, y, w, h, (58, 58, 66))
        for name, x, y, w, h in macros:
            paint(x, y, w, h, (34, 34, 40))
            for e in ((x, y, w, 1.2), (x, y + h - 1.2, w, 1.2), (x, y, 1.2, h), (x + w - 1.2, y, 1.2, h)): paint(*e, (120, 120, 130))
        n = 0
        for l, x, y, w, h in cells:
            if select(l): paint(x, y, w, h, COL[l if l in dm.PALETTE else None]); n += 1
        return img, n

    COL = {k: tuple(min(255, int(v * 1.0)) for v in c) for k, c in dm.PALETTE.items()}; COL[None] = (200, 200, 200)
    counts = collections.Counter(l for l, *_ in cells if l)
    blocks = [b for b, _ in counts.most_common()]
    panels = [('Memory subsystem (7 blocks together)', lambda l: l in MEM, (255, 255, 255))] + \
             [(b, (lambda bb: lambda l: l == bb)(b), dm.PALETTE[b]) for b in blocks]
    f_big, f, f_s = dm.fonts()
    cols = a.cols; rows = (len(panels) + cols - 1) // cols
    cw, ch = W + 20, H + 64
    canvas = Image.new('RGB', (cols * cw + 20, rows * ch + 90), (250, 250, 250)); d = ImageDraw.Draw(canvas)
    d.text((20, 22), a.title or 'Die map - one panel per block', fill=(20, 20, 20), font=f_big)
    total = sum(counts.values())
    for k, (name, sel, col) in enumerate(panels):
        img, n = raster(sel)
        im = Image.fromarray(img); x0 = 20 + (k % cols) * cw; y0 = 80 + (k // cols) * ch
        canvas.paste(im, (x0, y0 + 50)); d.rectangle([x0 - 1, y0 + 49, x0 + W, y0 + 50 + H], outline=(0, 0, 0))
        d.rectangle([x0, y0 + 6, x0 + 20, y0 + 26], fill=col, outline=(0, 0, 0))
        d.text((x0 + 28, y0 + 6), name, fill=(20, 20, 20), font=f)
        d.text((x0 + 28, y0 + 24), f'{n:,} cells ({100 * n / total:.1f}%)', fill=(90, 90, 90), font=f_s)
    d.text((20, rows * ch + 84 - 14), 'Highlighted = cells attributed to the block (inferred from register names + netlist connectivity); grey = all other cells; dark boxes = SRAM macros.',
           fill=(70, 70, 70), font=f_s)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True); canvas.save(a.out)
    print(f'wrote {a.out} ({canvas.size[0]}x{canvas.size[1]}), {len(panels)} panels', file=sys.stderr)


if __name__ == '__main__':
    main()
