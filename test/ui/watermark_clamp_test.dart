// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/models/watermark_placement.dart';

/// A watermark may be dragged until its BOX touches the frame edge -- text and
/// media alike. The bug report was "a GIF cannot reach the edge, text can", so
/// these cases pin the arithmetic both share.
///
/// This is deliberately a pure-math test: decoding a GIF needs a real codec,
/// and the previous version of this file tried to measure a live widget in the
/// host binding, where the image never decodes and every size stays null.
/// `integration_test/ui/watermark_gif_edge_test.dart` covers the real path on
/// a device.
void main() {
  const frame = Size(400, 300);

  test('an unmeasured layer is left where the finger put it', () {
    // Null means "the image has not decoded yet". Clamping with a guessed size
    // would snap the mark on its first drag.
    expect(clampWatermarkCenter(-1, 2, null, frame), const Offset(0, 1));
  });

  test('a measured layer stops with its edge on the frame edge', () {
    // 80 px wide in a 400 px frame: the centre may come 40 px = 0.1 from the
    // edge, which is exactly where the box touches it.
    final p = clampWatermarkCenter(-5, -5, const Size(80, 60), frame);
    expect(p.dx, closeTo(0.1, 1e-9));
    expect(p.dy, closeTo(0.1, 1e-9));
  });

  test('the far corner is symmetric', () {
    final p = clampWatermarkCenter(5, 5, const Size(80, 60), frame);
    expect(p.dx, closeTo(0.9, 1e-9));
    expect(p.dy, closeTo(0.9, 1e-9));
  });

  test('a layer wider than the frame is pinned to the centre', () {
    final p = clampWatermarkCenter(0, 1, const Size(800, 600), frame);
    expect(p, const Offset(0.5, 0.5));
  });

  test('a zero-size frame does not divide by zero', () {
    expect(
      clampWatermarkCenter(0.2, 0.3, const Size(10, 10), Size.zero),
      const Offset(0.2, 0.3),
    );
  });

  test('text and media follow the same rule', () {
    // Different sizes, same relationship: the inset is always half the box.
    for (final size in [const Size(40, 40), const Size(120, 90)]) {
      final p = clampWatermarkCenter(0, 0, size, frame);
      expect(p.dx, closeTo(size.width / 2 / frame.width, 1e-9));
      expect(p.dy, closeTo(size.height / 2 / frame.height, 1e-9));
    }
  });
}
