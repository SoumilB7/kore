#!/usr/bin/env python3
"""Frames README screenshots as macOS windows: rounded corners, a hairline border and a soft
shadow, on a transparent ground that sits on GitHub's light and dark pages alike.

    scripts/frame-shots.py <storyline output> <out dir> <name>...

Needs Pillow. The window is reduced to a 256-colour palette first (the UI is flat colour, so
nothing visible is lost) and the shadow stays smooth around it.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

WIDTH = 1600


def frame(src, dst):
    win = Image.open(src).convert("RGB")
    k = WIDTH * 0.86 / win.width
    win = win.resize((round(win.width * k), round(win.height * k)), Image.LANCZOS)
    win = win.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).convert("RGBA")
    w, h = win.size
    radius = round(WIDTH * 0.012)
    left, top, bottom = (WIDTH - w) // 2, round(WIDTH * 0.03), round(WIDTH * 0.06)
    canvas = Image.new("RGBA", (WIDTH, h + top + bottom), (0, 0, 0, 0))

    drop = round(WIDTH * 0.012)
    shape = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(shape).rounded_rectangle((left, top + drop, left + w, top + h + drop), radius, fill=110)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.putalpha(shape.filter(ImageFilter.GaussianBlur(round(WIDTH * 0.018))))
    canvas = Image.alpha_composite(canvas, shadow)

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius, fill=255)
    canvas.paste(win, (left, top), mask)
    ImageDraw.Draw(canvas).rounded_rectangle((left, top, left + w - 1, top + h - 1), radius, outline=(255, 255, 255, 38), width=2)
    canvas.save(dst, optimize=True)


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    for name in sys.argv[3:]:
        frame(f"{src}/{name}.png", f"{out}/{name}.png")
