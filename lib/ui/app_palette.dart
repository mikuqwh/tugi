/// The app's design tokens.
///
/// One file, one palette: every screen pulls its colors from here so the
/// nine features read as one system instead of nine unrelated screens.
///
/// ## The surface-tint trap
///
/// Material 3 draws an [ElevatedButton] by painting its background and then
/// laying a *surface tint* over it, the tint being [ColorScheme.surfaceTint],
/// which defaults to [ColorScheme.primary].
///
/// The old app-wide theme was
///
/// ``dart
/// colorScheme: const ColorScheme.dark(
///   primary: Colors.white,        // <- tint becomes white
///   surface: Color(0xFF1E1E1E),   // <- and the surface is near black
/// )
/// ``
///
/// so every tinted button was painted white-then-darkened and came out
/// **#1E1E1E -- indistinguishable from the black background**. That is why
/// the pick buttons looked black. [buildFeatureTheme] below kills the tint
/// explicitly, so a button's colour is exactly the colour asked for.
// SPDX-License-Identifier: GPL-3.0-or-later

library app_palette;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// A feature's colour triple: the fill, the colour that sits on it, and a
/// soft tint for chips and card backgrounds.
class Accent {
  const Accent(this.base, this.on, this.soft);

  /// The fill colour: buttons, app bars, icons.
  final Color base;

  /// The colour of text and icons drawn on top of [base].
  final Color on;

  /// A pale version of [base], for selected chips and card washes.
  final Color soft;
}

/// Shared neutrals.
class Neutrals {
  const Neutrals._();

  /// Page background.
  static const bg = Color(0xFFFBF7FF);

  /// Card / sheet background.
  static const surface = Color(0xFFFFFFFF);

  /// Primary text.
  static const ink = Color(0xFF1A1A2E);

  /// Secondary text.
  static const inkSoft = Color(0xFF6B6480);

  /// Hairlines and borders.
  static const line = Color(0xFFF0E7FA);
}

/// The four CATEGORY accents.
///
/// Per-feature colours live in [FeaturePalette]; these exist for section
/// headers, and as the theme fallbacks, so a category always has one anchor
/// hue that its features stay near.
class Accents {
  const Accents._();

  static const indigo =
      Accent(Color(0xFF3D5AFE), Color(0xFFFFFFFF), Color(0xFFE4E9FF));
  static const rose =
      Accent(Color(0xFFE6005C), Color(0xFFFFFFFF), Color(0xFFFFE3EC));

  /// The "conversion" accent (Tugi): cyan, so the format/convert family reads
  /// as one group once the home screen is split into categories in S4.
  static const cyan =
      Accent(Color(0xFF00A6C2), Color(0xFFFFFFFF), Color(0xFFDDF6FA));

  /// The 工具 category: warm orange, because "neutral grey" is exactly the
  /// thing a dopamine palette must not do.
  static const tools =
      Accent(Color(0xFFFB5607), Color(0xFFFFFFFF), Color(0xFFFFEDE3));

  /// 混淆：violet, its own family rather than a fourth cyan screen.
  static const violet =
      Accent(Color(0xFF7C4DFF), Color(0xFFFFFFFF), Color(0xFFEDE7FF));
}

/// Raw colour constants for the four categories.
///
/// Screens keep a `static const _accent = ...` of their own; a `const` cannot
/// read a field off an [Accent] instance, so the literal has to live here too.
/// These MUST stay equal to the corresponding [Accents] entries -- a test
/// pins that.
class CategoryColors {
  const CategoryColors._();

  /// 转换 — same as [Accents.cyan].
  static const convert = Color(0xFF00A6C2);

  /// GIF — same as [Accents.rose].
  static const gif = Color(0xFFE6005C);

  /// 图片 — same as [Accents.indigo].
  static const image = Color(0xFF3D5AFE);

  /// 工具 — same as [Accents.slate].
  static const tools = Color(0xFFFB5607);
}

/// One feature's colour pair.
///
/// [base] is what the screen paints (app bar, buttons) and [tail] is the
/// dopamine partner it blends into on gradients -- deliberately NOT a lighter
/// shade of [base]: a feature inside one family should still look different
/// from its siblings, so each one borrows a second hue from the palette
/// (mint, electric purple, blue, yellow).
@immutable
class FeatureAccent {
  const FeatureAccent(this.base, this.tail, this.on, this.soft);

  final Color base;
  final Color tail;

  /// Text/icon colour drawn ON [base]; chosen per feature so contrast holds
  /// for bright cyan/pink bases instead of forcing everything to white.
  final Color on;

  /// The pale tint used behind icons.
  final Color soft;

  LinearGradient get gradient => LinearGradient(
        colors: [base, tail],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
}

/// Per-feature colours. Eleven features, four families:
///
///  * 转换   cyan/teal, with mint / violet / yellow partners
///  * GIF    pink/magenta, with purple / lilac / cyan / yellow / blue partners
///  * 图片   blue/indigo, with violet / mint partners
///
/// The `const` literals live in [FeatureColors] and the pairs here reference
/// them, so a screen can declare `static const _accent = FeatureColors.x`.
class FeatureColors {
  const FeatureColors._();

  // 转换
  static const formatConvert = Color(0xFF00C2D1);
  static const formatConvertTail = Color(0xFF3A86FF);
  static const formatConvertOn = Color(0xFF0A2A33);

  static const extractAudio = Color(0xFF0E9BD1);
  static const extractAudioTail = Color(0xFF7B61FF);
  static const extractAudioOn = Color(0xFF1A1A2E);

  static const imagesToVideo = Color(0xFF12B5A6);
  static const imagesToVideoTail = Color(0xFF3A86FF);
  static const imagesToVideoOn = Color(0xFF04231F);

  /// 混淆：violet, far enough in hue from the three convert accents.
  static const scramble = Color(0xFF7C4DFF);
  static const scrambleTail = Color(0xFF00E0C6);
  static const scrambleOn = Color(0xFF14102E);

  // GIF
  static const videoToGif = Color(0xFFE6005C);
  static const videoToGifTail = Color(0xFF8338EC);
  static const videoToGifOn = Color(0xFFFFFFFF);

  static const imagesToGif = Color(0xFFD81B60);
  static const imagesToGifTail = Color(0xFFC77DFF);
  static const imagesToGifOn = Color(0xFFFFFFFF);

  static const editGif = Color(0xFFC2185B);
  static const editGifTail = Color(0xFF4CC9F0);
  static const editGifOn = Color(0xFFFFFFFF);

  static const gifToVideo = Color(0xFFFF4D8D);
  static const gifToVideoTail = Color(0xFF7B61FF);
  static const gifToVideoOn = Color(0xFF3A0A1C);

  static const gifToImages = Color(0xFFB5179E);
  static const gifToImagesTail = Color(0xFF3A86FF);
  static const gifToImagesOn = Color(0xFFFFFFFF);

  static const compressGif = Color(0xFFFF6B9D);
  static const compressGifTail = Color(0xFFD946EF);
  static const compressGifOn = Color(0xFF3A0A1C);

  // 图片
  static const addWatermark = Color(0xFF3D5AFE);
  static const addWatermarkTail = Color(0xFFC77DFF);
  static const addWatermarkOn = Color(0xFFFFFFFF);

  static const editImage = Color(0xFF2F6FE4);
  static const editImageTail = Color(0xFF06D6A0);
  static const editImageOn = Color(0xFFFFFFFF);
}

class FeaturePalette {
  const FeaturePalette._();

  static const formatConvert = FeatureAccent(
    FeatureColors.formatConvert,
    FeatureColors.formatConvertTail,
    FeatureColors.formatConvertOn,
    Color(0xFFDDF7F8),
  );
  static const extractAudio = FeatureAccent(
    FeatureColors.extractAudio,
    FeatureColors.extractAudioTail,
    FeatureColors.extractAudioOn,
    Color(0xFFE2F4FB),
  );
  static const imagesToVideo = FeatureAccent(
    FeatureColors.imagesToVideo,
    FeatureColors.imagesToVideoTail,
    FeatureColors.imagesToVideoOn,
    Color(0xFFDDF6F2),
  );
  static const scramble = FeatureAccent(
    FeatureColors.scramble,
    FeatureColors.scrambleTail,
    FeatureColors.scrambleOn,
    Color(0xFFEDE7FF),
  );
  static const videoToGif = FeatureAccent(
    FeatureColors.videoToGif,
    FeatureColors.videoToGifTail,
    FeatureColors.videoToGifOn,
    Color(0xFFFFE3EC),
  );
  static const imagesToGif = FeatureAccent(
    FeatureColors.imagesToGif,
    FeatureColors.imagesToGifTail,
    FeatureColors.imagesToGifOn,
    Color(0xFFFCE4EE),
  );
  static const editGif = FeatureAccent(
    FeatureColors.editGif,
    FeatureColors.editGifTail,
    FeatureColors.editGifOn,
    Color(0xFFFBE0E8),
  );
  static const gifToVideo = FeatureAccent(
    FeatureColors.gifToVideo,
    FeatureColors.gifToVideoTail,
    FeatureColors.gifToVideoOn,
    Color(0xFFFFE6EF),
  );
  static const gifToImages = FeatureAccent(
    FeatureColors.gifToImages,
    FeatureColors.gifToImagesTail,
    FeatureColors.gifToImagesOn,
    Color(0xFFFDE3EF),
  );
  static const compressGif = FeatureAccent(
    FeatureColors.compressGif,
    FeatureColors.compressGifTail,
    FeatureColors.compressGifOn,
    Color(0xFFFFE9F1),
  );
  static const addWatermark = FeatureAccent(
    FeatureColors.addWatermark,
    FeatureColors.addWatermarkTail,
    FeatureColors.addWatermarkOn,
    Color(0xFFE6E9FF),
  );
  static const editImage = FeatureAccent(
    FeatureColors.editImage,
    FeatureColors.editImageTail,
    FeatureColors.editImageOn,
    Color(0xFFE4EDFC),
  );

  /// Catalog ids happen to be snake_case; map them explicitly so a rename in
  /// one place cannot silently fall through to a wrong colour.
  static const Map<String, FeatureAccent> byId = {
    'format_convert': formatConvert,
    'extract_audio': extractAudio,
    'images_to_video': imagesToVideo,
    'video_to_gif': videoToGif,
    'images_to_gif': imagesToGif,
    'edit_gif': editGif,
    'gif_to_video': gifToVideo,
    'gif_to_images': gifToImages,
    'compress_gif': compressGif,
    'add_watermark': addWatermark,
    'edit_image': editImage,
  };

  static FeatureAccent of(String id) => byId[id] ?? formatConvert;
}

/// The gradient wash behind an [AppBar].
///
/// A flat app bar was the monotony the palette rework set out to fix; this
/// blends the feature's base into its partner hue in one cheap DecoratedBox.
class AccentGradientBackground extends StatelessWidget {
  const AccentGradientBackground({super.key, required this.accent});

  final FeatureAccent accent;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(gradient: accent.gradient),
        child: const SizedBox.expand(),
      );
}

/// The light theme a feature screen runs under.
///
/// [accent] drives the app bar, the primary buttons and the chip colours.
/// The surface tint is disabled (see the class doc) so a button is painted
/// in exactly [Accent.base].
ThemeData buildFeatureTheme(Accent accent) {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Neutrals.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent.base,
      brightness: Brightness.light,
    ).copyWith(
      primary: accent.base,
      onPrimary: accent.on,
      surface: Neutrals.surface,
      onSurface: Neutrals.ink,
      // No tint: an elevated button must show its own colour, not a
      // darkened version of it.
      surfaceTint: Colors.transparent,
    ),
    cardColor: Neutrals.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: accent.base,
      foregroundColor: accent.on,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: accent.on,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent.base,
        foregroundColor: accent.on,
        // A disabled action must still look like this feature (a muted
        // version of its colour), not like a grey library default.
        // Pale, not grey: "not ready" still reads as this feature's colour.
        disabledBackgroundColor: accent.base.withValues(alpha: 0.16),
        disabledForegroundColor: accent.base.withValues(alpha: 0.55),
        elevation: 0,
        // The tint is the whole bug; kill it at the theme level too.
        surfaceTintColor: Colors.transparent,
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
        // One height for every primary action: 52 is comfortable under a
        // thumb and matches the docked action bars.
        minimumSize: const Size(0, 52),
        shape: const RoundedRectangleBorder(borderRadius: Radii.controlAll),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent.base,
        foregroundColor: accent.on,
        surfaceTintColor: Colors.transparent,
        minimumSize: const Size(0, 52),
        shape: const RoundedRectangleBorder(borderRadius: Radii.controlAll),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent.base,
        side: const BorderSide(color: Neutrals.line, width: 1.2),
        minimumSize: const Size(0, 44),
        shape: const RoundedRectangleBorder(borderRadius: Radii.controlAll),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent.base,
        shape: const RoundedRectangleBorder(borderRadius: Radii.chipAll),
      ),
    ),
    cardTheme: CardThemeData(
      color: Neutrals.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: Radii.cardAll,
        side: BorderSide(color: Neutrals.line),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Neutrals.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.sheet)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Neutrals.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent.base,
      linearTrackColor: accent.soft,
    ),
    splashFactory: InkSparkle.splashFactory,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Neutrals.ink,
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent.base,
      inactiveTrackColor: accent.soft,
      thumbColor: accent.base,
      overlayColor: accent.base.withValues(alpha: 0.12),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? accent.base : null),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? accent.base.withValues(alpha: 0.35)
              : Neutrals.line),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Neutrals.surface,
      selectedColor: accent.soft,
      checkmarkColor: accent.base,
      side: const BorderSide(color: Neutrals.line, width: 1.2),
      labelStyle: const TextStyle(
        color: Neutrals.ink,
        fontWeight: FontWeight.w500,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.chipAll),
    ),
    dividerTheme: const DividerThemeData(color: Neutrals.line, space: 1),
    listTileTheme: const ListTileThemeData(iconColor: Neutrals.inkSoft),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Neutrals.surface,
      border: const OutlineInputBorder(
        borderRadius: Radii.controlAll,
        borderSide: BorderSide(color: Neutrals.line),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: Radii.controlAll,
        borderSide: BorderSide(color: Neutrals.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: Radii.controlAll,
        borderSide: BorderSide(color: accent.base, width: 1.8),
      ),
      labelStyle: const TextStyle(color: Neutrals.inkSoft),
    ),
  );
}
