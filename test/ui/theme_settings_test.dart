/// Settings persistence: round-trips, migrations, and the corrupt cases that
/// would otherwise show up as "the background is transparent" on a phone.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ui/app_palette.dart';
import 'package:tugi/ui/flow_background.dart';
import 'package:tugi/ui/theme_settings.dart';

void main() {
  test('every field survives a JSON round-trip', () {
    const original = ThemeSettings(
      background: BackgroundStyle.image,
      accentValue: 0xFF7B2FBE,
      imagePreset: 2,
      customImagePath: '/tmp/bg.png',
      imageOpacity: 0.31,
      backgroundOpacity: 0.6,
      motion: false,
    );
    final restored = ThemeSettings.fromJson(original.toJson());
    expect(restored.background, BackgroundStyle.image);
    expect(restored.accentValue, 0xFF7B2FBE);
    expect(restored.imagePreset, 2);
    expect(restored.customImagePath, '/tmp/bg.png');
    expect(restored.imageOpacity, closeTo(0.31, 1e-9));
    expect(restored.backgroundOpacity, closeTo(0.6, 1e-9));
    expect(restored.motion, isFalse);
  });

  test('a transparent accent falls back to the default', () {
    // 0x00000000 would paint a transparent background: invisible, and looks
    // like a rendering bug rather than a bad file.
    final s = ThemeSettings.fromJson(const {'accentValue': 0x00000000});
    expect(s.accentValue, const ThemeSettings().accentValue);
  });

  test('an out-of-range preset index is clamped', () {
    final s = ThemeSettings.fromJson(const {'imagePreset': 99});
    expect(s.imagePreset, backgroundPresets.length - 1);
  });

  test('an opacity outside the usable range is clamped', () {
    expect(
        ThemeSettings.fromJson(const {'imageOpacity': 5.0}).imageOpacity, 0.45);
    expect(ThemeSettings.fromJson(const {'imageOpacity': -1.0}).imageOpacity,
        0.02);
  });

  test('the colour opacity is clamped to a usable range', () {
    expect(
        ThemeSettings.fromJson(const {'backgroundOpacity': 3.0})
            .backgroundOpacity,
        1.0);
    expect(
        ThemeSettings.fromJson(const {'backgroundOpacity': 0.0})
            .backgroundOpacity,
        0.2);
  });

  test('the flow ground is pale enough for the blobs to show', () {
    // A dark accent must still produce a light ground, otherwise the blobs
    // have nothing to sit on (the "looks like a flat colour" complaint).
    final ground = flowGround(const Color(0xFF0088A0), 1.0);
    expect(ground.computeLuminance(), greaterThan(0.45));
  });

  test('garbage types do not throw', () {
    final s = ThemeSettings.fromJson(const {
      'background': 42,
      'accentValue': 'teal',
      'imagePreset': 'two',
      'customImagePath': 7,
      'imageOpacity': 'lots',
      'motion': 'yes',
    });
    expect(s.background, const ThemeSettings().background);
    expect(s.accentValue, const ThemeSettings().accentValue);
    expect(s.customImagePath, isNull);
    expect(s.motion, isTrue);
  });

  test('onBackground follows the background, not just the accent', () {
    const dark = ThemeSettings(
      background: BackgroundStyle.plain,
      accentValue: 0xFF0A2A33,
    );
    expect(dark.onBackground, Colors.white);

    const light = ThemeSettings(
      background: BackgroundStyle.plain,
      accentValue: 0xFFFFE066,
    );
    expect(light.onBackground, Neutrals.ink);

    // Flow sits on a pale ground whatever the accent, so it takes ink.
    const flow = ThemeSettings(
      background: BackgroundStyle.flow,
      accentValue: 0xFF0A2A33,
    );
    expect(flow.onBackground, Neutrals.ink);

    // An image sits on the pale base, so it always takes ink even when the
    // accent is dark.
    const image = ThemeSettings(
      background: BackgroundStyle.image,
      accentValue: 0xFF0A2A33,
    );
    expect(image.onBackground, Neutrals.ink);
  });

  test('copyWith can clear the custom image', () {
    const s = ThemeSettings(customImagePath: '/tmp/x.png');
    expect(s.copyWith(clearCustomImage: true).customImagePath, isNull);
    expect(s.copyWith(imagePreset: 1).customImagePath, '/tmp/x.png');
  });
}
