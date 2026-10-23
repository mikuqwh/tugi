#!/usr/bin/env python3
"""Generate Tugi's launcher icons from the illustrated artwork.

The source is `assets/brand/app_icon.png` -- a square illustration on white.
It is the single source of truth: re-run this script after replacing that file,
never edit the PNGs under android/ by hand.

Layout decisions:
  * adaptive foreground: the art is fitted to ~78% of the 108 dp canvas. The
    launcher may mask up to 18 dp off each edge, so a full-bleed square would
    lose the hat and the shoulders; 78% keeps the character whole under every
    mask shape.
  * the adaptive background is plain white, matching the artwork's own paper,
    so no seam is visible inside the mask.
  * no monochrome layer: Android's themed icons tint a silhouette, and a
    threshold of a painted illustration produces a grey blob. Themed icons
    fall back to the normal icon when `<monochrome>` is absent.
  * legacy (pre-API-26) icons are the same art on a rounded plate.

Run from the repo root:  python tool/brand/make_icons.py
"""
from __future__ import annotations

import os

from PIL import Image, ImageDraw

SRC = os.path.join("assets", "brand", "app_icon.png")
SS = 4  # supersampling for the rounded plate edges


def _load() -> Image.Image:
    return Image.open(SRC).convert("RGB")


def _fit(art: Image.Image, canvas_px: int, fraction: float) -> Image.Image:
    """Centre `art` on a white square of `canvas_px`, occupying `fraction`."""
    out = Image.new("RGB", (canvas_px, canvas_px), (255, 255, 255))
    inner = max(1, int(canvas_px * fraction))
    resized = art.resize((inner, inner), Image.LANCZOS)
    offset = (canvas_px - inner) // 2
    out.paste(resized, (offset, offset))
    return out


def foreground(size_px: int) -> Image.Image:
    """Adaptive foreground: white-topped art, no transparency needed."""
    return _fit(_load(), size_px, 0.78).convert("RGBA")


def legacy(size_px: int, round_icon: bool = False) -> Image.Image:
    """Pre-API-26 icon: the art on a rounded (or circular) white plate."""
    big = size_px * SS
    plate = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(plate)
    if round_icon:
        d.ellipse([0, 0, big - 1, big - 1], fill=(255, 255, 255, 255))
    else:
        d.rounded_rectangle(
            [0, 0, big - 1, big - 1],
            radius=int(big * 0.22),
            fill=(255, 255, 255, 255),
        )
    art = _fit(_load(), int(big * 0.90), 1.0).convert("RGBA")
    # The art is inset inside the plate, so it never reaches the rounded
    # corners: no masking needed (and a size-mismatched mask would throw).
    plate.paste(art, ((big - art.width) // 2, (big - art.height) // 2))
    return plate.resize((size_px, size_px), Image.LANCZOS)


def main() -> None:
    res = os.path.join("android", "app", "src", "main", "res")
    densities = {
        "mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0,
    }
    for name, scale in densities.items():
        d = os.path.join(res, f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)
        legacy(int(48 * scale)).save(os.path.join(d, "ic_launcher.png"))
        legacy(int(48 * scale), round_icon=True).save(
            os.path.join(d, "ic_launcher_round.png"))
        foreground(int(108 * scale)).save(
            os.path.join(d, "ic_launcher_foreground.png"))
        # Left over from the geometric-chick era; the artwork cannot be
        # silhouetted, so it must not be left in the resource tree.
        for stale in ("ic_launcher_monochrome.png",):
            stale_path = os.path.join(d, stale)
            if os.path.exists(stale_path):
                os.remove(stale_path)

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    adaptive = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""
    for fname in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, fname), "w", encoding="utf-8") as f:
            f.write(adaptive)

    values = os.path.join(res, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "colors.xml"), "w", encoding="utf-8") as f:
        f.write("<?xml version='1.0' encoding='utf-8'?>\n"
                "<resources>\n"
                '    <color name="ic_launcher_background">#FFFFFF</color>\n'
                "</resources>\n")

    preview = Image.new("RGB", (432 * 2 + 48, 432), (245, 246, 250))
    preview.paste(legacy(432), (0, 0))
    preview.paste(foreground(432), (432 + 48, 0))
    os.makedirs(os.path.join("tool", "brand"), exist_ok=True)
    preview.save(os.path.join("tool", "brand", "icon_preview.png"))
    print("icons written to", res)


if __name__ == "__main__":
    main()
