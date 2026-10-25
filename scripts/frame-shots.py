#!/usr/bin/env python3
"""Frames README screenshots as macOS windows on a card in Kore's blue: the window with rounded
corners, a hairline border and a soft shadow, on a rounded card that stands out on GitHub's
light and dark pages alike.

    scripts/frame-shots.py <storyline output> <out dir> <name>...

Needs Pillow. The window is reduced to a 256-colour palette first (the UI is flat colour, so
nothing visible is lost); the card's gradient and the shadow stay smooth around it.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

WIDTH = 1600
TOP, BOTTOM = (0x2B, 0x6A, 0x9C), (0x10, 0x2C, 0x45)   # hue 206°, the logo's blue, light to deep


def frame(src, dst):
    win = Image.open(src).convert("RGB")
    k = WIDTH * 0.84 / win.width
    win = win.resize((round(win.width * k), round(win.height * k)), Image.LANCZOS)
    win = win.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).convert("RGB")
    w, h = win.size
    radius = round(WIDTH * 0.012)
    left = (WIDTH - w) // 2
    top = round(WIDTH * 0.06)
    H = h + 2 * top

    # The card: a top-to-bottom gradient (rows of one colour compress to almost nothing).
    card = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        card.putpixel((0, y), tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))
    card = card.resize((WIDTH, H), Image.NEAREST)

    drop = round(WIDTH * 0.014)
    shape = Image.new("L", card.size, 0)
    ImageDraw.Draw(shape).rounded_rectangle((left, top + drop, left + w, top + h + drop), radius, fill=150)
    shade = shape.filter(ImageFilter.GaussianBlur(round(WIDTH * 0.02)))
    card = Image.composite(Image.new("RGB", card.size, (4, 10, 16)), card, shade)

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius, fill=255)
    card.paste(win, (left, top), mask)
    ImageDraw.Draw(card).rounded_rectangle((left, top, left + w - 1, top + h - 1), radius, outline=(70, 110, 145), width=2)

    out = card.convert("RGBA")
    corners = Image.new("L", card.size, 0)
    ImageDraw.Draw(corners).rounded_rectangle((0, 0, WIDTH - 1, H - 1), round(WIDTH * 0.02), fill=255)
    out.putalpha(corners)
    out.save(dst, optimize=True)


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    for name in sys.argv[3:]:
        frame(f"{src}/{name}.png", f"{out}/{name}.png")
