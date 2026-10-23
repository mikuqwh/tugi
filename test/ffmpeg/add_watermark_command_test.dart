/// Add Watermark — ffmpeg command construction.
///
/// Pure Dart, no Flutter, so this runs on the host VM with `dart test`.
///
/// The command builders are verified against real ffmpeg output by
/// `tool/wmprobe/probe.sh`; these tests pin the SHAPE of the command so a
/// future edit cannot quietly reintroduce a filtergraph that ffmpeg
/// rejects.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tugi/ffmpeg/commands.dart';

void main() {
  group('watermarkPositionExpression', () {
    test('centre uses the exact expressions the original assembles', () {
      expect(
        watermarkPositionExpression(
          WatermarkPosition.center,
          sizeVar: 'text_w/text_h',
        ),
        'x=main_w/2-text_w/2:y=main_h/2-text_h/2',
      );
    });

    test('bottom-centre uses the original bottom expression', () {
      //
      // The previous implementation's fragment ends in a bare `-`: it is a PREFIX, and the
      // margin number is appended to it. A trailing `-` on its own would not
      // even parse in ffmpeg's expression evaluator.
      expect(
        watermarkPositionExpression(
          WatermarkPosition.bottomCenter,
          sizeVar: 'text_w/text_h',
        ),
        'x=main_w/2-text_w/2:y=main_h-text_h-10',
      );
      expect(
        watermarkPositionExpression(
          WatermarkPosition.bottomCenter,
          sizeVar: 'text_w/text_h',
          margin: 0,
        ),
        'x=main_w/2-text_w/2:y=main_h-text_h-0',
      );
    });

    test('right edge keeps the 10px margin the original uses', () {
      expect(
        watermarkPositionExpression(
          WatermarkPosition.bottomRight,
          sizeVar: 'overlay_w/overlay_h',
        ),
        'x=main_w-overlay_w-10:y=main_h-overlay_h-10',
      );
    });

    test('the size variables are swapped in, not hardcoded', () {
      final text = watermarkPositionExpression(
        WatermarkPosition.center,
        sizeVar: 'text_w/text_h',
      );
      final overlay = watermarkPositionExpression(
        WatermarkPosition.center,
        sizeVar: 'overlay_w/overlay_h',
      );
      expect(text, contains('text_w'));
      expect(text, isNot(contains('overlay_w')));
      expect(overlay, contains('overlay_w'));
      expect(overlay, isNot(contains('text_w')));
    });

    test('every position produces an x and a y', () {
      for (final p in WatermarkPosition.values) {
        final expr = watermarkPositionExpression(p, sizeVar: 'text_w/text_h');
        expect(expr, startsWith('x='), reason: '$p');
        expect(expr, contains(':y='), reason: '$p');
      }
    });

    test('all nine anchors are covered', () {
      expect(WatermarkPosition.values, hasLength(9));
    });
  });

  group('drawtextWatermarkFilter', () {
    test('the text is NOT spliced into the filtergraph', () {
      // The whole point of textfile=+expansion=none: a watermark with a
      // percent sign or a colon must never reach the filter string.
      final filter = drawtextWatermarkFilter(
        fontFilePath: '/data/font.ttf',
        textFilePath: '/data/text.txt',
        fontSize: 24,
        fontColor: 'white',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      expect(filter, isNot(contains("text='")));
      expect(filter, contains('textfile=/data/text.txt'));
      expect(filter, contains('expansion=none'));
    });

    test('fontfile is always present -- there is no system-font fallback', () {
      final filter = drawtextWatermarkFilter(
        fontFilePath: '/data/font.ttf',
        textFilePath: '/data/text.txt',
        fontSize: 24,
        fontColor: 'white',
        placement: const WatermarkPlacement.anchor(WatermarkPosition.center),
      );
      expect(filter, contains('fontfile=/data/font.ttf'));
    });

    test('opacity becomes an alpha suffix on the colour', () {
      final filter = drawtextWatermarkFilter(
        fontFilePath: '/data/font.ttf',
        textFilePath: '/data/text.txt',
        fontSize: 24,
        fontColor: 'white',
        placement: const WatermarkPlacement.anchor(WatermarkPosition.center),
        opacity: 0.5,
      );
      expect(filter, contains('fontcolor=white@0.500'));
    });

    test('full opacity leaves the colour bare', () {
      final filter = drawtextWatermarkFilter(
        fontFilePath: '/data/font.ttf',
        textFilePath: '/data/text.txt',
        fontSize: 24,
        fontColor: 'white',
        placement: const WatermarkPlacement.anchor(WatermarkPosition.center),
        opacity: 1.0,
      );
      expect(filter, contains('fontcolor=white:'));
      expect(filter, isNot(contains('@')));
    });

    test('font size and position are carried through', () {
      final filter = drawtextWatermarkFilter(
        fontFilePath: '/data/font.ttf',
        textFilePath: '/data/text.txt',
        fontSize: 48,
        fontColor: 'red',
        placement: const WatermarkPlacement.anchor(WatermarkPosition.topLeft),
      );
      expect(filter, contains('fontsize=48'));
      expect(filter, contains('x=0:y=0'));
    });
  });

  group('overlayWatermarkAlphaStage', () {
    test('always normalises to rgba', () {
      expect(overlayWatermarkAlphaStage(1.0), 'format=rgba');
    });

    test('scales the alpha channel when an opacity is given', () {
      expect(
        overlayWatermarkAlphaStage(0.5),
        'format=rgba,colorchannelmixer=aa=0.500',
      );
    });
  });

  group('overlayWatermarkFilter', () {
    test('position is positional, the way the original spells it', () {
      expect(
        overlayWatermarkFilter(
          placement: const WatermarkPlacement.anchor(WatermarkPosition.center),
        ),
        'overlay=main_w/2-overlay_w/2:main_h/2-overlay_h/2',
      );
    });

    test('bottom-right keeps the original 10px inset', () {
      expect(
        overlayWatermarkFilter(
          placement:
              const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
        ),
        'overlay=main_w-overlay_w-10:main_h-overlay_h-10',
      );
    });
  });

  group('addWatermarkText', () {
    test('a GIF output applies the watermark BEFORE the palette split', () {
      final args = addWatermarkText(
        inputPath: '/in.gif',
        outputPath: '/out.gif',
        textFilePath: '/data/text.txt',
        fontFilePath: '/data/font.ttf',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
          filter.indexOf('drawtext'), lessThan(filter.indexOf('palettegen')));
      expect(filter, endsWith(watermarkGifTail));
    });

    test('a GIF output carries the GIF muxer flags', () {
      final args = addWatermarkText(
        inputPath: '/in.gif',
        outputPath: '/out.gif',
        textFilePath: '/data/text.txt',
        fontFilePath: '/data/font.ttf',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      expect(args, containsAllInOrder(['-gifflags', '-offsetting']));
      expect(args, containsAllInOrder(['-f', 'gif']));
      expect(args.last, '/out.gif');
    });

    test('looping off is requested explicitly', () {
      // `-loop 1` = play once. Omitting the flag does NOT turn looping off.
      final args = addWatermarkText(
        inputPath: '/in.gif',
        outputPath: '/out.gif',
        textFilePath: '/data/text.txt',
        fontFilePath: '/data/font.ttf',
        loop: false,
      );
      expect(args, containsAllInOrder(['-loop', '1']));
    });

    test('a still image output has no palette tail', () {
      final args = addWatermarkText(
        inputPath: '/in.png',
        outputPath: '/out.png',
        textFilePath: '/data/text.txt',
        fontFilePath: '/data/font.ttf',
        kind: WatermarkMediaKind.image,
      );
      expect(args, isNot(contains('-filter_complex')));
      expect(args, contains('-vf'));
      expect(args, isNot(contains('palettegen')));
    });

    test('no -r: the GIF keeps its own frame timing', () {
      // `-r` resamples and silently drops frames; the source GIF already
      // has the right pacing.
      final args = addWatermarkText(
        inputPath: '/in.gif',
        outputPath: '/out.gif',
        textFilePath: '/data/text.txt',
        fontFilePath: '/data/font.ttf',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      expect(args, isNot(contains('-r')));
    });

    test('a video output is H.264 with a faststart moov', () {
      final args = addWatermarkText(
        inputPath: '/in.mp4',
        outputPath: '/out.mp4',
        textFilePath: '/data/text.txt',
        fontFilePath: '/data/font.ttf',
        kind: WatermarkMediaKind.video,
      );
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args, isNot(contains('palettegen')));
    });
  });

  group('addWatermarkImage', () {
    test('the watermark is the SECOND input', () {
      final args = addWatermarkImage(
        inputPath: '/in.gif',
        watermarkPath: '/wm.png',
        outputPath: '/out.gif',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      final first = args.indexOf('-i');
      final second = args.indexOf('-i', first + 1);
      expect(args[first + 1], '/in.gif');
      expect(args[second + 1], '/wm.png');
    });

    test('the alpha stage runs on the watermark branch, before the overlay',
        () {
      final args = addWatermarkImage(
        inputPath: '/in.gif',
        watermarkPath: '/wm.png',
        outputPath: '/out.gif',
        opacity: 0.4,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
          filter, contains('[1:v]format=rgba,colorchannelmixer=aa=0.400[wm]'));
      expect(filter.indexOf('colorchannelmixer'),
          lessThan(filter.indexOf('overlay=')));
    });

    test('the overlay consumes the prepared watermark branch', () {
      final args = addWatermarkImage(
        inputPath: '/in.gif',
        watermarkPath: '/wm.png',
        outputPath: '/out.gif',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('[0:v][wm]overlay='));
    });

    test('a GIF output applies the watermark BEFORE the palette split', () {
      final args = addWatermarkImage(
        inputPath: '/in.gif',
        watermarkPath: '/wm.png',
        outputPath: '/out.gif',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
          filter.indexOf('overlay='), lessThan(filter.indexOf('palettegen')));
      expect(filter, endsWith(watermarkGifTail));
    });

    test('a still image output has no palette tail', () {
      final args = addWatermarkImage(
        inputPath: '/in.png',
        watermarkPath: '/wm.png',
        outputPath: '/out.png',
        kind: WatermarkMediaKind.image,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, isNot(contains('palettegen')));
    });

    test('a watermark width scales the watermark branch', () {
      final args = addWatermarkImage(
        inputPath: '/in.gif',
        watermarkPath: '/wm.png',
        outputPath: '/out.gif',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
        watermarkWidth: 120,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('[1:v]scale=120:-1,format=rgba[wm]'));
    });

    test('no watermark width leaves the scale stage out', () {
      final args = addWatermarkImage(
        inputPath: '/in.gif',
        watermarkPath: '/wm.png',
        outputPath: '/out.gif',
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, isNot(contains('scale=')));
    });

    test('a video output is H.264', () {
      final args = addWatermarkImage(
        inputPath: '/in.mp4',
        watermarkPath: '/wm.png',
        outputPath: '/out.mp4',
        kind: WatermarkMediaKind.video,
      );
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, isNot(contains('palettegen')));
    });
  });

  group('addWatermarkGif', () {
    test('the watermark is looped and cut at the base length', () {
      // Both are mandatory together: an infinitely looping input never
      // ends, so without shortest=1 the output runs away (measured: 19306
      // frames / 2436 s from a 2 s source).
      final args = addWatermarkGif(
        inputPath: '/in.gif',
        watermarkPath: '/wm.gif',
        outputPath: '/out.gif',
        watermarkFrames: 40,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('loop=loop=-1:size=40'));
      expect(
          filter,
          contains(
              'overlay=main_w-overlay_w-10:main_h-overlay_h-10:shortest=1'));
      expect(filter, endsWith(watermarkGifTail));
    });

    test('the buffer size comes from the real frame count', () {
      // size too small silently breaks the animation (size=1 freezes it,
      // size=0 truncated the output); too large is harmless.
      for (final n in [1, 8, 100, 512]) {
        final args = addWatermarkGif(
          inputPath: '/in.gif',
          watermarkPath: '/wm.gif',
          outputPath: '/out.gif',
          watermarkFrames: n,
        );
        final filter = args[args.indexOf('-filter_complex') + 1];
        expect(filter, contains('size=$n'), reason: '$n frames');
      }
    });

    test('a silly frame count cannot produce a zero-size buffer', () {
      final args = addWatermarkGif(
        inputPath: '/in.gif',
        watermarkPath: '/wm.gif',
        outputPath: '/out.gif',
        watermarkFrames: 0,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('size=1'));
      expect(filter, isNot(contains('size=0')));
    });

    test('a video source is H.264 with no palette tail', () {
      final args = addWatermarkGif(
        inputPath: '/in.mp4',
        watermarkPath: '/wm.gif',
        outputPath: '/out.mp4',
        kind: WatermarkMediaKind.video,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('loop=loop=-1'));
      expect(filter, contains(':shortest=1'));
      expect(filter, isNot(contains('palettegen')));
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
    });

    test('a still image source keeps the palette tail and drops the loop', () {
      // A still image with an animated watermark: the output IS a GIF and
      // its length follows the watermark. Looping is neither needed nor
      // possible -- there is no base length to cut at, so shortest=1 would
      // truncate the output to one frame.
      final args = addWatermarkGif(
        inputPath: '/in.png',
        watermarkPath: '/wm.gif',
        outputPath: '/out.gif',
        kind: WatermarkMediaKind.image,
        watermarkFrames: 40,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, isNot(contains('loop=')));
      expect(filter, isNot(contains('shortest=1')));
      expect(filter, endsWith(watermarkGifTail));
    });

    test('the watermark width is scaled before the loop', () {
      final args = addWatermarkGif(
        inputPath: '/in.gif',
        watermarkPath: '/wm.gif',
        outputPath: '/out.gif',
        watermarkFrames: 40,
        watermarkWidth: 90,
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter,
          contains('[1:v]scale=90:-1,format=rgba,loop=loop=-1:size=40[wm]'));
    });

    test('a free placement reaches the GIF variant too', () {
      final args = addWatermarkGif(
        inputPath: '/in.gif',
        watermarkPath: '/wm.gif',
        outputPath: '/out.gif',
        watermarkFrames: 40,
        placement: const WatermarkPlacement.free(0.3, 0.6),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
          filter,
          contains(
              'overlay=0.3*main_w-overlay_w/2:0.6*main_h-overlay_h/2:shortest=1'));
    });
  });

  group('watermarkPlacementExpression', () {
    test('a free placement centres the watermark on the dragged point', () {
      // The whole reason free placement stores a fraction: ffmpeg does the
      // subtraction with the REAL watermark size, so the caller never has
      // to measure anything.
      final expr = watermarkPlacementExpression(
        const WatermarkPlacement.free(0.25, 0.75),
        sizeVar: 'text_w/text_h',
      );
      expect(expr, 'x=0.25*main_w-text_w/2:y=0.75*main_h-text_h/2');
    });

    test('a free placement works for the overlay size variables too', () {
      final expr = watermarkPlacementExpression(
        const WatermarkPlacement.free(0.5, 0.5),
        sizeVar: 'overlay_w/overlay_h',
      );
      expect(expr, 'x=0.5*main_w-overlay_w/2:y=0.5*main_h-overlay_h/2');
    });

    test('an anchored placement keeps the original expressions', () {
      final expr = watermarkPlacementExpression(
        const WatermarkPlacement.anchor(WatermarkPosition.center),
        sizeVar: 'text_w/text_h',
      );
      expect(expr, 'x=main_w/2-text_w/2:y=main_h/2-text_h/2');
    });

    test('the anchor margin is carried through', () {
      final expr = watermarkPlacementExpression(
        const WatermarkPlacement.anchor(WatermarkPosition.bottomRight,
            margin: 24),
        sizeVar: 'overlay_w/overlay_h',
      );
      expect(expr, contains('-24'));
    });

    test('fractions are formatted without noise', () {
      final expr = watermarkPlacementExpression(
        const WatermarkPlacement.free(1.0, 0.0),
        sizeVar: 'text_w/text_h',
      );
      // Not '1.000000*main_w' and not '1*main_w' either.
      expect(expr, contains('1.0*main_w'));
      expect(expr, contains('0.0*main_h'));
      expect(expr, isNot(contains('000000')));
    });

    test('out-of-range fractions are clamped', () {
      final expr = watermarkPlacementExpression(
        const WatermarkPlacement.free(1.5, -0.2),
        sizeVar: 'text_w/text_h',
      );
      expect(expr, contains('1.0*main_w'));
      expect(expr, contains('0.0*main_h'));
    });

    test('isFree tells the two forms apart', () {
      expect(
        const WatermarkPlacement.anchor(WatermarkPosition.center).isFree,
        isFalse,
      );
      expect(const WatermarkPlacement.free(0.5, 0.5).isFree, isTrue);
      expect(
        const WatermarkPlacement.anchor(WatermarkPosition.center).anchor,
        WatermarkPosition.center,
      );
      expect(const WatermarkPlacement.free(0.5, 0.5).anchor, isNull);
    });
  });

  group('the two variants stay in step', () {
    test('text and image use the same anchor set', () {
      for (final p in WatermarkPosition.values) {
        final text = watermarkPositionExpression(p, sizeVar: 'text_w/text_h');
        final image =
            watermarkPositionExpression(p, sizeVar: 'overlay_w/overlay_h');
        // Same slot layout, only the size variable differs.
        final textSlots = text.substring(2).split(':').map(_slot).toList();
        final imageSlots = image.substring(2).split(':').map(_slot).toList();
        expect(textSlots, imageSlots, reason: '$p');
      }
    });
  });
}

/// Collapse a position expression to its slot shape, so the two variants
/// can be compared without the size variable getting in the way.
String _slot(String part) {
  return part
      .replaceAll('text_w', 'W')
      .replaceAll('text_h', 'H')
      .replaceAll('overlay_w', 'W')
      .replaceAll('overlay_h', 'H');
}
