// SPDX-License-Identifier: GPL-3.0-or-later

/// The colour wheel and the saved-colour row.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ui/theme_settings.dart';
import 'package:tugi/ui/color_wheel.dart';

void main() {
  testWidgets('dragging the ring changes the hue', (tester) async {
    Color? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ColorWheel(
            color: const Color(0xFFFF0000),
            size: 220,
            onChanged: (c) => picked = c,
          ),
        ),
      ),
    ));

    // The ring is the outer 26 px; drag from the right side (hue 0) down to
    // the bottom of the ring (hue 90).
    final center = tester.getCenter(find.byKey(const Key('color_wheel')));
    // From the right edge (hue 0) to the bottom edge (hue 90).
    await tester.dragFrom(
      center + const Offset(97, 0),
      const Offset(-97, 97),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    final hue = HSVColor.fromColor(picked!).hue;
    expect(hue, closeTo(90, 25));
  });

  testWidgets('dragging inside the square changes saturation/value',
      (tester) async {
    Color? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ColorWheel(
            color: const Color(0xFF00FF00),
            size: 220,
            onChanged: (c) => picked = c,
          ),
        ),
      ),
    ));

    final center = tester.getCenter(find.byKey(const Key('color_wheel')));
    // Bottom-left of the inner square: dark, low saturation.
    await tester.tapAt(center + const Offset(-40, 40));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    final hsv = HSVColor.fromColor(picked!);
    expect(hsv.value, lessThan(0.7));
    expect(hsv.saturation, lessThan(0.7));
  });

  testWidgets('saved colours can be picked and removed', (tester) async {
    Color? picked;
    Color? removed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SavedColorRow(
          colors: const [Color(0xFFFF0000), Color(0xFF0000FF)],
          onPick: (c) => picked = c,
          onRemove: (c) => removed = c,
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('saved_color_4294901760')));
    expect(picked, const Color(0xFFFF0000));

    await tester.longPress(find.byKey(const Key('saved_color_4278190335')));
    expect(removed, const Color(0xFF0000FF));
  });

  test('hex labels are six digits, upper case', () {
    expect(hexLabel(const Color(0xFF00A6C2)), '#00A6C2');
    expect(hexLabel(const Color(0xFFFFFFFF)), '#FFFFFF');
  });

  test('the accent helper picks readable text for dark and light colours', () {
    expect(accentFromColor(const Color(0xFF101820)).on, Colors.white);
    expect(
        accentFromColor(const Color(0xFFFFE066)).on, const Color(0xFF14202A));
  });
}
