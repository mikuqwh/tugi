#!/usr/bin/env python3
"""Build the bundled watermark fonts.

Why this exists
---------------
The app needs real font FILES for ffmpeg's `drawtext` filter. Two problems:

1. `drawtext` on the device build REQUIRES `fontfile=`. The bundled ffmpeg is
   built with `--enable-libfontconfig --enable-libfreetype`, but fontconfig on
   Android has no usable config file, so the fallback
   ("use the system font") does not exist. Without `fontfile=` the filter
   dies with "Cannot find a valid font".
2. The full Noto Sans SC VF is 17.8 MB, and the APK is already ~250 MB.
   Shipping it whole is wasteful.

So: instance the variable fonts at a single weight each, then subset them to
the GB2312 hanzi set (6763 chars) plus ASCII and common punctuation.

The output is a STATIC TTF. A variable font is a poor input for freetype:
it would render at whatever the default instance happens to be, and some
freetype builds mishandle the `gvar` table.

## Font choice is a licensing question, not just an aesthetic one

Only Noto (SIL Open Font License) fonts are bundled. The system also has
SimHei, DengXian and Microsoft YaHei, which would give a different look,
but they are Microsoft's copyrighted fonts and redistributing them inside
an APK is not allowed. OFL fonts can be shipped as long as the license
travels with them; the NOTICE file is generated alongside.

The four faces shipped:
  NotoSansSC-Regular   - the default; neutral sans
  NotoSansSC-Bold      - for emphasis / small sizes
  NotoSerifSC-Regular  - a serif (Song/Ming) look
  NotoSerifSC-Bold     - serif, heavier
"""
import os
import sys

import pathlib

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools import subset

SANS_SRC = r"C:\Windows\Fonts\NotoSansSC-VF.ttf"
SERIF_SRC = r"C:\Windows\Fonts\NotoSerifSC-VF.ttf"
OUT_DIR = str(pathlib.Path(__file__).resolve().parent.parent / "assets" / "fonts")

# (source, weight, output name, family name for the UI)
FACES = [
    (SANS_SRC, 400, "NotoSansSC-Regular.ttf", "Noto Sans SC"),
    (SANS_SRC, 700, "NotoSansSC-Bold.ttf", "Noto Sans SC Bold"),
    (SERIF_SRC, 400, "NotoSerifSC-Regular.ttf", "Noto Serif SC"),
    (SERIF_SRC, 700, "NotoSerifSC-Bold.ttf", "Noto Serif SC Bold"),
]


def gb2312_hanzi() -> set:
    """Every hanzi the GB2312 encoding can represent (6763 of them).

    Decoding every valid two-byte GB2312 sequence is a deterministic way to
    get the set -- no hand-maintained list to go stale.
    """
    chars = set()
    for hi in range(0xA1, 0xFE + 1):
        for lo in range(0xA1, 0xFE + 1):
            try:
                chars.add(bytes([hi, lo]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return chars


def wanted_chars() -> set:
    wanted = set(gb2312_hanzi())
    wanted |= set(chr(c) for c in range(0x20, 0x7F))       # ASCII
    # Full-width punctuation and the CJK symbols a watermark might use.
    wanted |= set("　、。〃々〈〉《》「」『』【】〔〕〖〗〝〞・ー"
                  "！＂＃＄％＆＇（）＊＋，－．／０１２３４５６７８９"
                  "：；＜＝＞？＠［＼］＾＿｀｛｜｝～"
                  "…‰′″‹›※€£¥©®™←→↑↓■□▲△○●◇★☆♪"
                  "、。！？：；，．·「」『』（）【】〔〕〜～￥")
    wanted |= set("一二三四五六七八九十百千万亿零壹贰叁肆伍陆柒捌玖拾"
                  "月日年时分秒星期号的了在是我有和就不人都一个上也很到说"
                  "要去你我他会着看好这那与为上以于中下但")
    # Characters the UI itself may draw in a watermark.
    wanted |= set("水印文字图片视频透明度位置大小颜色字体描边阴影不透明度")
    # Drop only the control characters. NOT `c.strip()`: that also removes
    # U+0020 SPACE and U+3000 IDEOGRAPHIC SPACE, and a font without the
    # space glyph renders every space in a watermark as a tofu box.
    return {c for c in wanted if c not in "\n\r\t\v\f"}


def build_one(src, weight, out_name, family, wanted):
    print(f"\n=== {out_name} (wght={weight}) ===")
    if not os.path.exists(src):
        print(f"  SKIP: source missing {src}", file=sys.stderr)
        return False

    # 1. Pin the variable axis so the result is static.
    font = TTFont(src)
    axes = [(a.axisTag, a.minValue, a.defaultValue, a.maxValue)
            for a in font["fvar"].axes]
    print(f"  source: {os.path.getsize(src) / 1e6:.1f} MB, axes={axes}")
    font = instancer.instantiateVariableFont(font, {"wght": weight}, inplace=True)

    # 2. Subset.
    options = subset.Options()
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    options.layout_features = ["*"]
    options.notdef_outline = True
    options.recalc_bounds = True
    options.drop_tables += ["DSIG"]
    options.desubroutinize = True
    options.glyph_names = False

    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=[ord(c) for c in wanted])
    subsetter.subset(font)

    # The family name has to say which face it is, or the four files are
    # indistinguishable to anything that reads the name table.
    name = font["name"]
    for nid, val in ((1, family), (2, "Regular"), (4, family),
                     (6, out_name.replace(".ttf", ""))):
        name.setName(val, nid, 3, 1, 0x409)
        name.setName(val, nid, 1, 0, 0)

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, out_name)
    font.flavor = None
    font.save(out)

    size = os.path.getsize(out)
    check = TTFont(out)
    cmap = check.getBestCmap()
    print(f"  written: {out} ({size / 1e6:.2f} MB), "
          f"glyphs={check['maxp'].numGlyphs}, cmap={len(cmap)}")

    missing = [c for c in ("水", "印", "A", "0", "中", " ", "　")
               if ord(c) not in cmap]
    if missing:
        print(f"  ERROR: missing required glyphs: {missing!r}", file=sys.stderr)
        return False
    return True


def main() -> int:
    wanted = wanted_chars()
    print(f"requested glyph set: {len(wanted)} codepoints")

    ok = True
    total = 0
    for src, weight, out_name, family in FACES:
        if build_one(src, weight, out_name, family, wanted):
            total += os.path.getsize(os.path.join(OUT_DIR, out_name))
        else:
            ok = False

    # The OFL requires the license to travel with the font.
    notice = os.path.join(OUT_DIR, "OFL-LICENSE.txt")
    with open(notice, "w", encoding="utf-8") as f:
        f.write(
            "The fonts in this directory are subsets of Noto Sans SC and\n"
            "Noto Serif SC, licensed under the SIL Open Font License 1.1.\n\n"
            "Copyright 2025 The Noto Project Authors\n"
            "https://github.com/notofonts/noto-cjk\n\n"
            "Licensed under the Apache License, Version 2.0 (the \"License\");\n"
            "you may not use this file except in compliance with the License.\n"
            "You may obtain a copy of the License at\n\n"
            "    http://www.apache.org/licenses/LICENSE-2.0\n\n"
            "Unless required by applicable law or agreed to in writing,\n"
            "software distributed under the License is distributed on an\n"
            "\"AS IS\" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,\n"
            "either express or implied. See the License for the specific\n"
            "language governing permissions and limitations under the\n"
            "License.\n\n"
            "The full license text is available at\n"
            "https://openfontlicense.org/open-font-license-official-text/\n"
        )
    print(f"\nOFL notice written: {notice}")
    print(f"total font payload: {total / 1e6:.2f} MB")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
