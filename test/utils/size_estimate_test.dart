/// The size bands shown in the UI.
///
/// The bands come from `tool/wmprobe/calibrate_compress.sh`; these tests pin
/// the CONTRACT of the estimator (ordering, clamping, monotonicity), not one
/// exact number, because the numbers are measured ranges and will be
/// re-calibrated if a pipeline changes.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/utils/size_estimate.dart';

void main() {
  group('estimateCompressedGif', () {
    const input = 1000000;

    test('returns an ordered range that fits inside the input', () {
      for (final ratio in [0.8, 0.5, 0.2, 0.05, 0.99]) {
        final e = estimateCompressedGif(input, ratio);
        expect(e.lowBytes, greaterThan(0), reason: '$ratio');
        expect(e.lowBytes, lessThanOrEqualTo(e.highBytes), reason: '$ratio');
        expect(e.highBytes, lessThanOrEqualTo(input), reason: '$ratio');
      }
    });

    test('smaller ratios predict smaller files', () {
      final a = estimateCompressedGif(input, 0.8).midBytes;
      final b = estimateCompressedGif(input, 0.5).midBytes;
      final c = estimateCompressedGif(input, 0.2).midBytes;
      expect(a, greaterThan(b));
      expect(b, greaterThan(c));
    });

    test('the band brackets every measured 0.5 case', () {
      // Measured at ratio 0.5: 0.3594 (test pattern), 0.3312 (noisy
      // gradient), 0.5057 (flat colour) of the input bytes. A band that
      // misses one of those is too narrow to be honest.
      final e = estimateCompressedGif(input, 0.5);
      expect(e.lowBytes / input, lessThanOrEqualTo(0.3312));
      expect(e.highBytes / input, greaterThanOrEqualTo(0.5057));
    });

    test('ratio 1 predicts no change', () {
      final e = estimateCompressedGif(input, 1.0);
      expect(e.lowBytes, input);
      expect(e.highBytes, input);
    });

    test('nonsense input predicts nothing rather than throwing', () {
      expect(estimateCompressedGif(0, 0.5).isValid, isFalse);
      expect(estimateCompressedGif(input, 0).isValid, isFalse);
      expect(estimateCompressedGif(input, -1).isValid, isFalse);
    });
  });

  group('estimateFrameStepGif', () {
    const input = 1000000;

    test('kept fraction drives the estimate', () {
      final half = estimateFrameStepGif(input, 60, 2);
      final third = estimateFrameStepGif(input, 60, 3);
      expect(half.midBytes, greaterThan(third.midBytes));
      // Step 3 of 60 frames keeps 20: a third of the bytes, +/- the measured
      // 0.80..1.08 spread.
      expect(third.lowBytes, closeTo(input * 20 / 60 * 0.80, 2));
      expect(third.highBytes, closeTo(input * 20 / 60 * 1.08, 2));
    });

    test('a step of 1 (or less) means no change', () {
      final e = estimateFrameStepGif(input, 60, 1);
      expect(e.lowBytes, input);
      expect(e.highBytes, input);
    });

    test('an unparseable source yields no shrink claim', () {
      // The screen leaves the frame count at 0 when GifReader cannot parse
      // the file; promising a saving there would be a guess.
      final e = estimateFrameStepGif(input, 0, 3);
      expect(e.lowBytes, input);
      expect(e.highBytes, input);
    });

    test('a stride larger than the frame count keeps one frame', () {
      final e = estimateFrameStepGif(input, 5, 50);
      expect(e.lowBytes, greaterThan(0));
      expect(e.highBytes, lessThanOrEqualTo(input));
    });
  });

  group('estimateImageBytes', () {
    const spec = 800;

    test('uncompressed targets are pixel maths, not a band', () {
      final bmp = estimateImageBytes(
        inputBytes: 500000,
        width: 800,
        height: 600,
        format: formatById('bmp')!,
        quality: 85,
      );
      // 800*600*3 = 1 440 000 bytes, exact by construction.
      expect(bmp.lowBytes, 1440000);
      expect(bmp.highBytes, 1440000);

      // BMP is the only truly exact one; TIFF and EXR depend on sparsity.
      final tiff = estimateImageBytes(
        inputBytes: 500000,
        width: 800,
        height: 600,
        format: formatById('tiff')!,
        quality: 85,
      );
      expect(tiff.lowBytes, 1440000);
      expect(tiff.highBytes, greaterThan(tiff.lowBytes));
    });

    test('a compressed target is a band of the source size', () {
      final jpg = estimateImageBytes(
        inputBytes: 1000000,
        width: 4000,
        height: 3000,
        format: formatById('jpg')!,
        quality: 85,
      );
      expect(jpg.lowBytes, lessThan(jpg.highBytes));
      expect(jpg.lowBytes, greaterThan(200000));
      expect(jpg.highBytes, lessThan(2000000));
    });

    test('a higher quality predicts a bigger file', () {
      final low = estimateImageBytes(
        inputBytes: 1000000,
        width: 4000,
        height: 3000,
        format: formatById('jpg')!,
        quality: 40,
      );
      final high = estimateImageBytes(
        inputBytes: 1000000,
        width: 4000,
        height: 3000,
        format: formatById('jpg')!,
        quality: 95,
      );
      expect(high.midBytes, greaterThan(low.midBytes));
    });

    test('quality does not move a lossless target', () {
      final a = estimateImageBytes(
        inputBytes: 1000000,
        width: 4000,
        height: 3000,
        format: formatById('png')!,
        quality: 30,
      );
      final b = estimateImageBytes(
        inputBytes: 1000000,
        width: 4000,
        height: 3000,
        format: formatById('png')!,
        quality: 95,
      );
      expect(a.midBytes, b.midBytes);
    });

    test('missing geometry predicts nothing', () {
      final e = estimateImageBytes(
        inputBytes: 1000,
        width: 0,
        height: 0,
        format: formatById('jpg')!,
        quality: 85,
      );
      expect(e.isValid, isFalse);
    });

    test('only the deterministic formats claim an exact estimate', () {
      expect(isExactImageEstimate(formatById('bmp')!), isTrue);
      expect(isExactImageEstimate(formatById('jpg')!), isFalse);
      expect(isExactImageEstimate(formatById('exr')!), isFalse);
      expect(spec, 800);
    });
  });

  test('savingsPercent reports the midpoint saving', () {
    final e = estimateCompressedGif(1000000, 0.5);
    expect(e.savingsPercent(1000000), inInclusiveRange(40, 70));
    // Guarding against a divide-by-zero on an unknown input size.
    expect(e.savingsPercent(0), 0);
  });

  group('estimateAudioBytes', () {
    test('is arithmetic: kbps x seconds', () {
      // 128 kbps for 60 s = 960 000 bytes.
      final e = estimateAudioBytes(
        bitrateKbps: 128,
        duration: const Duration(seconds: 60),
      );
      expect(e.lowBytes, closeTo(960000 * 0.97, 2));
      expect(e.highBytes, closeTo(960000 * 1.02, 2));
      expect(e.midBytes, closeTo(960000, 25000));
    });

    test('scales with duration and bitrate', () {
      final short = estimateAudioBytes(
          bitrateKbps: 128, duration: const Duration(seconds: 10));
      final long = estimateAudioBytes(
          bitrateKbps: 128, duration: const Duration(seconds: 20));
      final loud = estimateAudioBytes(
          bitrateKbps: 320, duration: const Duration(seconds: 10));
      expect(long.midBytes, greaterThan(short.midBytes));
      expect(loud.midBytes, greaterThan(short.midBytes));
    });

    test('unknown bitrate or duration predicts nothing', () {
      expect(
          estimateAudioBytes(
                  bitrateKbps: 0, duration: const Duration(seconds: 10))
              .isValid,
          isFalse);
      expect(
          estimateAudioBytes(bitrateKbps: 128, duration: Duration.zero).isValid,
          isFalse);
    });
  });
}
