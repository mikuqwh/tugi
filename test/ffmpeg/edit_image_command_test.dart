/// Unit tests for the Edit Image command builder and the image header
/// reader.
///
/// Pure `package:test`, host VM, no ffmpeg -- same reason as the other
/// suites in test/ffmpeg/ (`flutter test` cannot connect to flutter_tester
/// here).
///
/// Pins, all measured on host ffmpeg 9.0.2 and md5-replicated against the
/// golden set (12/12):
///
///  - `eq` contrast neutral is 1.0: the UI offset -100..100 maps to
///    `1.0 + offset/100` (feeding the raw offset destroys the image at
///    mid-slider).
///  - `1.0 + (-70)/100` is 0.30000000000000004 in IEEE-754; the filter text
///    must round, not leak the binary float.
///  - 90° steps are `transpose=dir=...` (named), never `rotate=` (which
///    keeps the frame size and crops the corners).
///  - unsharp matrix size is fixed at the odd 5:5 (even sizes are rejected
///    by ffmpeg).
///  - a fully neutral edit emits no `-vf` at all.
///  - partial parameter sets stay well-formed: touching only brightness
///    gives exactly `eq=brightness=...`, never `eq=:,hue=h=`.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:tugi/ffmpeg/commands.dart';
import 'package:tugi/utils/image_reader.dart';
import 'package:test/test.dart';

void main() {
  String filterOf(List<String> args) => args[args.indexOf('-vf') + 1];

  List<String> build({
    EditImageGeometry geometry = const EditImageGeometry(),
    EditImageAdjust adjust = const EditImageAdjust(),
    String preset = 'none',
    int presetStrength = 100,
    String format = 'jpg',
    int jpegQuality = 2,
    String outputPath = '/out.jpg',
  }) =>
      editImageTransform(
        inputPath: '/in.png',
        outputPath: outputPath,
        geometry: geometry,
        adjust: adjust,
        preset: preset,
        presetStrength: presetStrength,
        format: format,
        jpegQuality: jpegQuality,
      );

  group('parameter mapping (eq / hue)', () {
    test('contrast offset maps around the 1.0 neutral', () {
      expect(filterOf(build(adjust: const EditImageAdjust(contrast: 20))),
          'eq=contrast=1.2');
      expect(filterOf(build(adjust: const EditImageAdjust(contrast: -50))),
          'eq=contrast=0.5');
    });

    test('contrast -70 does not leak the IEEE-754 tail', () {
      expect(filterOf(build(adjust: const EditImageAdjust(contrast: -70))),
          'eq=contrast=0.3');
    });

    test('brightness is 0-neutral and keeps its sign', () {
      expect(filterOf(build(adjust: const EditImageAdjust(brightness: 10))),
          'eq=brightness=0.1');
      expect(filterOf(build(adjust: const EditImageAdjust(brightness: -25))),
          'eq=brightness=-0.25');
    });

    test('saturation UI 0..200 maps to 0.0..2.0 around 100', () {
      expect(filterOf(build(adjust: const EditImageAdjust(saturation: 160))),
          'eq=saturation=1.6');
      expect(filterOf(build(adjust: const EditImageAdjust(saturation: 0))),
          'eq=saturation=0');
    });

    test('hue is emitted in degrees with its sign', () {
      expect(
          filterOf(build(adjust: const EditImageAdjust(hue: 45))), 'hue=h=45');
      expect(filterOf(build(adjust: const EditImageAdjust(hue: -45))),
          'hue=h=-45');
    });
  });

  group('neutrality', () {
    test('a fully neutral edit carries no -vf at all', () {
      final args = build();
      expect(args, isNot(contains('-vf')));
      expect(args, isNot(contains('-filter_complex')));
    });

    test('untouched sliders disappear from the eq filter', () {
      final f =
          filterOf(build(adjust: const EditImageAdjust(contrast: 20, blur: 8)));
      expect(f, 'eq=contrast=1.2,gblur=sigma=8:steps=3');
      expect(f, isNot(contains(':,')), reason: f);
      expect(f, isNot(contains('=:')), reason: f);
    });

    test('a single touched slider yields exactly one well-formed stage', () {
      expect(filterOf(build(adjust: const EditImageAdjust(brightness: 10))),
          'eq=brightness=0.1');
      expect(
          filterOf(build(adjust: const EditImageAdjust(hue: 45))), 'hue=h=45');
    });
  });

  group('geometry', () {
    test('90° is transpose=dir=clock, never rotate=', () {
      final args = build(geometry: const EditImageGeometry(quarterTurns: 1));
      expect(filterOf(args), 'transpose=dir=clock');
      expect(args.join(' '), isNot(contains('rotate=')),
          reason: args.join(' '));
    });

    test('270° is transpose=dir=cclock', () {
      expect(
          filterOf(build(geometry: const EditImageGeometry(quarterTurns: 3))),
          'transpose=dir=cclock');
    });

    test('180° is hflip,vflip', () {
      expect(
          filterOf(build(geometry: const EditImageGeometry(quarterTurns: 2))),
          'hflip,vflip');
    });

    test('flips use hflip/vflip directly', () {
      expect(filterOf(build(geometry: const EditImageGeometry(flipH: true))),
          'hflip');
      expect(filterOf(build(geometry: const EditImageGeometry(flipV: true))),
          'vflip');
    });

    test('crop keeps w:h:x:y order', () {
      expect(
          filterOf(build(
              geometry: const EditImageGeometry(
                  crop: EditImageCropRect(
                      x: 80, y: 60, width: 480, height: 360)))),
          'crop=480:360:80:60');
    });

    test('scale is even-height lanczos', () {
      expect(
          filterOf(build(geometry: const EditImageGeometry(scaleWidth: 320))),
          'scale=320:-2:flags=lanczos');
    });
  });

  group('stage order', () {
    test('geometry -> color -> detail, in filter-chain order', () {
      final f = filterOf(build(
        geometry: const EditImageGeometry(
            quarterTurns: 1,
            flipV: true,
            scaleWidth: 320,
            crop: EditImageCropRect(x: 10, y: 20, width: 600, height: 400)),
        adjust: const EditImageAdjust(
            brightness: 10,
            contrast: 20,
            saturation: 160,
            hue: 45,
            temperature: 50,
            shadows: 20,
            midtones: -10,
            highlights: 10,
            sharpen: 150,
            blur: 8),
        preset: 'cine',
      ));
      final order = [
        f.indexOf('crop='),
        f.indexOf('transpose=dir=clock'),
        f.indexOf('vflip'),
        f.indexOf('scale='),
        f.indexOf('eq=brightness='),
        f.indexOf('hue='),
        f.indexOf('eq=contrast=1.2:saturation=0.75'),
        f.indexOf('colorbalance=rs=0.08'),
        f.indexOf('colorbalance=rs=0.2'),
        f.indexOf('unsharp='),
        f.indexOf('gblur='),
      ];
      for (final i in order) {
        expect(i, isNonNegative, reason: f);
      }
      expect(order, orderedEquals(order.toList()..sort()), reason: f);
    });
  });

  group('unsharp / gblur', () {
    test('unsharp matrix size is the fixed odd 5:5', () {
      expect(filterOf(build(adjust: const EditImageAdjust(sharpen: 1))),
          'unsharp=5:5:0.01:5:5:0');
      expect(filterOf(build(adjust: const EditImageAdjust(sharpen: 100))),
          'unsharp=5:5:1:5:5:0');
      expect(filterOf(build(adjust: const EditImageAdjust(sharpen: 150))),
          'unsharp=5:5:1.5:5:5:0');
      expect(filterOf(build(adjust: const EditImageAdjust(sharpen: 300))),
          'unsharp=5:5:3:5:5:0');
    });

    test('blur emits sigma with steps=3', () {
      expect(filterOf(build(adjust: const EditImageAdjust(blur: 8))),
          'gblur=sigma=8:steps=3');
    });
  });

  group('temperature / colorbalance', () {
    test('temperature maps to gamma_r/gamma_b around 1 with G pinned', () {
      expect(filterOf(build(adjust: const EditImageAdjust(temperature: 50))),
          'eq=gamma_r=1.25:gamma_g=1:gamma_b=0.75');
      expect(filterOf(build(adjust: const EditImageAdjust(temperature: -100))),
          'eq=gamma_r=0.5:gamma_g=1:gamma_b=1.5');
    });

    test('temperature shares the eq filter with other eq options', () {
      expect(
          filterOf(build(
              adjust: const EditImageAdjust(brightness: 10, temperature: 50))),
          'eq=brightness=0.1:gamma_r=1.25:gamma_g=1:gamma_b=0.75');
    });

    test('colorbalance follows the guide template rs/gm/bh', () {
      expect(
          filterOf(build(
              adjust: const EditImageAdjust(
                  shadows: 20, midtones: -10, highlights: 10))),
          'colorbalance=rs=0.2:gm=-0.1:bh=0.1');
    });

    test('a single colorbalance zone emits only its key', () {
      expect(filterOf(build(adjust: const EditImageAdjust(highlights: 10))),
          'colorbalance=bh=0.1');
      expect(filterOf(build(adjust: const EditImageAdjust(midtones: -5))),
          'colorbalance=gm=-0.05');
    });

    test('new fields participate in neutrality', () {
      expect(const EditImageAdjust(temperature: 1).isNeutral, isFalse);
      expect(const EditImageAdjust(shadows: -30).isNeutral, isFalse);
      expect(const EditImageAdjust(highlights: 30).isNeutral, isFalse);
      expect(
          filterOf(
              build(adjust: const EditImageAdjust(temperature: 100, blur: 8))),
          'eq=gamma_r=1.5:gamma_g=1:gamma_b=0.5,gblur=sigma=8:steps=3');
    });
  });

  group('style presets', () {
    test('none and strength 0 emit no preset stages', () {
      final plain =
          filterOf(build(adjust: const EditImageAdjust(contrast: 20)));
      expect(
          filterOf(build(
              adjust: const EditImageAdjust(contrast: 20), preset: 'none')),
          plain);
      expect(
          filterOf(build(
              adjust: const EditImageAdjust(contrast: 20),
              preset: 'bw',
              presetStrength: 0)),
          plain);
      expect(
          filterOf(build(
              adjust: const EditImageAdjust(contrast: 20),
              preset: 'unknown-preset')),
          plain);
    });

    test('bw scales saturation toward 0', () {
      expect(filterOf(build(preset: 'bw')), 'eq=saturation=0');
      expect(filterOf(build(preset: 'bw', presetStrength: 50)),
          'eq=saturation=0.5');
    });

    test('vintage at full strength is the sepia matrix', () {
      expect(
          filterOf(build(preset: 'vintage')),
          'colorchannelmixer=rr=0.393:rg=0.769:rb=0.189:'
          'gr=0.349:gg=0.686:gb=0.168:br=0.272:bg=0.534:bb=0.131');
    });

    test('cool / warm bend gamma in opposite directions', () {
      expect(filterOf(build(preset: 'cool')),
          'eq=gamma_r=0.85:gamma_g=1:gamma_b=1.15');
      expect(filterOf(build(preset: 'warm')),
          'eq=gamma_r=1.15:gamma_g=1:gamma_b=0.85');
    });

    test('contrast / lowsat scale linearly with strength', () {
      expect(filterOf(build(preset: 'contrast')), 'eq=contrast=1.4');
      expect(filterOf(build(preset: 'contrast', presetStrength: 50)),
          'eq=contrast=1.2');
      expect(filterOf(build(preset: 'lowsat')), 'eq=saturation=0.6');
    });

    test('cine emits an eq stage and a balance stage, in that order', () {
      expect(filterOf(build(preset: 'cine')),
          'eq=contrast=1.2:saturation=0.75,colorbalance=rs=0.08:bs=-0.08');
    });

    test('soft is a negative unsharp amount on the fixed odd 5:5', () {
      expect(filterOf(build(preset: 'soft')), 'unsharp=5:5:-0.8:5:5:0');
    });

    test('preset sits between hue and the manual colorbalance', () {
      expect(
          filterOf(build(
              adjust: const EditImageAdjust(hue: 45, highlights: 10),
              preset: 'bw')),
          'hue=h=45,eq=saturation=0,colorbalance=bh=0.1');
    });
  });

  group('output format', () {
    test('jpg defaults to -q:v 2 (mjpeg scale: 2 is best)', () {
      final args = build();
      final i = args.indexOf('-q:v');
      expect(i, isNonNegative);
      expect(args[i + 1], '2');
      expect(args.last, '/out.jpg');
    });

    test('a chosen quality passes through', () {
      final args = build(jpegQuality: 5);
      expect(args[args.indexOf('-q:v') + 1], '5');
    });

    test('png adds no -q:v and still ends with the output path', () {
      final args = build(format: 'png', outputPath: '/out.png');
      expect(args, isNot(contains('-q:v')));
      expect(args.last, '/out.png');
    });

    test('png forces no -pix_fmt (golden md5s were produced without it)', () {
      final args = build(format: 'png', outputPath: '/out.png');
      expect(args, isNot(contains('-pix_fmt')));
    });
  });

  group('argv shape', () {
    test('every option value stays glued to its flag', () {
      final cases = <List<String>>[
        build(),
        build(geometry: const EditImageGeometry(quarterTurns: 1)),
        build(adjust: const EditImageAdjust(contrast: 20)),
        build(
          geometry: const EditImageGeometry(
              scaleWidth: 320,
              crop: EditImageCropRect(x: 0, y: 0, width: 100, height: 100)),
          adjust: const EditImageAdjust(
              brightness: 5, hue: -30, sharpen: 200, blur: 4),
        ),
        build(format: 'png', outputPath: '/out.png'),
      ];
      const flagsWithValue = {'-i', '-vf', '-q:v', '-pix_fmt'};
      for (final args in cases) {
        for (var i = 0; i < args.length; i++) {
          if (flagsWithValue.contains(args[i])) {
            expect(i + 1, lessThan(args.length),
                reason: '"${args[i]}" has no value in $args');
            expect(args[i + 1].startsWith('-'), isFalse,
                reason:
                    '"${args[i]}" is followed by a flag, not a value, in $args');
          }
        }
        expect(args.first, '-y', reason: args.join(' '));
        expect(args[args.indexOf('-i') + 1], '/in.png', reason: args.join(' '));
        expect(args.last, isNot(startsWith('-')), reason: args.join(' '));
      }
    });
  });

  group('exact combined command', () {
    test('full stack produces the exact documented argv', () {
      final args = editImageTransform(
        inputPath: '/in.png',
        outputPath: '/out.jpg',
        geometry: const EditImageGeometry(
            quarterTurns: 1,
            flipH: true,
            scaleWidth: 640,
            crop: EditImageCropRect(x: 80, y: 60, width: 480, height: 360)),
        adjust: const EditImageAdjust(
            brightness: 10,
            contrast: 20,
            saturation: 160,
            hue: 45,
            sharpen: 150,
            blur: 8),
      );
      expect(
          args,
          orderedEquals(<String>[
            '-y',
            '-i',
            '/in.png',
            '-vf',
            'crop=480:360:80:60,transpose=dir=clock,hflip,'
                'scale=640:-2:flags=lanczos,'
                'eq=brightness=0.1:contrast=1.2:saturation=1.6,'
                'hue=h=45,unsharp=5:5:1.5:5:5:0,gblur=sigma=8:steps=3',
            '-q:v',
            '2',
            '/out.jpg',
          ]));
    });
  });

  group('ImageReader', () {
    Uint8List png(
        {required int width, required int height, int colorType = 2}) {
      final b = BytesBuilder();
      b.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      b.add(const [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]); // IHDR
      final dims = ByteData(8)
        ..setUint32(0, width)
        ..setUint32(4, height);
      b.add(dims.buffer.asUint8List());
      b.add([8, colorType, 0, 0, 0]);
      return b.toBytes();
    }

    Uint8List jpeg({required int width, required int height}) =>
        Uint8List.fromList(<int>[
          0xFF, 0xD8, //
          0xFF, 0xC0, 0x00, 0x11, 0x08,
          height >> 8, height & 0xFF, width >> 8, width & 0xFF,
          0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        ]);

    test('parses png dimensions and alpha channels', () {
      final info = ImageReader.parse(png(width: 640, height: 480));
      expect(info.width, 640);
      expect(info.height, 480);
      expect(info.format, 'png');
      expect(info.hasAlpha, isFalse);

      expect(ImageReader.parse(png(width: 1, height: 2, colorType: 6)).hasAlpha,
          isTrue);
      expect(ImageReader.parse(png(width: 1, height: 2, colorType: 4)).hasAlpha,
          isTrue);
      expect(ImageReader.parse(png(width: 1, height: 2, colorType: 2)).hasAlpha,
          isFalse);
    });

    test('parses jpeg dimensions from SOF0', () {
      final info = ImageReader.parse(jpeg(width: 640, height: 480));
      expect(info.width, 640);
      expect(info.height, 480);
      expect(info.format, 'jpeg');
      expect(info.hasAlpha, isFalse);
    });

    test('rejects truncated and foreign payloads', () {
      expect(
          () => ImageReader.parse(png(width: 640, height: 480).sublist(0, 20)),
          throwsA(isA<ImageParseException>()));
      expect(() => ImageReader.parse(Uint8List.fromList(const [1, 2, 3])),
          throwsA(isA<ImageParseException>()));
      expect(
          () => ImageReader.parse(Uint8List.fromList(const [0xFF, 0xD8, 0xFF])),
          throwsA(isA<ImageParseException>()));
    });
  });

  // ---------------------------------------------------------------------
  // Style-preset GPU preview matrices.
  //
  // The editor shows style presets through ColorFilter.matrix without
  // running ffmpeg, so these mappings are what the user actually sees before
  // pressing save. A wrong matrix here means "the preview lies", which is
  // worse than having no preview at all.
  // ---------------------------------------------------------------------
  group('editImagePresetPreviewMatrix', () {
    List<double> m44(String preset, int strength) =>
        editImagePresetPreviewMatrix(preset, strength)!;

    List<double> m3(List<double> m, int row) =>
        [m[row * 5], m[row * 5 + 1], m[row * 5 + 2]];

    double trans(List<double> m, int row) => m[row * 5 + 4];

    test('returns null exactly for the no-op cases', () {
      expect(editImagePresetPreviewMatrix('none', 100), isNull);
      expect(editImagePresetPreviewMatrix('bw', 0), isNull);
      expect(editImagePresetPreviewMatrix('soft', 100), isNull,
          reason: 'negative unsharp is a convolution; no affine stand-in');
      expect(editImagePresetPreviewMatrix('bw', -10), isNull);
    });

    test('every non-soft preset returns a usable 4x5 matrix', () {
      for (final p in const [
        'bw',
        'lowsat',
        'contrast',
        'vintage',
        'cool',
        'warm',
        'cine'
      ]) {
        final m = m44(p, 100);
        expect(m.length, 20, reason: p);
        expect(m.sublist(15), [0, 0, 0, 1, 0],
            reason: '$p must leave the alpha row untouched');
        expect(m44(p, 1).length, 20, reason: '$p at strength 1');
      }
    });

    test('bw at full strength collapses all rows onto the luma axis', () {
      // Every row must be the same coefficients, and their sum must be 1 --
      // that is what makes R=G=B for any input.
      final m = m44('bw', 100);
      final row0 = m3(m, 0);
      for (var r = 1; r < 3; r++) {
        expect(m3(m, r), row0, reason: 'row $r must match row 0');
      }
      expect(row0.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
      // Rec.709 luma, not the 0.299/0.587/0.114 of Rec.601.
      expect(row0[0], closeTo(0.2126, 1e-6));
      expect(row0[1], closeTo(0.7152, 1e-6));
      expect(row0[2], closeTo(0.0722, 1e-6));
      for (var r = 0; r < 3; r++) {
        expect(trans(m, r), 0);
      }
    });

    test('bw strength scales continuously from identity to pure luma', () {
      // strength 0 returns null (documented as the off switch), so probe the
      // ramp from 1 upward and check it moves monotonically toward luma.
      expect(m3(identity44(), 0), [1, 0, 0]);
      var prev = double.infinity;
      for (final s in [1, 25, 50, 75, 100]) {
        final row = m3(m44('bw', s), 0);
        // R coefficient falls toward lr while G rises toward lg, so the
        // R-minus-G spread shrinks toward the pure-luma value.
        final spread = row[0] - row[1];
        expect(spread, lessThan(prev), reason: 'strength $s');
        prev = spread;
      }
      expect(prev, closeTo(0.2126 - 0.7152, 1e-6));
    });

    test('lowsat is a partial desaturation, never reaching bw', () {
      final low = m3(m44('lowsat', 100), 0);
      final bw = m3(m44('bw', 100), 0);
      expect(low[0], greaterThan(bw[0]));
      expect(low[1], lessThan(bw[1]));
      // Residual saturation must survive: at 100% strength the row is
      // v*I + (1-v)*luma with v = 1 - 0.4 = 0.6.
      const lr = 0.2126, lg = 0.7152, lb = 0.0722;
      final v = 0.6;
      expect(low[0], closeTo(v + (1 - v) * lr, 1e-9));
      expect(low[1], closeTo((1 - v) * lg, 1e-9));
      expect(low[2], closeTo((1 - v) * lb, 1e-9));
      expect(low.reduce((a, b) => a + b), closeTo(1.0, 1e-9),
          reason: 'luma mix must preserve overall brightness');
    });

    test('contrast is a diagonal scale that pivots around 128', () {
      // eq contrast is v' = v*c + 128*(1-c); the matrix must carry the same
      // offset or mid-grey drifts. The 3x3 part stays DIAGONAL -- contrast is
      // not a channel mixer.
      final c = 1 + 0.4;
      final m = m44('contrast', 100);
      expect(m3(m, 0), [closeTo(c, 1e-9), 0, 0]);
      expect(m3(m, 1), [0, closeTo(c, 1e-9), 0]);
      expect(m3(m, 2), [0, 0, closeTo(c, 1e-9)]);
      for (var r = 0; r < 3; r++) {
        expect(trans(m, r), closeTo(128 * (1 - c), 1e-9));
      }
      // A neutral-strength matrix must leave 128 exactly where it was.
      final half = m44('contrast', 50);
      final ch = 1 + 0.2;
      expect(trans(half, 0), closeTo(128 * (1 - ch), 1e-9));
      // ffmpeg's eq contrast neutral is 1.0, not 0.0 -- at strength 0 the
      // scale must be exactly 1 with zero offset.
      expect(identity44()[0], 1.0);
    });

    test('vintage reproduces the colorchannelmixer coefficients', () {
      // Must match editImagePresetFilters' vintage branch term for term, laid
      // out at the 3x3 positions of a 4x5 (0/1/2, 5/6/7, 10/11/12).
      final filters = editImagePresetFilters('vintage', 100).join();
      final m = m44('vintage', 100);
      const target = [
        0.393, 0.769, 0.189, //
        0.349, 0.686, 0.168,
        0.272, 0.534, 0.131,
      ];
      const pos = [0, 1, 2, 5, 6, 7, 10, 11, 12];
      for (var i = 0; i < 9; i++) {
        expect(m[pos[i]], closeTo(target[i], 1e-3), reason: 'coefficient $i');
        expect(filters, contains(target[i].toStringAsFixed(3)),
            reason: 'ffmpeg side must emit the same $i');
      }
      // Everything outside the 3x3 must stay zero: the three alpha columns,
      // the three translate slots, and the alpha row except its diagonal.
      for (final idx in const [3, 4, 8, 9, 13, 14, 15, 16, 17, 19]) {
        expect(m[idx], 0, reason: 'index $idx must stay zero');
      }
      expect(m[18], 1.0, reason: 'the alpha diagonal must survive');
      // Diagonal terms are pulled toward the target, not set to it: at full
      // strength rr is 0.393, not the identity 1.
      expect(m[0], lessThan(1.0));
    });

    test('vintage strength 1 is still nearly the identity', () {
      final m = m44('vintage', 1);
      expect(m[0], closeTo(1 - (1 - 0.393) * 0.01, 1e-3),
          reason: 'a 1% mix moves 1% of the way');
    });

    test('cool and warm are diagonal gains in opposite directions', () {
      final cool = m44('cool', 100);
      final warm = m44('warm', 100);
      // R lives at index 0, B at 12 in a 4x5.
      expect(cool[0], closeTo(1 - 0.15, 1e-9));
      expect(cool[12], closeTo(1 + 0.15, 1e-9));
      expect(warm[0], closeTo(1 + 0.15, 1e-9));
      expect(warm[12], closeTo(1 - 0.15, 1e-9));
      // Green is the pivot for both: it must not move.
      expect(cool[6], 1.0);
      expect(warm[6], 1.0);
      // Off-diagonals stay zero (a pure per-channel gain).
      for (final m in [cool, warm]) {
        expect([m[1], m[2], m[5], m[7], m[10], m[11]], everyElement(0));
      }
    });

    test('cine carries both its desaturation and its contrast, and no shift',
        () {
      final m = m44('cine', 100);
      final c = 1 + 0.2;
      expect(m[0], closeTo((1 - 0.25) * c + 0.25 * 0.2126 * c, 1e-9),
          reason: 'saturation mix then contrast scale');
      expect(trans(m, 0), closeTo(128 * (1 - c), 1e-9));
    });

    test('matrices stay finite and bounded across the whole strength range',
        () {
      for (final p in const [
        'bw',
        'lowsat',
        'contrast',
        'vintage',
        'cool',
        'warm',
        'cine'
      ]) {
        for (var s = 0; s <= 100; s += 5) {
          // strength 0 is the documented off switch and returns null.
          if (s == 0) {
            expect(editImagePresetPreviewMatrix(p, s), isNull, reason: p);
            continue;
          }
          final m = m44(p, s);
          for (var i = 0; i < 20; i++) {
            final v = m[i];
            expect(v.isFinite, isTrue, reason: '$p @$s idx$i -> $v');
            // The 3x3 block mixes channels (coefficients stay near 1); the
            // translate column carries eq's 128*(1-c) pivot, which reaches
            // +-51 at full contrast. Nothing may exceed a sane bound.
            final bound = i % 5 == 4 ? 64.0 : 4.0;
            expect(v.abs(), lessThan(bound), reason: '$p @$s idx$i -> $v');
          }
        }
      }
    });
  });

  // ---------------------------------------------------------------------
  // Compression ladder search.
  //
  // ffmpeg's mjpeg encoder has no target-size mode, so the apply step walks
  // these ladders. `-q:v` is monotonic in output size, which is what makes
  // "stop at the first entry that fits" exact rather than heuristic.
  // ---------------------------------------------------------------------
  group('compression ladders', () {
    test('quality ladder is ascending and bounded by mjpeg 2..31', () {
      expect(imageCompressionQualityLadder.first, 2);
      expect(imageCompressionQualityLadder.last, 31);
      for (var i = 1; i < imageCompressionQualityLadder.length; i++) {
        expect(imageCompressionQualityLadder[i],
            greaterThan(imageCompressionQualityLadder[i - 1]));
      }
    });

    test('width ladder is descending and stays in the documented range', () {
      expect(imageCompressionWidthLadder.first, 2560);
      expect(imageCompressionWidthLadder.last, 320);
      for (var i = 1; i < imageCompressionWidthLadder.length; i++) {
        expect(imageCompressionWidthLadder[i],
            lessThan(imageCompressionWidthLadder[i - 1]));
      }
      for (final w in imageCompressionWidthLadder) {
        expect(w % 2, 0, reason: 'scale=-2 needs an even target: $w');
      }
    });

    test('ceiling snaps an off-ladder quality down to the nearest rung', () {
      expect(imageCompressionQualityCeiling(2), 2);
      expect(imageCompressionQualityCeiling(3), 2);
      expect(imageCompressionQualityCeiling(5), 4);
      expect(imageCompressionQualityCeiling(7), 6);
      expect(imageCompressionQualityCeiling(31), 31);
      expect(imageCompressionQualityCeiling(99), 31);
      expect(imageCompressionQualityCeiling(1), isNull,
          reason: 'finer than the best rung: start at the top');
      expect(imageCompressionQualityCeiling(0), isNull);
      expect(imageCompressionQualityCeiling(-5), isNull);
    });

    test('search order starts at the requested quality and descends', () {
      final order = imageCompressionSearchOrder(10);
      expect(order.first, 10);
      expect(order, [10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 31]);
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]),
            reason: 'must ascend in q, i.e. descend in quality');
      }
      expect(imageCompressionSearchOrder(2).first, 2);
      expect(imageCompressionSearchOrder(2).last, 31);
      expect(imageCompressionSearchOrder(31), [31]);
      expect(imageCompressionSearchOrder(1).first, 2,
          reason: 'below the best rung: clamp up to the top');
      expect(imageCompressionSearchOrder(99), [31],
          reason:
              'above the worst rung: clamp down to the worst, never past it');
      // An off-ladder start snaps DOWN to a rung (never finer than asked).
      expect(imageCompressionSearchOrder(11).first, 10);
      expect(imageCompressionSearchOrder(13).first, 12);
    });

    test('width order is empty when there is nothing to give up', () {
      expect(imageCompressionWidthSearchOrder(null), isEmpty,
          reason: 'no cap means the source resolution is already the floor');
      expect(imageCompressionWidthSearchOrder(320), isEmpty);
      expect(imageCompressionWidthSearchOrder(480), [320]);
      expect(imageCompressionWidthSearchOrder(1080), [960, 800, 640, 480, 320]);
      expect(
          imageCompressionWidthSearchOrder(4000), imageCompressionWidthLadder,
          reason: 'above the top rung: every rung qualifies');
      expect(imageCompressionWidthSearchOrder(2561), isNot(contains(2560)),
          reason: '2561 clamps to 2560, which is not narrower than itself');
      expect(imageCompressionWidthSearchOrder(2560), isNot(contains(2560)));
    });

    test('width clamp forces even and never finer than the last rung', () {
      expect(imageCompressionClampWidth(null), isNull);
      expect(imageCompressionClampWidth(1920), 1920);
      expect(imageCompressionClampWidth(1921), 1920,
          reason: 'odd widths break scale=-2 pairing');
      expect(imageCompressionClampWidth(0), 320);
      expect(imageCompressionClampWidth(-10), 320);
      expect(imageCompressionClampWidth(200), 320);
      expect(imageCompressionClampWidth(2561), 2560);
    });

    test('a plan without a target is a no-op encode', () {
      const p =
          ImageCompressionPlan(targetBytes: 0, quality: 2, maxWidth: null);
      expect(p.hasTarget, isFalse);
      expect(p.mode, ImageCompressionMode.qualityThenScale);
    });

    test('only qualityThenScale permits dropping pixels', () {
      expect(compressionAllowsScaling(ImageCompressionMode.qualityThenScale),
          isTrue);
      expect(
          compressionAllowsScaling(ImageCompressionMode.qualityOnly), isFalse);
      expect(
          compressionAllowsScaling(ImageCompressionMode.qualityFloor), isFalse);
    });

    test('qualityOnly still searches quality, just not width', () {
      const p = ImageCompressionPlan(
        targetBytes: 1024,
        quality: 2,
        maxWidth: 1080,
        mode: ImageCompressionMode.qualityOnly,
      );
      expect(compressionAllowsScaling(p.mode), isFalse);
      // The ladder itself is mode-agnostic; the service gates on the mode.
      expect(imageCompressionSearchOrder(p.quality).first, 2);
      expect(imageCompressionSearchOrder(p.quality).length,
          imageCompressionQualityLadder.length);
    });

    test('result reports fit against the target it was measured for', () {
      const r = ImageCompressionResult(
          path: '/x.jpg', bytes: 900, quality: 8, width: 1080);
      expect(r.fits(1024), isTrue);
      expect(r.fits(900), isTrue, reason: 'the target is inclusive');
      expect(r.fits(899), isFalse);
    });
  });

  // ---------------------------------------------------------------------
  // Compression phase plan.
  //
  // This is the regression test for the iteration-budget bug: the old walk
  // spent the whole budget on quality rungs at the source width before ever
  // narrowing, so an aggressive target reported "已压到质量/尺寸下限" while a
  // narrower width would have fit. Measured on host ffmpeg 9.0.2 with a
  // 1920x1080 testsrc2 and a 20 KB target: 68 attempts before any width
  // descent, 13 with the probe-first plan.
  // ---------------------------------------------------------------------
  group('compressionSearchPhases', () {
    List<CompressionPhase> plan({
      int startQuality = 2,
      int? startWidth,
      bool allowScale = true,
      int? sourceWidth,
    }) =>
        compressionSearchPhases(
          startQuality: startQuality,
          startWidth: startWidth,
          allowScale: allowScale,
          sourceWidth: sourceWidth,
        );

    test('no width cap and no source width means a single phase', () {
      final p = plan(startWidth: null);
      expect(p.length, 1);
      expect(p.first.width, isNull, reason: 'null keeps the source resolution');
      expect(p.first.probeQuality, 31, reason: 'probe the WORST rung');
    });

    test('a null cap still descends from the SOURCE width when scaling is on',
        () {
      // The regression: "输出宽度: 原始" left startWidth null, so the width
      // ladder came out empty and "允许缩小尺寸" did nothing -- a 20 KB target
      // on a 4032px photo walked quality to 31, quit at 573 KB, and reported
      // 未达目标 even though 320px would have fit easily.
      final p = plan(startWidth: null, sourceWidth: 4032);
      expect(p.length, greaterThan(1),
          reason: 'the ladder must exist, or scaling is a no-op');
      expect(p.first.width, isNull,
          reason: 'phase 1 still encodes at full size');
      expect(p[1].width, 2560, reason: 'descent starts at the top rung');
      expect(p.last.width, 320, reason: 'and reaches the floor');
    });

    test('a source narrower than the top rung descends from the ladder top',
        () {
      final p = plan(startWidth: null, sourceWidth: 1280);
      // 1280 clamps onto the ladder, so the descent skips 2560/2048/1600.
      expect(p.first.width, isNull);
      expect(p[1].width, 1080);
      expect(p.last.width, 320);
    });

    test('scaling off ignores the source width entirely', () {
      final p = plan(startWidth: null, sourceWidth: 4032, allowScale: false);
      expect(p.length, 1, reason: 'no ladder without scaling');
      expect(p.single.width, isNull);
    });

    test('probe is always the worst rung and is excluded from the walk', () {
      final p = plan(startWidth: 1920);
      expect(p.length, greaterThan(1));
      for (final phase in p) {
        expect(phase.probeQuality, 31);
        expect(phase.walkQuality, isNot(contains(31)),
            reason:
                'the probe is already encoded; walking it again wastes one');
        expect(phase.walkQuality, isNotEmpty);
        // Walk order must be best-first, so the first fit is the best quality.
        for (var i = 1; i < phase.walkQuality.length; i++) {
          expect(phase.walkQuality[i], greaterThan(phase.walkQuality[i - 1]));
        }
        expect(phase.walkQuality.first, 2);
      }
    });

    test('phases descend in width and never repeat one', () {
      final p = plan(startWidth: 1920);
      expect(p.map((e) => e.width).toList(),
          [1920, 1600, 1280, 1080, 960, 800, 640, 480, 320]);
      final seen = p.map((e) => e.width).toSet();
      expect(seen.length, p.length, reason: 'no duplicate widths');
    });

    test('allowScale=false collapses the plan to the source width only', () {
      final p = plan(startWidth: 1920, allowScale: false);
      expect(p.length, 1);
      expect(p.single.width, 1920);
      // Quality is still searched -- only the width descent is disabled.
      expect(p.single.maxEncodes, 15);
    });

    test('an off-ladder start quality still probes the worst rung', () {
      final p = plan(startQuality: 11, startWidth: 1080);
      // 11 clamps down to rung 10, so the walk runs 10..28 and the probe is 31.
      expect(p.first.probeQuality, 31);
      expect(p.first.walkQuality.first, 10);
      expect(p.first.walkQuality.last, 28);
    });

    test('a start already at the worst rung leaves an empty walk', () {
      final p = plan(startQuality: 31, startWidth: 1920);
      for (final phase in p) {
        expect(phase.probeQuality, 31);
        expect(phase.walkQuality, isEmpty,
            reason: 'nothing better to try; the probe IS the only candidate');
        expect(phase.maxEncodes, 1);
      }
    });

    test('worst-case encode count matches the measured pathology', () {
      // 1920x1080 -> 20 KB was the case that starved the old budget.
      final p = plan(startWidth: 1920);
      final worst = compressionWorstCaseEncodes(p);
      expect(worst, 9 * 15, reason: '9 widths x (1 probe + 14 walk)');
      // The old budget of 12 was below even the PER-WIDTH cost of 15, so a
      // single aggressive target could never reach the second width.
      expect(worst, greaterThan(12));
    });

    test('the default budget always covers the plan it is derived from', () {
      for (final w in [320, 480, 640, 1080, 1920, 4000, null]) {
        final p = plan(startWidth: w);
        final worst = compressionWorstCaseEncodes(p);
        // Mirrors EditImageService.compress's default: 2x headroom, floored
        // at 20 and capped at 200.
        final budget = (worst * 2).clamp(20, 200);
        expect(budget, greaterThanOrEqualTo(worst),
            reason: 'width $w: budget $budget < worst case $worst');
      }
    });

    test('clamping happens in the plan, so widths are always even', () {
      final p = plan(startWidth: 1921);
      expect(p.first.width, 1920, reason: 'odd widths break scale=-2');
      expect(plan(startWidth: 100).first.width, 320,
          reason: 'below the last rung: floors there');
      for (final phase in p) {
        expect(phase.width! % 2, 0);
      }
    });

    test('width order is empty when the cap is already the floor', () {
      expect(plan(startWidth: 320).length, 1);
      expect(plan(startWidth: 320).single.width, 320);
    });
  });

  // ---------------------------------------------------------------------
  // Apply-button arming across a re-pick.
  //
  // Regression: picking a new image used to seed the applied-target marker
  // with the CURRENT target. Because the target persists across picks, the
  // fresh image was immediately considered already-compressed and the apply
  // button stayed grey -- so "pick a big photo, change nothing, compress it"
  // was impossible without first dragging some unrelated slider.
  group('compressionTargetPending', () {
    const k100kb = 100 * 1024;
    const k300kb = 300 * 1024;

    test('a real target on a fresh image arms apply (the regression)', () {
      // A re-pick leaves the marker null: nothing applied to the new image.
      expect(compressionTargetPending(k100kb, null), isTrue,
          reason: 'this is the whole fix: the button must be live');
    });

    test('the old seeding behaviour is what disabled the button', () {
      // Pinning the bug so it cannot come back quietly: inheriting the target
      // made a fresh image look already-compressed.
      expect(compressionTargetPending(k100kb, k100kb), isFalse);
    });

    test('applying the target disarms it until the target changes', () {
      expect(compressionTargetPending(k100kb, k100kb), isFalse);
      expect(compressionTargetPending(k300kb, k100kb), isTrue,
          reason: 'switching target must re-arm');
    });

    test('"不压缩" never arms the button on its own', () {
      // Switching back to 不压缩 must not leave a live "apply" that does
      // nothing -- not even straight after a re-pick, when the marker is null.
      expect(compressionTargetPending(0, null), isFalse);
      expect(compressionTargetPending(0, 0), isFalse);
      expect(compressionTargetPending(0, k100kb), isFalse);
    });

    test('null is not a reachable target, so any real target reads pending',
        () {
      // The screen only renders the button after a pick, and a pick never
      // leaves the marker null while a real target is selected -- but the
      // comparison must still behave sanely if it ever does.
      expect(compressionTargetPending(k100kb, null), isTrue);
      expect(compressionTargetPending(2 * 1024 * 1024, null), isTrue);
    });

    test('every chip target arms or disarms for the right reason', () {
      const chips = <int>[
        0,
        k100kb,
        k300kb,
        500 * 1024,
        1024 * 1024,
        2 * 1024 * 1024
      ];
      for (final t in chips) {
        // Fresh image (marker null): armed iff there is a compression intent.
        expect(compressionTargetPending(t, null), t != 0,
            reason: 'target $t straight after a pick');
        // Just applied at this target: never armed.
        expect(compressionTargetPending(t, t), isFalse,
            reason: 'target $t right after applying it');
      }
    });
  });

  group('compressionWidthRungs', () {
    List<CompressionPhase> phasesFor(int source) => compressionSearchPhases(
          startQuality: 2,
          startWidth: null,
          allowScale: true,
          sourceWidth: source,
        );

    test('rungs come out widest-first, excluding the head phase', () {
      final rungs = compressionWidthRungs(phasesFor(4032));
      expect(rungs.first, 2560);
      expect(rungs.last, 320);
      // Descending width == ascending index == descending file size.
      for (var i = 1; i < rungs.length; i++) {
        expect(rungs[i], lessThan(rungs[i - 1]),
            reason: 'rung $i must be narrower than rung ${i - 1}');
      }
    });

    test('a single-phase plan has no rungs', () {
      expect(compressionWidthRungs(phasesFor(320)), isEmpty);
      expect(
        compressionWidthRungs(compressionSearchPhases(
            startQuality: 2, startWidth: null, allowScale: false)),
        isEmpty,
      );
    });
  });

  group('compressionWidestFittingRung', () {
    // The rung lists are widest-first, so a fitting rung is at a HIGHER index
    // than an overshooting one. Modelled as "fits at index >= cutoff".
    const rungs = <int>[2560, 2048, 1600, 1280, 1080, 960, 800, 640, 480, 320];

    Future<int?> search(int cutoff) => compressionWidestFittingRung(
          rungs: rungs,
          fitsAt: (i) async => i >= cutoff,
        );

    test('returns the widest fitting rung, not the widest rung', () async {
      // 640 is at index 7; rungs 0..6 overshoot. The bug this guards against
      // returned 2560 (index 0) and reported 未达目标 with a 203.9 KB file.
      expect(await search(7), 7);
      expect(rungs[(await search(7))!], 640);
    });

    test('handles every cutoff position', () async {
      for (var cutoff = 0; cutoff < rungs.length; cutoff++) {
        final got = await search(cutoff);
        expect(got, cutoff, reason: 'cutoff $cutoff');
        expect(rungs[got!], rungs[cutoff]);
      }
    });

    test('returns null when nothing fits', () async {
      final got = await compressionWidestFittingRung(
        rungs: rungs,
        fitsAt: (i) async => false,
      );
      expect(got, isNull);
    });

    test('the narrowest rung fitting means everything wider overshoots',
        () async {
      expect(rungs[(await search(rungs.length - 1))!], 320);
    });

    test('a null answer stops the search and keeps the best confirmed',
        () async {
      var calls = 0;
      final got = await compressionWidestFittingRung(
        rungs: rungs,
        fitsAt: (i) async {
          calls++;
          if (i >= 7) return true;
          if (i == 3) return null; // budget spent
          return false;
        },
      );
      // Cones down from mid=4 (false) to range 4..10, mid=7 (true) -> best=7,
      // then mid=5 (false), then mid=6 (false)... never re-measures 3 blindly.
      expect(got, 7);
      expect(calls, lessThan(rungs.length),
          reason: 'bisection must not scan every rung');
    });

    test('probe count is logarithmic, not linear', () async {
      var calls = 0;
      await compressionWidestFittingRung(
        rungs: rungs,
        fitsAt: (i) async {
          calls++;
          return i >= 7;
        },
      );
      expect(calls, lessThanOrEqualTo(4),
          reason: 'log2(10) ~= 3.3 probes; a linear walk needs 8');
    });
  });
  group('editImageFilterChain', () {
    // The chain used to be inline in editImageTransform. The combined
    // (result + preview) builder needs the same text, so it was extracted;
    // these lock the extraction to the single-output builder's argv.
    test('matches what editImageTransform embeds in -vf', () {
      const cases = <(EditImageGeometry, EditImageAdjust, String, int)>[
        (EditImageGeometry(), EditImageAdjust(), 'none', 100),
        (EditImageGeometry(quarterTurns: 1), EditImageAdjust(), 'none', 100),
        (EditImageGeometry(scaleWidth: 1280), EditImageAdjust(), 'bw', 100),
        (
          EditImageGeometry(flipH: true, flipV: true),
          EditImageAdjust(brightness: 30, contrast: -20, sharpen: 50),
          'vintage',
          60
        ),
      ];
      for (final (geometry, adjust, preset, strength) in cases) {
        final chain = editImageFilterChain(
          geometry: geometry,
          adjust: adjust,
          preset: preset,
          presetStrength: strength,
        );
        final single = editImageTransform(
          inputPath: '/in.png',
          outputPath: '/out.jpg',
          geometry: geometry,
          adjust: adjust,
          preset: preset,
          presetStrength: strength,
        );
        if (chain.isEmpty) {
          expect(single.contains('-vf'), isFalse,
              reason: 'neutral edit must emit no -vf');
        } else {
          expect(filterOf(single), chain);
        }
      }
    });

    test('a fully neutral edit yields an empty chain', () {
      expect(editImageFilterChain(), isEmpty);
    });
  });

  group('editImageTransformWithPreview', () {
    List<String> combined({
      EditImageGeometry geometry = const EditImageGeometry(),
      EditImageAdjust adjust = const EditImageAdjust(),
      String preset = 'none',
      String format = 'jpg',
      int jpegQuality = 2,
    }) =>
        editImageTransformWithPreview(
          inputPath: '/in.png',
          outputPath: '/out.jpg',
          previewPath: '/prev.jpg',
          geometry: geometry,
          adjust: adjust,
          preset: preset,
          format: format,
          jpegQuality: jpegQuality,
        );

    test('splits the filtered stream into exactly two labelled outputs', () {
      final args = combined(adjust: const EditImageAdjust(brightness: 25));
      final fc = args[args.indexOf('-filter_complex') + 1];
      // The chain runs once, then forks; the preview branch scales.
      expect(fc, contains('split=2[vout][vpre]'));
      expect(fc, contains('[vpre]scale=1080:-2:flags=lanczos[vprev]'));
      expect(fc.startsWith('eq=brightness=0.25,'), isTrue,
          reason: 'the -vf chain must be the head of the complex graph');
    });

    test('a neutral edit still needs a real pad for split', () {
      final args = combined();
      final fc = args[args.indexOf('-filter_complex') + 1];
      // No chain to hang split off, so it must start from `null`.
      expect(fc.startsWith('null,split=2'), isTrue);
    });

    test('maps both outputs and keeps the quality on the full-size one', () {
      final args = combined(jpegQuality: 5);
      // -q:v 5 sits between the [vout] map and its path...
      final vout = args.indexOf('[vout]');
      expect(args.sublist(vout, vout + 4), ['[vout]', '-q:v', '5', '/out.jpg']);
      // ...and the preview pins its own 4 after its map.
      final vprev = args.indexOf('[vprev]');
      expect(args.sublist(vprev, vprev + 4),
          ['[vprev]', '-q:v', '4', '/prev.jpg']);
    });

    test('png drops the full-size quality knob but the preview keeps its own',
        () {
      final args = combined(format: 'png');
      final vout = args.indexOf('[vout]');
      expect(args.sublist(vout, vout + 2), ['[vout]', '/out.jpg'],
          reason: 'no -q:v for the png output');
      final vprev = args.indexOf('[vprev]');
      expect(
          args.sublist(vprev, vprev + 4), ['[vprev]', '-q:v', '4', '/prev.jpg'],
          reason: 'the display copy is always a jpeg');
    });

    test('never emits the single-output -vf flag', () {
      // -vf applies to one output only; leaving it in would make ffmpeg
      // re-read the input for the second output and defeat the whole point.
      expect(combined().contains('-vf'), isFalse);
    });

    test('both output paths appear exactly once', () {
      final args = combined();
      expect(args.where((a) => a == '/out.jpg').length, 1);
      expect(args.where((a) => a == '/prev.jpg').length, 1);
    });
  });
}

/// Identity 4x5, used to assert what a zero-strength preset must equal.
List<double> identity44() => <double>[
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ];
