#!/usr/bin/env python3
"""Draw the app icon (light, dark, tinted): an eight-pointed star with a
three-bar waveform cut out of it. Needs Pillow.

  python3 tools/make-app-icon.py
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "App/QuranRecitationChecker/Resources/Assets.xcassets/AppIcon.appiconset"
N, SS = 1024, 4  # final size, supersampling
W = N * SS
C = W / 2
A = 0.26 * W     # half-side of each square of the star


def star_mask():
    m = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(m)
    for turn in (0, math.pi / 4):
        pts = [(C + A * math.sqrt(2) * math.cos(turn + math.pi / 4 + k * math.pi / 2),
                C + A * math.sqrt(2) * math.sin(turn + math.pi / 4 + k * math.pi / 2)) for k in range(4)]
        d.polygon(pts, fill=255)
    # Waveform: three rounded bars, the middle one tallest.
    bw, gap = 0.17 * A, 0.13 * A
    for i, h in zip((-1, 0, 1), (0.50, 0.95, 0.50)):
        x = C + i * (bw + gap)
        d.rounded_rectangle((x - bw / 2, C - h * A / 2 * 1.2, x + bw / 2, C + h * A / 2 * 1.2), radius=bw / 2, fill=0)
    return m


def gradient(top, bottom):
    g = Image.new("RGB", (1, W))
    for y in range(W):
        t = y / (W - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize((W, W))


def save(img, name):
    img.resize((N, N), Image.LANCZOS).save(OUT / name, optimize=True)


mask = star_mask()
# Ink on paper, like the web app.
light = gradient((0x2A, 0x2A, 0x2A), (0x11, 0x11, 0x11))
light.paste((255, 255, 255), mask=mask)
save(light, "AppIcon.png")

# Dark and tinted: transparent background, which iOS fills in.
dark = Image.new("RGBA", (W, W), (0, 0, 0, 0))
dark.paste((0xF2, 0xF2, 0xF2, 255), mask=mask)
save(dark, "AppIcon-Dark.png")

tinted = Image.new("RGBA", (W, W), (0, 0, 0, 0))
tinted.paste((255, 255, 255, 255), mask=mask)
save(tinted, "AppIcon-Tinted.png")
