#!/usr/bin/env python3
"""Annotate a die-photo style GDS render (scripts/die_shot_render.py) with block regions (white outlines + labels), like vendor die shots.

  die_shot_annotate.py --img die_soft.png --def RUN/final/def/gpu_asic_top.def --netlist RUN/06-yosys-synthesis/gpu_asic_top.nl.v \
              --lef <std.lef> <sram.lef> --margin 0.01 --out die_shot.png --caption "..."
The render must cover the die bounding box plus `margin` of its size on each side (die_shot_render.py does). A render larger than --size is box-filtered down to it and
given more contrast and colour, so wiring density reads as colour.
"""
import argparse, collections, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import die_map as dm

GROUP = {
    'Register files': 'Register files', 'Core pipeline / control': 'Pipeline & control', 'Dispatch / DCR': 'Pipeline & control',
    'Fetcher': 'Pipeline & control', 'ALUs': 'Pipeline & control', 'Scheduler': 'Warp scheduler', 'PC / call stacks': 'PC / call stacks',
    'FP32 FMA units': 'FP32 FMA units', 'Load/store unit': 'Load/store unit', 'Shared memory': 'Shared memory',
    'D-cache (L1)': 'L1 D-cache', 'I-cache (L1)': 'L1 I-cache', 'L2 control / tags': 'L2 control / tags',
    'L2 data engine': 'L2 data path', 'L2 victim write buffer': 'L2 data path',
    'Memory controllers': 'Memory controllers', 'Host memory glue (Wishbone window)': 'Host interface',
}
MACRO = {'pmem': 'Program memory\n2 KB SRAM', 'dmem': 'Data memory\n2 KB SRAM', 'sram': 'L2 data array\n2 KB SRAM'}


def box_sum(a, r):
    """sum over a (2r+1)^2 window, zero padded"""
    p = np.pad(a, r); c = p.cumsum(0).cumsum(1); c = np.pad(c, ((1, 0), (1, 0)))
    k = 2 * r + 1
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


def components(mask):
    lab = np.zeros(mask.shape, int); n = 0; sizes = {}
    for y, x in zip(*np.nonzero(mask)):
        if lab[y, x]: continue
        n += 1; st = [(y, x)]; lab[y, x] = n; s = 0
        while st:
            cy, cx = st.pop(); s += 1
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                yy, xx = cy + dy, cx + dx
                if 0 <= yy < mask.shape[0] and 0 <= xx < mask.shape[1] and mask[yy, xx] and not lab[yy, xx]:
                    lab[yy, xx] = n; st.append((yy, xx))
        sizes[n] = s
    return lab, sizes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--img', required=True); ap.add_argument('--def', dest='deff', required=True)
    ap.add_argument('--netlist', required=True); ap.add_argument('--lef', nargs='+', required=True)
    ap.add_argument('--margin', type=float, default=0.01); ap.add_argument('--bin', type=float, default=12.0)
    ap.add_argument('--out', required=True); ap.add_argument('--caption', default='')
    ap.add_argument('--size', type=int, default=2400, help='output width in pixels')
    a = ap.parse_args()

    inst = dm.parse_netlist(a.netlist); lab, _ = dm.infer_labels(inst)
    sizes = dm.lef_sizes(a.lef); die, units, comps = dm.parse_def(a.deff)
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units
    groups = sorted(set(GROUP.values())); gi = {g: i for i, g in enumerate(groups)}
    B = a.bin; nx, ny = int(np.ceil(dw / B)), int(np.ceil(dh / B))
    acc = np.zeros((len(groups), ny, nx)); macros = []; inside = np.zeros((ny, nx), bool)
    cx0, cy0, cx1, cy1 = dw, dh, 0.0, 0.0                       # extent of the placed standard cells
    for name, ty, x, y, o in comps:
        if ty not in sizes: continue
        w, h = sizes[ty]
        if o in ('E', 'W', 'FE', 'FW'): w, h = h, w
        xu, yu = (x - die[0]) / units, (y - die[1]) / units
        if 'sram' in ty: macros.append((name, xu, yu, w, h)); continue
        j, i = min(int((yu + h / 2) // B), ny - 1), min(int((xu + w / 2) // B), nx - 1)
        cx0, cy0, cx1, cy1 = min(cx0, xu), min(cy0, yu), max(cx1, xu + w), max(cy1, yu + h)
        if '__fill' in ty or '__decap' in ty or '__tap' in ty: inside[j, i] = True; continue
        inside[j, i] = True
        g = GROUP.get(lab.get(name))
        if g: acc[gi[g], j, i] += w * h
    mac = np.zeros((ny, nx), bool)
    for _, x, y, w, h in macros:
        mac[int(y // B):int(np.ceil((y + h) / B)), int(x // B):int(np.ceil((x + w) / B))] = True
    # smooth: majority over a growing window, then a few rounds of mode filtering
    sm = np.stack([box_sum(acc[g], 3) for g in range(len(groups))])
    reg = np.where(sm.sum(0) > 0, sm.argmax(0), -1)
    for _ in range(4):
        oh = np.stack([box_sum((reg == g).astype(float), 3) for g in range(len(groups))])
        reg = np.where(oh.sum(0) > 0, oh.argmax(0), -1)
    core = box_sum(inside.astype(float), 1) >= 3          # bins well inside the placed core area
    reg[~core | mac] = -1

    # ---- drawing
    im = Image.open(a.img).convert('RGB')
    if im.size[0] > a.size:
        im = im.resize((a.size, round(im.size[1] * a.size / im.size[0])), Image.BOX)
        im = ImageEnhance.Color(ImageEnhance.Contrast(im).enhance(1.6)).enhance(1.5)
    W, H = im.size
    m = a.margin * max(dw, dh); s = W / (dw + 2 * m)
    X = lambda x: (x + m) * s; Y = lambda y: (dh + m - y) * s
    big = np.kron(reg, np.ones((1, 1), int))
    # boundary pixels: compute at bin resolution, draw as short white segments between differing bins
    ov = Image.new('RGBA', im.size, (0, 0, 0, 0)); d = ImageDraw.Draw(ov)
    LINE = (255, 255, 255, 240); SHADOW = (0, 0, 0, 170); lw = max(3, int(W / 800))
    segs = []
    for j in range(ny):
        for i in range(nx):
            r = reg[j, i]
            if r < 0: continue
            if i + 1 < nx and reg[j, i + 1] >= 0 and reg[j, i + 1] != r:
                xx = X((i + 1) * B); segs.append([xx, Y(j * B), xx, Y((j + 1) * B)])
            if j + 1 < ny and reg[j + 1, i] >= 0 and reg[j + 1, i] != r:
                yy = Y((j + 1) * B); segs.append([X(i * B), yy, X((i + 1) * B), yy])
    clipx = lambda v: min(max(v, X(cx0)), X(cx1)); clipy = lambda v: min(max(v, Y(cy1)), Y(cy0))
    segs = [[clipx(a0), clipy(b0), clipx(a1), clipy(b1)] for a0, b0, a1, b1 in segs]
    for sg in segs: d.line(sg, fill=SHADOW, width=lw + 4)
    for sg in segs: d.line(sg, fill=LINE, width=lw)
    for name, x, y, w, h in macros:
        d.rectangle([X(x), Y(y + h), X(x + w), Y(y)], outline=SHADOW, width=lw + 5)
        d.rectangle([X(x), Y(y + h), X(x + w), Y(y)], outline=LINE, width=lw + 1)
    try:
        f = ImageFont.truetype('DejaVuSans-Bold.ttf', int(W / 62)); fs = ImageFont.truetype('DejaVuSans.ttf', int(W / 90))
    except OSError:
        f = fs = ImageFont.load_default()

    def tag(cx, cy, text):
        bb = d.multiline_textbbox((cx, cy), text, font=f, anchor='mm', align='center')
        pad = int(W / 220)
        d.rectangle([bb[0] - pad, bb[1] - pad, bb[2] + pad, bb[3] + pad], fill=(255, 255, 255, 235))
        d.multiline_text((cx, cy), text, font=f, fill=(15, 15, 18, 255), anchor='mm', align='center')

    for g in range(len(groups)):
        comp, sz = components(reg == g)
        if not sz: continue
        best = max(sz, key=sz.get)
        if sz[best] * B * B < 12000: continue                      # too small to label (<0.012 mm2)
        ys, xs = np.nonzero(comp == best); cy, cx = ys.mean(), xs.mean()
        k = np.argmin((ys - cy) ** 2 + (xs - cx) ** 2)               # a point inside the region near its centroid
        tag(X((xs[k] + 0.5) * B), Y((ys[k] + 0.5) * B), groups[g])
    for name, x, y, w, h in macros:
        key = next((k for k in MACRO if k in name), None)
        tag(X(x + w / 2), Y(y + h / 2), MACRO.get(key, name))
    # scale bar + caption
    x0, y0 = X(dw - 560), Y(-m * 0.45)
    d.line([x0, y0, x0 + 500 * s, y0], fill=LINE, width=lw + 2)
    d.text((x0 + 250 * s, y0 - lw * 2), '500 µm', font=fs, fill=LINE, anchor='mb')
    im = Image.alpha_composite(im.convert('RGBA'), ov).convert('RGB')
    if a.caption:
        cap = Image.new('RGB', (W, int(W / 30)), (12, 12, 14)); dc = ImageDraw.Draw(cap)
        dc.text((int(W / 80), cap.size[1] // 2), a.caption, font=fs, fill=(225, 225, 225), anchor='lm')
        out = Image.new('RGB', (W, H + cap.size[1])); out.paste(im, (0, 0)); out.paste(cap, (0, H)); im = out
    im.save(a.out); print('wrote', a.out, im.size)


if __name__ == '__main__':
    main()
