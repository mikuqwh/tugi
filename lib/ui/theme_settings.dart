// SPDX-License-Identifier: GPL-3.0-or-later

/// User-facing look-and-feel settings.
///
/// The accent is stored as an ARGB colour rather than an index into a preset
/// list: the user can mix their own hue, and a preset is just a shortcut that
/// writes the same value. Old files that stored an `accentIndex` are migrated.
// SPDX-License-Identifier: GPL-3.0-or-later

library theme_settings;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
import 'flow_background.dart';

/// What the home background looks like.
enum BackgroundStyle {
  plain('纯色', '干净的浅底'),
  flow('颜色流动', '模糊色块缓慢流动'),
  image('图片', '预设插画或自己的图');

  const BackgroundStyle(this.label, this.blurb);
  final String label;
  final String blurb;
}

/// Built-in background images, shipped in `assets/brand/`. The FIRST one is
/// the app icon, which is also the default background on a fresh install.
const List<String> backgroundPresets = [
  'assets/brand/app_icon.png',
  'assets/brand/bg_1.png',
  'assets/brand/bg_2.png',
  'assets/brand/bg_3.png',
];

/// The default accent: deep enough to read as a colour, not a tint.
const Color defaultAccent = Color(0xFF0088A0);

/// A named shortcut that writes a concrete colour.
@immutable
class AccentPreset {
  const AccentPreset(this.label, this.color);
  final String label;
  final Color color;
}

const List<AccentPreset> accentPresets = [
  AccentPreset('青', Color(0xFF0088A0)),
  AccentPreset('玫红', Color(0xFFC2185B)),
  AccentPreset('靛蓝', Color(0xFF2F4FE0)),
  AccentPreset('橙', Color(0xFFD9540B)),
  AccentPreset('紫', Color(0xFF7B2FBE)),
  AccentPreset('绿', Color(0xFF1E7B4F)),
];

/// Build an [Accent] from an arbitrary colour, picking readable text on it.
Accent accentFromColor(Color color) {
  final light = color.computeLuminance() < 0.5;
  return Accent(
    color,
    light ? Colors.white : const Color(0xFF14202A),
    Color.alphaBlend(color.withValues(alpha: 0.16), Colors.white),
  );
}

@immutable
class ThemeSettings {
  const ThemeSettings({
    this.background = BackgroundStyle.image,
    this.accentValue = 0xFF0088A0,
    this.imagePreset = 0, // assets/brand/app_icon.png
    this.customImagePath,
    this.imageOpacity = 0.10,
    this.backgroundOpacity = 1.0,
    this.motion = true,
  });

  final BackgroundStyle background;

  /// ARGB value of the accent.
  final int accentValue;

  /// Index into [backgroundPresets]; ignored when [customImagePath] is set.
  final int imagePreset;

  /// A user-imported background, already copied into the app's support dir.
  final String? customImagePath;

  /// 0.02..0.45: how strongly an image background shows through.
  final double imageOpacity;

  /// 0.2..1.0: how opaque the chosen colour / flow is. Lower values let the
  /// neutral base show through, which is the difference between "a colour
  /// wallpaper" and "a tinted page".
  final double backgroundOpacity;

  /// Master switch for the rainbow CTA, the flow background and page motion.
  final bool motion;

  Color get accentColor => Color(accentValue);
  Accent get accent => accentFromColor(accentColor);

  /// The colour actually behind the text: the accent blended with the
  /// opacity the user picked, over the neutral base.
  Color get backgroundGround => switch (background) {
        BackgroundStyle.plain => Color.alphaBlend(
            accentColor.withValues(alpha: backgroundOpacity),
            Neutrals.bg,
          ),
        BackgroundStyle.flow => flowGround(accentColor, backgroundOpacity),
        BackgroundStyle.image => Neutrals.bg,
      };

  /// Text/icon colour that stays readable ON whatever the background is.
  Color get onBackground =>
      backgroundGround.computeLuminance() < 0.42 ? Colors.white : Neutrals.ink;

  /// The image provider for the current image background, if any.
  ImageProvider? get backgroundImage {
    final custom = customImagePath;
    if (custom != null && File(custom).existsSync()) {
      return FileImage(File(custom));
    }
    if (imagePreset >= 0 && imagePreset < backgroundPresets.length) {
      return AssetImage(backgroundPresets[imagePreset]);
    }
    return null;
  }

  ThemeSettings copyWith({
    BackgroundStyle? background,
    int? accentValue,
    int? imagePreset,
    String? customImagePath,
    bool clearCustomImage = false,
    double? imageOpacity,
    double? backgroundOpacity,
    bool? motion,
  }) =>
      ThemeSettings(
        background: background ?? this.background,
        accentValue: accentValue ?? this.accentValue,
        imagePreset: imagePreset ?? this.imagePreset,
        customImagePath:
            clearCustomImage ? null : (customImagePath ?? this.customImagePath),
        imageOpacity: imageOpacity ?? this.imageOpacity,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        motion: motion ?? this.motion,
      );

  Map<String, Object?> toJson() => {
        'background': background.name,
        'accentValue': accentValue,
        'imagePreset': imagePreset,
        'customImagePath': customImagePath,
        'imageOpacity': imageOpacity,
        'backgroundOpacity': backgroundOpacity,
        'motion': motion,
      };

  static ThemeSettings fromJson(Map<String, Object?> raw) {
    const fallback = ThemeSettings();

    // `gradient` was the old name of the flowing background.
    final rawBg = raw['background'];
    final background = BackgroundStyle.values.firstWhere(
      (b) =>
          b.name == rawBg || (b == BackgroundStyle.flow && rawBg == 'gradient'),
      orElse: () => fallback.background,
    );

    // Migration: older files stored an index into four category accents.
    int accent = fallback.accentValue;
    if (raw['accentValue'] is int && (raw['accentValue'] as int) >> 24 != 0) {
      accent = raw['accentValue'] as int;
    } else if (raw['accentIndex'] is int) {
      const legacy = [0xFF00A6C2, 0xFFE6005C, 0xFF3D5AFE, 0xFFFB5607];
      final i = (raw['accentIndex'] as int).clamp(0, legacy.length - 1);
      accent = legacy[i];
    }

    final preset = raw['imagePreset'];
    final opacity = raw['imageOpacity'];
    final bgOpacity = raw['backgroundOpacity'];
    final custom = raw['customImagePath'];
    return ThemeSettings(
      background: background,
      accentValue: accent,
      imagePreset: preset is int
          ? preset.clamp(0, backgroundPresets.length - 1)
          : fallback.imagePreset,
      customImagePath: custom is String && custom.isNotEmpty ? custom : null,
      imageOpacity: opacity is num
          ? opacity.toDouble().clamp(0.02, 0.45)
          : fallback.imageOpacity,
      backgroundOpacity: bgOpacity is num
          ? bgOpacity.toDouble().clamp(0.2, 1.0)
          : fallback.backgroundOpacity,
      motion: raw['motion'] is bool ? raw['motion'] as bool : true,
    );
  }
}

/// Holds the current settings and notifies listeners on change.
class ThemeSettingsController extends ChangeNotifier {
  ThemeSettingsController._();

  static final ThemeSettingsController instance = ThemeSettingsController._();

  ThemeSettings _value = const ThemeSettings();
  ThemeSettings get value => _value;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/settings.json');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        _value = ThemeSettings.fromJson(raw.cast<String, Object?>());
        notifyListeners();
      }
    } catch (_) {
      // Bad settings must not stop the app from opening.
    }
  }

  Future<void> update(ThemeSettings next) async {
    _value = next;
    notifyListeners();
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(next.toJson()));
    } catch (_) {
      // Losing a preference is not worth an error dialog.
    }
  }
}
