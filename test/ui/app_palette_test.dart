/// The palette has two representations of the four category colours: the
/// [Accents] objects (which build themes) and the raw [CategoryColors] literals
/// (which `const` declarations in screens need). They must not drift.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ui/app_palette.dart';

void main() {
  test('CategoryColors mirror the Accents entries exactly', () {
    expect(CategoryColors.convert, Accents.cyan.base);
    expect(CategoryColors.gif, Accents.rose.base);
    expect(CategoryColors.image, Accents.indigo.base);
    expect(CategoryColors.tools, Accents.tools.base);
  });

  test('every feature has a pair, and the pair is two different hues', () {
    expect(FeaturePalette.byId.length, 11);
    for (final entry in FeaturePalette.byId.entries) {
      final accent = entry.value;
      expect(accent.base, isNot(accent.tail), reason: entry.key);
      // A pure light/dark ramp would be the monotony this replaced: the
      // partner must be a genuinely different hue.
      final hueShift = (HSVColor.fromColor(accent.base).hue -
              HSVColor.fromColor(accent.tail).hue)
          .abs();
      final wrapped = hueShift > 180 ? 360 - hueShift : hueShift;
      expect(wrapped, greaterThan(25), reason: '${entry.key} hue shift');
      expect(HSVColor.fromColor(accent.base).saturation, greaterThan(0.55),
          reason: '${entry.key} is not dopamine-bright');
    }
  });

  test('text on every feature colour meets WCAG AA (4.5:1)', () {
    double ratio(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    for (final entry in FeaturePalette.byId.entries) {
      final accent = entry.value;
      expect(ratio(accent.base, accent.on), greaterThanOrEqualTo(4.5),
          reason: entry.key);
    }
  });

  test('each category accent has readable text on it', () {
    for (final accent in [
      Accents.cyan,
      Accents.rose,
      Accents.indigo,
      Accents.tools,
    ]) {
      expect(accent.on, isNotNull);
      // The soft tint must be visibly lighter than the base, or the home icon
      // plates disappear into the card.
      expect(accent.soft.computeLuminance(),
          greaterThan(accent.base.computeLuminance()));
    }
  });
}
