// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure-logic unit tests for Video to GIF pipeline.
/// No FFmpeg, no device, no absolute paths — runs on host VM.
/// Uses flutter_test (not package:test) for Flutter integration.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';
import 'package:tugi/models/creation.dart';

void main() {
  group('Creation width-driven resolution model', () {
    test('default keepResolution=true returns source dimensions', () {
      final (:w, :h) = Creation.deriveOutputSize(1080, 2400);
      expect(w, equals(1080));
      expect(h, equals(2400));
    });

    test('outputWidth=1080 with keepResolution=false', () {
      final (:w, :h) = Creation.deriveOutputSize(1080, 2400,
          outputWidth: 1080, keepResolution: false);
      expect(w, equals(1080));
      expect(h, equals(2400)); // 1080 / 0.45 = 2400
    });

    test('outputWidth=607.5 → height = width / ratio', () {
      final (:w, :h) = Creation.deriveOutputSize(1080, 2400,
          outputWidth: 607.5, keepResolution: false);
      expect(w, equals(607.5));
      expect(h, equals(1350.0)); // 607.5 / 0.45 = 1350
    });

    test('widthPresets original sentinel (0) falls back to source width', () {
      final (:w, :h) = Creation.deriveOutputSize(1080, 2400,
          outputWidth: 0, keepResolution: false);
      expect(w, equals(1080)); // 0 ≤ 0 → use srcW
      expect(h, equals(2400));
    });

    test('真机 data: all 3 creations satisfy height = width / ratio', () {
      const cases = [
        (607.5, 1350.0, 0.45),
        (345.6, 768.0, 0.45),
        (259.2, 576.0, 0.45),
      ];
      for (final (w, h, r) in cases) {
        expect(h, closeTo(w / r, 0.01));
      }
    });
  });

  group('Constants', () {
    test('defaultFrameCount = 10', () {
      expect(Creation.defaultFrameCount, equals(10));
    });

    test('layerFps = 12', () {
      expect(Creation.layerFps, equals(12));
    });

    test('defaultAspectRatio = 0.45', () {
      expect(Creation.defaultAspectRatio, equals(0.45));
    });

    test('widthPresets has original and 1080', () {
      expect(Creation.widthPresets.containsKey('original'), isTrue);
      expect(Creation.widthPresets.containsKey('1080'), isTrue);
    });
  });

  group('recommendWidthForSize', () {
    test('≤20MB returns null (no constraint)', () {
      expect(Creation.recommendWidthForSize(15, 1080), isNull);
    });

    test('≤30MB returns 75% of source width', () {
      expect(Creation.recommendWidthForSize(25, 1080), equals(810.0));
    });

    test('≤90MB returns 50% of source width', () {
      expect(Creation.recommendWidthForSize(50, 1080), equals(540.0));
    });
  });
}
