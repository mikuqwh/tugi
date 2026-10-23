// SPDX-License-Identifier: GPL-3.0-or-later

/// Compress GIFs command shapes.
///
/// The resolution pipeline was verified byte-for-byte against this app
/// in 2026-10-15; what is new here is the Extract Frames mode, whose shape is
/// pinned so a change to the frame-rate maths cannot pass unnoticed.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ffmpeg/commands.dart';

String filterOf(List<String> args) => args[args.indexOf('-filter_complex') + 1];

void main() {
  group('compressGif (Reduce Resolution)', () {
    test('scales by the ratio and re-quantises after the scale', () {
      final args = compressGif(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        ratio: 0.5,
      );
      final filter = filterOf(args);
      expect(filter, startsWith('[0:v]scale=iw*0.5:-1:flags=lanczos,'));
      // The palette has to be built from the SCALED frames, so the split
      // comes after the scale.
      expect(
          filter,
          contains('split[a][b];[a]palettegen=reserve_transparent=on:'
              'transparency_color=ffffff[p];[b][p]paletteuse'));
      expect(args, isNot(contains('-ignore_loop')));
      expect(args, contains('-loop'));
      expect(args.last, 'out.gif');
    });
  });

  group('compressGifByFrames (Extract Frames)', () {
    test('asks for sourceFps / step', () {
      final args = compressGifByFrames(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        sourceFps: 20,
        frameStep: 4,
      );
      final filter = filterOf(args);
      // 20 / 4 = 5 fps, six decimals so a fractional rate is not rounded
      // into a drift.
      expect(filter, startsWith('[0:v]fps=5.000000,'));
      expect(filter, contains('palettegen'));
      expect(args.last, 'out.gif');
    });

    test('a fractional rate keeps its decimals', () {
      // 20 / 3 = 6.666...: rounding to 6.67 over 3 s is 20.0 frames either
      // way, but the exact value avoids drift on longer sources.
      final args = compressGifByFrames(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        sourceFps: 20,
        frameStep: 3,
      );
      expect(filterOf(args), startsWith('[0:v]fps=6.666667,'));
    });

    test('a step below 2 is treated as no thinning', () {
      final args = compressGifByFrames(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        sourceFps: 12,
        frameStep: 1,
      );
      expect(filterOf(args), startsWith('[0:v]fps=12.000000,'));
    });

    test('an unknown source rate falls back to 10 fps, not to zero', () {
      // fps=0 would make ffmpeg fail; a GIF whose rate could not be parsed
      // still has to compress.
      final args = compressGifByFrames(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        sourceFps: 0,
        frameStep: 2,
      );
      expect(filterOf(args), startsWith('[0:v]fps=5.000000,'));
    });

    test('keeps the GIF muxer flags and the loop setting', () {
      final args = compressGifByFrames(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        sourceFps: 10,
        frameStep: 2,
        loop: false,
      );
      expect(args, containsAllInOrder(['-gifflags', '-offsetting']));
      expect(args[args.indexOf('-loop') + 1], '1');
    });
  });
}
