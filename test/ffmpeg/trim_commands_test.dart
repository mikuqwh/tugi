// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:format_core/format_core.dart';
import 'package:tugi/ffmpeg/commands.dart';
import 'package:tugi/models/encode_preset.dart';

void main() {
  group('videoToGif trim', () {
    test('no trim keeps the argv shape untouched', () {
      final args = videoToGif(inputPath: 'a.mp4', outputPath: 'o.gif');
      expect(args.contains('-ss'), isFalse);
      expect(args.contains('-t'), isFalse);
      expect(args[args.indexOf('-i') - 1], '-y');
    });

    test('a start lands as -ss before -i', () {
      final args = videoToGif(
        inputPath: 'a.mp4',
        outputPath: 'o.gif',
        start: 2.5,
        duration: 3,
      );
      final ss = args.indexOf('-ss');
      final t = args.indexOf('-t');
      final input = args.indexOf('-i');
      expect(ss, greaterThan(-1));
      expect(args[ss + 1], '2.500');
      expect(args[t + 1], '3.000');
      // Both must precede the input: that is what makes it a fast seek.
      expect(ss, lessThan(input));
      expect(t, lessThan(input));
    });

    test('a zero start does not emit -ss', () {
      final args = videoToGif(
        inputPath: 'a.mp4',
        outputPath: 'o.gif',
        start: 0,
        duration: 2,
      );
      expect(args.contains('-ss'), isFalse);
      expect(args[args.indexOf('-t') + 1], '2.000');
    });
  });

  group('crop', () {
    test('video: crop leads the chain, before fps and split', () {
      final args = videoToGif(
        inputPath: 'a.mp4',
        outputPath: 'o.gif',
        crop: 'crop=640:360:100:50',
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('crop=640:360:100:50,fps=12,'));
    });

    test('video: trim and crop compose (seek outside, crop inside)', () {
      final args = videoToGif(
        inputPath: 'a.mp4',
        outputPath: 'o.gif',
        start: 1,
        duration: 2,
        crop: 'crop=320:240:0:0',
      );
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('crop=320:240:0:0,fps=12,'));
    });

    test('apng: crop is the first -vf stage', () {
      final args = videoToApng(
        inputPath: 'a.mp4',
        outputPath: 'o.apng',
        crop: 'crop=100:100:4:4',
      );
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, startsWith('crop=100:100:4:4,fps=12'));
    });

    test('gif speed: trim, crop, then the rebased speed', () {
      final args = editGifSpeed(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        speedMultiplier: 1,
        start: 1,
        end: 3,
        crop: 'crop=200:200:0:0',
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
          filter,
          startsWith(
            'trim=start=1.000:end=3.000,crop=200:200:0:0,setpts=1.0*(PTS-STARTPTS)',
          ));
    });

    test('gif reverse: crop after trim, before reverse', () {
      final args = editGifReverse(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        start: 1,
        end: 3,
        crop: 'crop=200:200:0:0',
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
          filter,
          startsWith(
            'trim=start=1.000:end=3.000,crop=200:200:0:0,reverse',
          ));
    });

    test('no crop leaves the argv untouched', () {
      final args = videoToGif(inputPath: 'a.mp4', outputPath: 'o.gif');
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('fps=12,'));
    });
  });

  group('encode presets', () {
    test('fast: 128 colours and bayer dithering', () {
      final args = videoToGif(
        inputPath: 'a.mp4',
        outputPath: 'o.gif',
        preset: EncodePreset.fast,
      );
      final f = args[args.indexOf('-filter_complex') + 1];
      expect(f, contains('max_colors=128'));
      expect(f, contains('dither=bayer:bayer_scale=5'));
    });

    test('high: full stats mode', () {
      final args = videoToGif(
        inputPath: 'a.mp4',
        outputPath: 'o.gif',
        preset: EncodePreset.high,
      );
      final f = args[args.indexOf('-filter_complex') + 1];
      expect(f, contains('stats_mode=full'));
    });

    test('the default is balanced and unchanged', () {
      final f = videoToGif(inputPath: 'a.mp4', outputPath: 'o.gif');
      final filter = f[f.indexOf('-filter_complex') + 1];
      expect(filter, contains('max_colors=256'));
      expect(filter, contains('dither=sierra2_4a'));
    });

    test('edit GIF honours the preset', () {
      final args = editGifSpeed(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        speedMultiplier: 1,
        preset: EncodePreset.fast,
      );
      final f = args[args.indexOf('-filter_complex') + 1];
      expect(f, contains('max_colors=128'));
      expect(f, contains('stats_mode=single'));
    });
  });

  group('videoToApng trim', () {
    test('carries the same input-side trim', () {
      final args = videoToApng(
        inputPath: 'a.mp4',
        outputPath: 'o.apng',
        start: 1,
      );
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
      expect(args[args.indexOf('-ss') + 1], '1.000');
    });
  });

  group('editGifSpeed trim', () {
    test('trim rebases the timestamps before the speed stage', () {
      final args = editGifSpeed(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        speedMultiplier: 2,
        start: 1.5,
        end: 4,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('trim=start=1.500:end=4.000,'));
      // Without the rebase the kept segment would start at 1.5 s and the
      // output would carry 1.5 s of dead time.
      expect(filter, contains('setpts=2.0*(PTS-STARTPTS)'));
    });

    test('an untrimmed edit is unchanged', () {
      final args = editGifSpeed(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        speedMultiplier: 2,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('setpts=2.0*PTS'));
      expect(filter, isNot(contains('trim=')));
    });
  });

  group('editGifReverse trim', () {
    test('trims before reversing so the buffer only holds the segment', () {
      final args = editGifReverse(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        speedMultiplier: 1,
        start: 2,
        end: 5,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('trim=start=2.000:end=5.000,reverse'));
    });

    test('reverse without trim does not rebase PTS', () {
      final args = editGifReverse(
        inputPath: 'a.gif',
        outputPath: 'o.gif',
        speedMultiplier: 0.5,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, startsWith('reverse,setpts=0.5*PTS'));
    });
  });
}
