// SPDX-License-Identifier: GPL-3.0-or-later

/// Unit tests for the Edit GIF command builders (play speed + reverse).
///
/// Pure `package:test`, host VM, no ffmpeg -- same reason as the other suites
/// in test/ffmpeg/ (`flutter test` cannot connect to flutter_tester here).
///
/// The two bugs these pin, both found by running real files:
///
///  1. `-r 12` in the speed path re-resamples the timeline: a 77-frame /
///     5.14 s GIF came out as 63 frames / 5.25 s (14 frames silently gone).
///     Frame count and duration must be preserved at speed 1.0, so the
///     builders must never emit `-r`.
///
///  2. The palette must be the Edit path's transparent one
///     not Video to GIF's `stats_mode=single` template that an earlier
///     version borrowed.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:tugi/ffmpeg/commands.dart';
import 'package:test/test.dart';

void main() {
  String filterOf(List<String> args) =>
      args[args.indexOf('-filter_complex') + 1];

  group('editGifSpeed', () {
    test('puts the setpts multiplier into the filter chain', () {
      for (final speed in [0.2, 0.5, 1.0, 2.0]) {
        final args = editGifSpeed(
            inputPath: '/in.gif',
            outputPath: '/out.gif',
            speedMultiplier: speed);
        expect(filterOf(args), startsWith('setpts=$speed*PTS,'),
            reason: 'speed=$speed: ${filterOf(args)}');
      }
    });

    test('never emits -r (it silently drops frames)', () {
      for (final speed in [0.2, 0.5, 1.0, 2.0]) {
        final args = editGifSpeed(
            inputPath: '/in.gif',
            outputPath: '/out.gif',
            speedMultiplier: speed);
        expect(args, isNot(contains('-r')), reason: 'speed=$speed: $args');
      }
    });

    test('uses the transparent palette, not the videoToGif one', () {
      final args = editGifSpeed(
          inputPath: '/in.gif', outputPath: '/out.gif', speedMultiplier: 0.5);
      final f = filterOf(args);
      expect(
          f,
          contains('palettegen=reserve_transparent=on:'
              'transparency_color=ffffff'));
      expect(f, isNot(contains('stats_mode=single')), reason: f);
      expect(f, isNot(contains('paletteuse=new=1')), reason: f);
    });

    test('pre-stage stays unlabelled so [a]/[b] bind to split', () {
      final args = editGifSpeed(
          inputPath: '/in.gif', outputPath: '/out.gif', speedMultiplier: 2.0);
      final f = filterOf(args);
      expect(f, isNot(contains('[0:v]')), reason: f);
      expect(f, contains('setpts=2.0*PTS,split[a][b];'), reason: f);
    });

    test('gifflags arrive as two separate argv entries', () {
      // A single '-gifflags -offsetting' string is rejected with
      // "Unrecognized option 'gifflags -offsetting'".
      final args = editGifSpeed(
          inputPath: '/in.gif', outputPath: '/out.gif', speedMultiplier: 1.0);
      final at = args.indexOf('-gifflags');
      expect(at, greaterThan(-1), reason: '$args');
      expect(args[at + 1], '-offsetting', reason: '$args');
    });

    test('loop maps to 0/1 with the flag and value glued together', () {
      for (final loop in [true, false]) {
        final args = editGifSpeed(
            inputPath: '/in.gif',
            outputPath: '/out.gif',
            speedMultiplier: 0.5,
            loop: loop);
        final loopAt = args.indexOf('-loop');
        expect(loopAt, greaterThan(-1), reason: 'loop=$loop: $args');
        expect(args[loopAt + 1], loop ? '0' : '1',
            reason: 'loop=$loop should map to ${loop ? '0' : '1'}: $args');
      }
    });

    test('ends with -f gif and the output path, nothing dangling', () {
      for (final loop in [true, false]) {
        for (final speed in [0.2, 2.0]) {
          final args = editGifSpeed(
              inputPath: '/in.gif',
              outputPath: '/out.gif',
              speedMultiplier: speed,
              loop: loop);
          expect(args.last, '/out.gif', reason: '$args');
          final fmtAt = args.lastIndexOf('-f');
          expect(args[fmtAt + 1], 'gif', reason: '$args');
          expect(args.sublist(fmtAt + 2), ['/out.gif'], reason: '$args');
        }
      }
    });
  });

  group('editGifReverse', () {
    test('omits setpts entirely at speed 1.0', () {
      final args = editGifReverse(inputPath: '/in.gif', outputPath: '/out.gif');
      final f = filterOf(args);
      expect(f, startsWith('reverse,split[a][b];'), reason: f);
    });

    test('composes setpts after the reversal for other speeds', () {
      final args = editGifReverse(
          inputPath: '/in.gif', outputPath: '/out.gif', speedMultiplier: 0.5);
      expect(filterOf(args), startsWith('reverse,setpts=0.5*PTS,split[a][b];'),
          reason: filterOf(args));
    });

    test('keeps the speed-path invariants: no -r, transparent palette, loop',
        () {
      for (final loop in [true, false]) {
        for (final speed in [1.0, 0.5]) {
          final args = editGifReverse(
              inputPath: '/in.gif',
              outputPath: '/out.gif',
              speedMultiplier: speed,
              loop: loop);
          expect(args, isNot(contains('-r')), reason: '$args');
          expect(filterOf(args), contains('palettegen=reserve_transparent=on'));
          final loopAt = args.indexOf('-loop');
          expect(args[loopAt + 1], loop ? '0' : '1', reason: '$args');
          expect(args.last, '/out.gif', reason: '$args');
          final fmtAt = args.lastIndexOf('-f');
          expect(args.sublist(fmtAt + 2), ['/out.gif'], reason: '$args');
        }
      }
    });
  });
}
