#!/usr/bin/env python3
"""
Recreates the DropUnzip app icon:
- Black background with rounded-rect document shape
- Yellow/cream body, pink top section, blue folded corner
- Bold black outline style
- Zip/archive lines and a stylised 'a' glyph in the centre
Generates all required macOS icon sizes and builds an .icns file.
"""

from PIL import Image, ImageDraw, ImageFont
import math, os, subprocess, shutil

SIZE = 1024   # master canvas

def round_rect(draw, xy, radius, fill, outline=None, width=1):
    x0, y0, x1, y1 = xy
    draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill,
                            outline=outline, width=width)

def make_icon(size=1024):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d   = ImageDraw.Draw(img)
    s   = size
    sc  = s / 1024   # scale factor

    def p(v): return int(v * sc)   # scale a value

    STROKE   = p(28)
    BLACK    = (0, 0, 0, 255)
    YELLOW   = (255, 220, 120, 255)
    YELLOW2  = (255, 235, 160, 255)
    PINK     = (255, 160, 180, 255)
    PINK2    = (255, 190, 205, 255)
    BLUE     = (160, 200, 240, 255)
    WHITE    = (255, 255, 255, 255)
    BG       = (30, 30, 30, 255)

    # ── Background circle (dark, like the original) ──────────────────────
    d.ellipse([0, 0, s-1, s-1], fill=BG)

    # ── Document body ─────────────────────────────────────────────────────
    doc_l = p(180)
    doc_t = p(100)
    doc_r = p(860)
    doc_b = p(940)
    corner_cut = p(160)   # size of the folded corner
    radius = p(60)

    # Main body (yellow) — drawn as polygon with corner cut
    body_pts = [
        (doc_l + radius, doc_t),
        (doc_r - corner_cut, doc_t),
        (doc_r, doc_t + corner_cut),
        (doc_r, doc_b - radius),
        (doc_r - radius, doc_b),
        (doc_l + radius, doc_b),
        (doc_l, doc_b - radius),
        (doc_l, doc_t + radius),
    ]
    d.rounded_rectangle([doc_l, doc_t, doc_r, doc_b], radius=radius,
                         fill=YELLOW, outline=BLACK, width=STROKE)

    # ── Pink top section ──────────────────────────────────────────────────
    pink_bottom = p(360)
    # Clip pink to top of document
    pink_pts = [
        (doc_l + radius, doc_t),
        (doc_r - corner_cut, doc_t),
        (doc_r - corner_cut, pink_bottom),
        (doc_l, pink_bottom),
        (doc_l, doc_t + radius),
    ]
    d.polygon(pink_pts, fill=PINK)
    # Lighter pink highlight
    d.polygon([
        (doc_l + radius, doc_t),
        (doc_l + p(200), doc_t),
        (doc_l + p(200), pink_bottom),
        (doc_l + radius, pink_bottom),
        (doc_l, pink_bottom - p(40)),
        (doc_l, doc_t + radius),
    ], fill=PINK2)

    # ── Folded corner (blue triangle) ─────────────────────────────────────
    fold_pts = [
        (doc_r - corner_cut, doc_t),
        (doc_r, doc_t + corner_cut),
        (doc_r - corner_cut, doc_t + corner_cut),
    ]
    d.polygon(fold_pts, fill=BLUE)
    # Fold shadow line
    d.line([(doc_r - corner_cut, doc_t),
            (doc_r - corner_cut, doc_t + corner_cut),
            (doc_r, doc_t + corner_cut)],
           fill=BLACK, width=STROKE)

    # ── Horizontal lines (zip/archive lines) ─────────────────────────────
    line_x0 = doc_l + p(60)
    line_x1 = doc_r - p(60)
    line_w   = STROKE - p(4)
    for ly in [p(390), p(440)]:
        d.rounded_rectangle([line_x0, ly, line_x1, ly + line_w],
                             radius=line_w//2, fill=BLACK)

    # ── Stylised 'a' glyph in centre ─────────────────────────────────────
    cx, cy = s // 2, p(620)
    r_outer = p(140)
    r_inner = p(80)
    stroke_w = p(38)

    # Outer circle arc (open at bottom-right)
    d.arc([cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer],
          start=30, end=320, fill=BLACK, width=stroke_w)

    # Inner filled circle (hole)
    d.ellipse([cx - r_inner, cy - r_inner, cx + r_inner, cy + r_inner],
              fill=YELLOW2)
    d.arc([cx - r_inner, cy - r_inner, cx + r_inner, cy + r_inner],
          start=0, end=360, fill=BLACK, width=p(10))

    # Vertical stem on the right
    stem_x = cx + r_outer - stroke_w // 2
    d.rounded_rectangle([stem_x - stroke_w//2, cy - r_outer,
                          stem_x + stroke_w//2, cy + r_outer + p(30)],
                         radius=stroke_w//2, fill=BLACK)

    # ── Bottom lines ──────────────────────────────────────────────────────
    for ly in [p(800), p(850)]:
        x0 = doc_l + p(60)
        x1 = doc_r - p(180)
        d.rounded_rectangle([x0, ly, x1, ly + line_w],
                             radius=line_w//2, fill=BLACK)

    # ── Redraw document outline on top ───────────────────────────────────
    d.rounded_rectangle([doc_l, doc_t, doc_r, doc_b], radius=radius,
                         fill=None, outline=BLACK, width=STROKE)
    # Re-draw corner cut outline
    d.line([(doc_r - corner_cut, doc_t),
            (doc_r - corner_cut, doc_t + corner_cut),
            (doc_r, doc_t + corner_cut)],
           fill=BLACK, width=STROKE)

    # ── Pink/yellow divider line ──────────────────────────────────────────
    d.line([(doc_l, pink_bottom), (doc_r - corner_cut, pink_bottom)],
           fill=BLACK, width=STROKE)

    return img


# ── Generate all required macOS icon sizes ────────────────────────────────

iconset_dir = "DropUnzip/Assets.xcassets/AppIcon.appiconset"
os.makedirs(iconset_dir, exist_ok=True)

master = make_icon(1024)

sizes = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

for filename, px in sizes:
    resized = master.resize((px, px), Image.LANCZOS)
    out_path = os.path.join(iconset_dir, filename)
    resized.save(out_path, "PNG")
    print(f"  wrote {out_path}  ({px}x{px})")

# ── Update Contents.json ──────────────────────────────────────────────────
import json

contents = {
  "images": [
    {"idiom":"mac","scale":"1x","size":"16x16",  "filename":"icon_16x16.png"},
    {"idiom":"mac","scale":"2x","size":"16x16",  "filename":"icon_16x16@2x.png"},
    {"idiom":"mac","scale":"1x","size":"32x32",  "filename":"icon_32x32.png"},
    {"idiom":"mac","scale":"2x","size":"32x32",  "filename":"icon_32x32@2x.png"},
    {"idiom":"mac","scale":"1x","size":"128x128","filename":"icon_128x128.png"},
    {"idiom":"mac","scale":"2x","size":"128x128","filename":"icon_128x128@2x.png"},
    {"idiom":"mac","scale":"1x","size":"256x256","filename":"icon_256x256.png"},
    {"idiom":"mac","scale":"2x","size":"256x256","filename":"icon_256x256@2x.png"},
    {"idiom":"mac","scale":"1x","size":"512x512","filename":"icon_512x512.png"},
    {"idiom":"mac","scale":"2x","size":"512x512","filename":"icon_512x512@2x.png"},
  ],
  "info": {"author":"xcode","version":1}
}

with open(os.path.join(iconset_dir, "Contents.json"), "w") as f:
    json.dump(contents, f, indent=2)

print("Done — Contents.json updated")
