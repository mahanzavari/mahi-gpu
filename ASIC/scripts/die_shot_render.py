# KLayout batch render of a final GDS, die-photo style (annotated by scripts/die_shot_annotate.py; `make die-shot`).
# Metals are drawn opaque, bottom to top, at high resolution; the caller downsamples with a box filter so each pixel
# averages many wires and wiring density shows as colour, as in a die photograph.
#   klayout -b -zz -r die_shot_render.py -rd gds=<gds> -rd lyp=<sky130A.lyp> -rd out=<png> -rd px=4000 -rd style=lyp|photo
import pya

gds, out, px, style = gds, out, int(px), style
lv = pya.LayoutView()
idx = lv.load_layout(gds, False)
ly = lv.cellview(idx).layout()
top = ly.top_cell()
lv.set_config("background-color", "#0b0b0d")
lv.set_config("grid-visible", "false")
lv.set_config("text-visible", "false")
lv.set_config("default-text-size", "0")

if style == "lyp":
    lv.load_layer_props(lyp)
else:
    stack = [  # (layer, datatype, colour, dither): opaque, bottom to top
        (65, 20, 0x1f4d2b, 0),   # diff
        (66, 20, 0x8c2f2a, 0),   # poly
        (67, 20, 0x5b3f86, 0),   # li1
        (68, 20, 0x2a5f9e, 0),   # met1
        (69, 20, 0x2c9a8c, 0),   # met2
        (70, 20, 0xb38a2e, 0),   # met3
        (71, 20, 0xd4743a, 0),   # met4
        (72, 20, 0xa88a48, 0),   # met5
    ]
    lv.clear_layers()
    for l, d, c, dith in stack:
        p = pya.LayerProperties()
        p.source = f"{l}/{d}@1"
        p.fill_color = c; p.frame_color = c
        p.dither_pattern = dith
        p.width = 0
        lv.insert_layer(lv.end_layers(), p)

lv.max_hier()
b = top.dbbox()
m = max(b.width(), b.height()) * 0.01
lv.zoom_box(pya.DBox(b.left - m, b.bottom - m, b.right + m, b.top + m))
lv.save_image(out, px, px)
print("saved", out, b)
