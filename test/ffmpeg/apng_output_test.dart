// SPDX-License-Identifier: GPL-3.0-or-later

/// APNG as an alternative animation output.
///
/// APNG cannot ride the GIF palette tail (it is true-colour), and it must not
/// be resampled on the way out (the concat list already carries exact frame
/// durations). Both mistakes would "work" and quietly change the animation,
/// so they are pinned here.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/ffmpeg/commands.dart';

FormatSpec _gif = formatById('gif')!;
FormatSpec _apng = formatById('apng')!;

void main() {
  group('apngFromFrames', () {
    test('no palette pass, no gif muxer flags, explicit apng muxer', () {
      final args = apngFromFrames(
        concatListPath: 'list.txt',
        outputPath: 'out.apng',
      );
      final joined = args.join(' ');
      expect(joined, isNot(contains('palettegen')));
      expect(joined, isNot(contains('-gifflags')));
      expect(args, containsAllInOrder(['-f', 'apng', 'out.apng']));
    });

    test('loops via -plays, not -loop', () {
      final loop = apngFromFrames(
        concatListPath: 'list.txt',
        outputPath: 'out.apng',
        loop: true,
      );
      final once = apngFromFrames(
        concatListPath: 'list.txt',
        outputPath: 'out.apng',
        loop: false,
      );
      expect(loop, containsAllInOrder(['-plays', '0']));
      expect(once, containsAllInOrder(['-plays', '1']));
      expect(loop, isNot(contains('-loop')));
    });

    test('does not resample: no -r and no fps filter', () {
      // The concat list's own durations are the timing. `-r` or `fps=` would
      // quantise them a second time and drop frames (measured for the GIF
      // path and for Edit GIF).
      final args = apngFromFrames(
        concatListPath: 'list.txt',
        outputPath: 'out.apng',
        prefixFilter: 'scale=320:-2',
      );
      final joined = args.join(' ');
      expect(joined, isNot(contains(' -r ')));
      expect(joined, isNot(contains('fps=')));
      expect(args[args.indexOf('-filter_complex') + 1], 'scale=320:-2');
    });
  });

  group('editGifSpeed / editGifReverse with APNG', () {
    test('speed keeps setpts but drops the palette tail', () {
      final args = editGifSpeed(
        inputPath: 'in.gif',
        outputPath: 'out.apng',
        speedMultiplier: 1.5,
        format: _apng,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, 'setpts=1.5*PTS');
      expect(filter, isNot(contains('palettegen')));
      expect(args, containsAllInOrder(['-f', 'apng']));
    });

    test('reverse keeps the reverse filter, and no gif flags', () {
      final args = editGifReverse(
        inputPath: 'in.gif',
        outputPath: 'out.apng',
        speedMultiplier: 2.0,
        format: _apng,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, 'reverse,setpts=2.0*PTS');
      expect(args.join(' '), isNot(contains('palettegen')));
      expect(args.join(' '), isNot(contains('-gifflags')));
    });

    test('passing no format keeps the GIF shape exactly', () {
      final speed = editGifSpeed(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        speedMultiplier: 1.0,
      );
      final filter = speed[speed.indexOf('-filter_complex') + 1];
      expect(filter, contains('palettegen'));
      expect(speed, containsAllInOrder(['-f', 'gif']));
    });
  });

  group('watermark APNG', () {
    WatermarkLayerSpec textLayer() => const WatermarkLayerSpec(
          kind: WatermarkLayerKind.text,
          placement: WatermarkPlacement.anchor(
            WatermarkPosition.bottomRight,
          ),
          textFilePath: 't.txt',
          fontFilePath: 'f.ttf',
        );

    test('animated output as APNG skips the palette tail', () {
      final args = addWatermarks(
        inputPath: 'in.gif',
        outputPath: 'out.apng',
        kind: WatermarkMediaKind.gif,
        layers: [textLayer()],
        format: _apng,
      );
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(graph, isNot(contains('palettegen')));
      expect(args, containsAllInOrder(['-f', 'apng']));
      expect(args, containsAllInOrder(['-plays', '0']));
    });

    test('GIF output is untouched when no format is given', () {
      final args = addWatermarks(
        inputPath: 'in.gif',
        outputPath: 'out.gif',
        kind: WatermarkMediaKind.gif,
        layers: [textLayer()],
      );
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(graph, contains('palettegen'));
      expect(args, containsAllInOrder(['-f', 'gif']));
    });

    test('an APNG request for a VIDEO target still uses the video encoder', () {
      // The format only changes the animated branch; a video kind keeps its
      // encoder so a mismatched call cannot produce an apng-named mp4.
      final args = addWatermarks(
        inputPath: 'in.mp4',
        outputPath: 'out.mp4',
        kind: WatermarkMediaKind.video,
        layers: [textLayer()],
        format: formatById('mp4_h264'),
      );
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
    });
  });
}
