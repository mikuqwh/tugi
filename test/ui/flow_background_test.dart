// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ui/flow_background.dart';

/// The background loops forever. If the animation is not periodic, every
/// `repeat()` snaps back to a different frame -- the "flash" users see as the
/// video restarting.
void main() {
  const size = Size(400, 800);

  test('every blob returns to its starting point at the loop boundary', () {
    for (var i = 0; i < 6; i++) {
      final start = flowBlobCenter(i, 0, size);
      final end = flowBlobCenter(i, 1, size);
      expect(
        (end - start).distance,
        lessThan(0.5),
        reason: 'blob $i jumps ${(end - start).distance.toStringAsFixed(2)} px '
            'when the loop restarts',
      );
    }
  });

  test('the crossing is continuous: no step larger than a normal frame', () {
    // A 26 s loop at 60 fps moves t by ~0.00064 per frame.
    const step = 1 / 1560;
    for (var i = 0; i < 6; i++) {
      final before = flowBlobCenter(i, 1 - step, size);
      final after = flowBlobCenter(i, step, size);
      final across = (after - before).distance;
      // Compare with a step in the middle of the loop, where a jump could not
      // hide behind a slow section.
      final mid =
          (flowBlobCenter(i, 0.5 + step, size) - flowBlobCenter(i, 0.5, size))
              .distance;
      expect(
        across,
        lessThan(mid * 3 + 2),
        reason: 'blob $i moves ${across.toStringAsFixed(2)} px across the '
            'boundary vs ${mid.toStringAsFixed(2)} px mid-loop',
      );
    }
  });

  test('the blobs actually move', () {
    for (var i = 0; i < 6; i++) {
      final a = flowBlobCenter(i, 0.0, size);
      final b = flowBlobCenter(i, 0.25, size);
      expect((b - a).distance, greaterThan(10), reason: 'blob $i is frozen');
    }
  });

  test('no two blobs share a path (they would move as one)', () {
    for (var i = 0; i < 6; i++) {
      for (var j = i + 1; j < 6; j++) {
        final a = flowBlobCenter(i, 0.3, size);
        final b = flowBlobCenter(j, 0.3, size);
        expect((a - b).distance, greaterThan(8));
      }
    }
  });
}
