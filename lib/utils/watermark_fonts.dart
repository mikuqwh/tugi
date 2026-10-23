// SPDX-License-Identifier: GPL-3.0-or-later

/// The bundled watermark fonts.
///
/// starts empty. This clone ships a small set instead, so the feature works
/// on first launch.
///
/// ## Why these four and not the system fonts
///
/// Every face here is a subset of a Noto CJK font, which is under the SIL
/// Open Font License and can be redistributed inside an APK (the license
/// text ships next to them in `OFL-LICENSE.txt`). The machine this was
/// built on also has SimHei, DengXian and Microsoft YaHei, which would
/// look different, but they are Microsoft's copyrighted fonts and bundling
/// them would not be legal.
///
/// ## The Flutter family name
///
/// Each file is also registered as a Flutter font family so the PREVIEW can
/// draw the same face ffmpeg will use. The family names below must match
/// what is declared in `pubspec.yaml`, and the files must be listed there
/// or `FontLoader` will fail to find them.
// SPDX-License-Identifier: GPL-3.0-or-later

library watermark_fonts;

/// One selectable watermark font.
class WatermarkFont {
  const WatermarkFont({
    required this.id,
    required this.label,
    required this.assetPath,
    required this.fileName,
    required this.flutterFamily,
  });

  /// Stable identifier, persisted in the screen's state.
  final String id;

  /// What the UI shows.
  final String label;

  /// Path inside the APK, for `rootBundle`.
  final String assetPath;

  /// The name the font is copied to in the app's work directory. ffmpeg's
  /// `fontfile=` points at this file.
  final String fileName;

  /// The Flutter font family this file is registered under, so the preview
  /// can draw with it.
  final String flutterFamily;
}

/// The fonts offered in the UI, in display order.
///
/// Four faces: a sans and a serif, each in a regular and a bold weight. The
/// weight matters as much as the family for a watermark -- at the small
/// sizes a watermark usually runs at, a regular-weight stroke thins out and
/// reads as dirt on the frame.
const List<WatermarkFont> watermarkFonts = [
  WatermarkFont(
    id: 'sans',
    label: '黑体',
    assetPath: 'assets/fonts/NotoSansSC-Regular.ttf',
    fileName: 'NotoSansSC-Regular.ttf',
    flutterFamily: 'WatermarkSans',
  ),
  WatermarkFont(
    id: 'sans_bold',
    label: '黑体 粗',
    assetPath: 'assets/fonts/NotoSansSC-Bold.ttf',
    fileName: 'NotoSansSC-Bold.ttf',
    flutterFamily: 'WatermarkSansBold',
  ),
  WatermarkFont(
    id: 'serif',
    label: '宋体',
    assetPath: 'assets/fonts/NotoSerifSC-Regular.ttf',
    fileName: 'NotoSerifSC-Regular.ttf',
    flutterFamily: 'WatermarkSerif',
  ),
  WatermarkFont(
    id: 'serif_bold',
    label: '宋体 粗',
    assetPath: 'assets/fonts/NotoSerifSC-Bold.ttf',
    fileName: 'NotoSerifSC-Bold.ttf',
    flutterFamily: 'WatermarkSerifBold',
  ),
];

/// The font used unless the user picks another.
///
/// Written out rather than indexed from the list: a list subscript is not a
/// constant expression in Dart, and this is referenced from a `const`
/// default parameter.
const WatermarkFont defaultWatermarkFont = WatermarkFont(
  id: 'sans',
  label: '黑体',
  assetPath: 'assets/fonts/NotoSansSC-Regular.ttf',
  fileName: 'NotoSansSC-Regular.ttf',
  flutterFamily: 'WatermarkSans',
);

/// Look up a font by [id], falling back to [defaultWatermarkFont].
///
/// The fallback matters because the id comes from persisted state: a font
/// that is removed in a later version must not crash the screen.
WatermarkFont watermarkFontById(String id) {
  for (final f in watermarkFonts) {
    if (f.id == id) return f;
  }
  return defaultWatermarkFont;
}
