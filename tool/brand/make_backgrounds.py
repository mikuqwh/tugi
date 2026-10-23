#!/usr/bin/env python3
"""Generate the three built-in background images.

These are deliberately abstract: soft off-screen blobs in a dopamine palette,
blurred so no shape is recognisable. They exist so the "图片" background mode
has something to show before the user imports their own artwork.

Run from the repo root:  python tool/brand/make_backgrounds.py
"""
from __future__ import annotations

import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

SIZE = 720  # 2x the widest phone dp; scaled down by Flutter

PALETTES = [
    # (background, blob colours)
    ((250, 247, 255), [(0x7B, 0x61, 0xFF), (0x4C, 0xC9, 0xF0), (0xFF, 0xBE, 0x0B)]),
    ((255, 250, 246), [(0xFF, 0x6B, 0x9D), (0xFF, 0xBE, 0x0B), (0x06, 0xD6, 0xA0)]),
    ((245, 252, 255), [(0x00, 0xC2, 0xD1), (0x3A, 0x86, 0xFF), (0xC7, 0x7D, 0xFF)]),
]


def render(index: int, palette) -> Image.Image:
    bg, colors = palette
    base = Image.new("RGB", (SIZE, SIZE), bg)
    blobs = Image.new("RGB", (SIZE, SIZE), bg)
    draw = ImageDraw.Draw(blobs)

    rng = random.Random(1000 + index)
    for i, color in enumerate(colors):
        # Three large blobs pinned to different corners, each with a hand-
        # placed centre so the result stays calm rather than noisy.
        cx, cy = [
            (0.20, 0.18), (0.85, 0.35), (0.45, 0.95),
        ][i % 3]
        cx += rng.uniform(-0.06, 0.06)
        cy += rng.uniform(-0.06, 0.06)
        r = SIZE * (0.42 + 0.08 * i)
        draw.ellipse(
            [cx * SIZE - r, cy * SIZE - r, cx * SIZE + r, cy * SIZE + r],
            fill=color,
        )

    blobs = blobs.filter(ImageFilter.GaussianBlur(SIZE * 0.14))
    # Blend the blurred blobs onto the base at a low alpha so the palette stays
    # pale (a background must not fight the cards).
    out = Image.blend(base, blobs, 0.55)
    out = out.filter(ImageFilter.GaussianBlur(SIZE * 0.02))

    # A very light vignette keeps the top edge readable behind the header.
    veil = Image.new("L", (SIZE, SIZE), 255)
    vd = ImageDraw.Draw(veil)
    for y in range(SIZE):
        t = y / SIZE
        vd.line([(0, y), (SIZE, y)], fill=int(255 - 18 * math.sin(t * math.pi)))
    white = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
    return Image.composite(white, out, veil.point(lambda v: int((255 - v) * 0.55)))


def main() -> None:
    out_dir = os.path.join("assets", "brand")
    os.makedirs(out_dir, exist_ok=True)
    for i, palette in enumerate(PALETTES):
        render(i, palette).save(os.path.join(out_dir, f"bg_{i + 1}.png"))
    print("backgrounds written to", out_dir)


if __name__ == "__main__":
    main()
