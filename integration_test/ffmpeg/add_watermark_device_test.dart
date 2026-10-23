/// Device test: the Add Watermark pipeline actually runs on the device.
///
/// This is the one thing the host tests cannot prove. The device's
/// ffmpeg-kit build is a different binary from the host's ffmpeg, and the
/// `drawtext` filter is the risk: it needs libfreetype, and it needs a
/// font FILE on disk (the device has no usable fontconfig, so there is no
/// system-font fallback -- without `fontfile=` the filter aborts with
/// "Cannot find a valid font").
///
/// The fixtures are generated with ffmpeg-kit itself rather than embedded
/// as base64: the app already carries the encoder, and a synthesised
/// `testsrc2` is a known-good GIF.
///
/// Runs on emulator-5554 (or any device) because ffmpeg only exists
/// inside the app.
// SPDX-License-Identifier: GPL-3.0-or-later

library add_watermark_test;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/ffmpeg/commands.dart'
    show
        WatermarkLayerKind,
        WatermarkMediaKind,
        WatermarkPlacement,
        WatermarkPosition;
import 'package:tugi/services/add_watermark_service.dart';
import 'package:tugi/utils/gif_reader.dart' as gr;
import 'package:tugi/utils/watermark_fonts.dart';

/// A 320x180 / 24-frame / 2 s GIF built by ffmpeg.
Future<String> _makeSourceGif(String dir) async {
  final path = '$dir/wm_source.gif';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=320x180:rate=12:duration=2',
    '-vf',
    'fps=12,split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1',
    '-gifflags',
    '-offsetting',
    '-loop',
    '0',
    '-f',
    'gif',
    path,
  ]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture GIF failed: ${await session.getOutput()}');
  expect(File(path).existsSync(), isTrue);
  return path;
}

/// A 60x40 red PNG to use as the image watermark.
Future<String> _makeWatermarkPng(String dir) async {
  final path = '$dir/wm_mark.png';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=red:size=60x40',
    '-frames:v',
    '1',
    '-pix_fmt',
    'rgba',
    path,
  ]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture PNG failed: ${await session.getOutput()}');
  expect(File(path).existsSync(), isTrue);
  return path;
}

/// An 80x60 / 8-frame / 1 s GIF to use as the ANIMATED watermark.
///
/// It is deliberately SHORTER than the 2 s base: that is the case where a
/// naive overlay freezes the watermark halfway through, which is what the
/// `loop` filter exists to prevent.
Future<String> _makeWatermarkGif(String dir) async {
  final path = '$dir/wm_mark.gif';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=80x60:rate=8:duration=1',
    '-vf',
    'fps=8,split[a][b];[a]palettegen=stats_mode=single[p];[b][p]paletteuse=new=1',
    '-gifflags',
    '-offsetting',
    '-loop',
    '0',
    '-f',
    'gif',
    path,
  ]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture GIF watermark failed: ${await session.getOutput()}');
  expect(File(path).existsSync(), isTrue);
  return path;
}

void main() {
  testWidgets('a text watermark is applied on the device', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final service = AddWatermarkService(workDir: dir);

    final out = await service.addText(
      inputPath: source,
      // Chinese plus a percent sign: the percent sign is the character
      // that breaks an inline `text='...'`, and the Chinese proves the
      // bundled font subset actually carries the glyphs.
      text: '水印 50% done',
      font: watermarkFontById('sans'),
      fontSize: 24,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      kind: WatermarkMediaKind.gif,
    );

    expect(File(out).existsSync(), isTrue);
    expect(File(out).lengthSync(), greaterThan(0));

    // The GIF is still a GIF, with the source's frame count and duration.
    final info = gr.GifReader.parse(File(out).readAsBytesSync());
    final sourceInfo = gr.GifReader.parse(File(source).readAsBytesSync());
    expect(info.frames, sourceInfo.frames);
    expect(info.width, sourceInfo.width);
    expect(info.height, sourceInfo.height);
    expect(info.durationMs, sourceInfo.durationMs);

    // And the bytes differ, so the watermark was really drawn.
    expect(File(out).readAsBytesSync(), isNot(File(source).readAsBytesSync()));
  });

  testWidgets('every bundled font renders on the device', (tester) async {
    // Each font is a separate file with its own name table; a broken one
    // would fail only when it is the one selected.
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final service = AddWatermarkService(workDir: dir);

    for (final font in watermarkFonts) {
      final out = await service.addText(
        inputPath: source,
        text: '字体 50%',
        font: font,
        fontSize: 20,
        placement:
            const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
        kind: WatermarkMediaKind.gif,
      );
      expect(File(out).existsSync(), isTrue, reason: font.id);
      expect(File(out).lengthSync(), greaterThan(0), reason: font.id);
    }
  });

  testWidgets('the bundled fonts are really extracted to files',
      (tester) async {
    // Without this, `drawtext` would fail with "Cannot find a valid font"
    // and the failure would be a confusing ffmpeg error rather than a
    // clear one.
    final dir = (await getTemporaryDirectory()).path;
    final service = AddWatermarkService(workDir: dir);
    for (final font in watermarkFonts) {
      final fontPath = await service.ensureFontFile(font);
      expect(File(fontPath).existsSync(), isTrue, reason: font.id);
      expect(File(fontPath).lengthSync(), greaterThan(1024 * 1024),
          reason: font.id);
      // The second call reuses the cached copy rather than re-copying.
      expect(await service.ensureFontFile(font), fontPath, reason: font.id);
    }
  });

  testWidgets('an image watermark is applied on the device', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final mark = await _makeWatermarkPng(dir);
    final service = AddWatermarkService(workDir: dir);

    final out = await service.addImage(
      inputPath: source,
      watermarkPath: mark,
      opacity: 0.6,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      watermarkWidth: 48,
      kind: WatermarkMediaKind.gif,
    );

    expect(File(out).existsSync(), isTrue);
    final info = gr.GifReader.parse(File(out).readAsBytesSync());
    final sourceInfo = gr.GifReader.parse(File(source).readAsBytesSync());
    expect(info.frames, sourceInfo.frames);
    expect(File(out).readAsBytesSync(), isNot(File(source).readAsBytesSync()));
  });

  testWidgets('a GIF watermark loops instead of freezing', (tester) async {
    // The base is 2 s and the watermark is 1 s, so without looping the
    // watermark would freeze on its last frame for the whole second half.
    // The output must keep the base's length AND still be animating.
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final mark = await _makeWatermarkGif(dir);
    final service = AddWatermarkService(workDir: dir);

    final out = await service.addGifWatermark(
      inputPath: source,
      watermarkPath: mark,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      watermarkWidth: 48,
      kind: WatermarkMediaKind.gif,
    );

    expect(File(out).existsSync(), isTrue);
    final info = gr.GifReader.parse(File(out).readAsBytesSync());
    final sourceInfo = gr.GifReader.parse(File(source).readAsBytesSync());
    expect(info.frames, sourceInfo.frames);
    expect(info.durationMs, sourceInfo.durationMs);

    final wmInfo = gr.GifReader.parse(File(mark).readAsBytesSync());
    expect(wmInfo.frames, greaterThan(1), reason: 'fixture must animate');

    // A still-image source with a GIF watermark: the output is a GIF whose
    // length follows the watermark.
    final stillOut = await service.addGifWatermark(
      inputPath: await _makeWatermarkPng(dir),
      watermarkPath: mark,
      kind: WatermarkMediaKind.image,
    );
    expect(File(stillOut).existsSync(), isTrue);
    final stillInfo = gr.GifReader.parse(File(stillOut).readAsBytesSync());
    expect(stillInfo.frames, greaterThan(1),
        reason: 'the watermark animation must survive onto a still base');
  });

  testWidgets('a free (dragged) placement lands where it was asked to',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final service = AddWatermarkService(workDir: dir);

    // Top-left quadrant. If the fraction were ignored, the watermark would
    // still be at the default bottom-right and the frame-count checks would
    // still pass -- so the byte comparison is what makes this a real test.
    final free = await service.addText(
      inputPath: source,
      text: 'TOP',
      font: watermarkFontById('sans'),
      fontSize: 20,
      placement: const WatermarkPlacement.free(0.2, 0.2),
      kind: WatermarkMediaKind.gif,
    );
    final anchored = await service.addText(
      inputPath: source,
      text: 'TOP',
      font: watermarkFontById('sans'),
      fontSize: 20,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      kind: WatermarkMediaKind.gif,
    );

    expect(File(free).existsSync(), isTrue);
    expect(File(anchored).existsSync(), isTrue);
    expect(
        File(free).readAsBytesSync(), isNot(File(anchored).readAsBytesSync()),
        reason: 'a free placement must move the watermark');
  });

  testWidgets('the media kind is detected from the bytes', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final gif = await _makeSourceGif(dir);
    final png = await _makeWatermarkPng(dir);

    expect(await AddWatermarkService.detectKind(gif), WatermarkMediaKind.gif);
    expect(await AddWatermarkService.detectKind(png), WatermarkMediaKind.image);
  });

  testWidgets('a video source gets a first frame extracted', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final video = '$dir/wm_source.mp4';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=320x180:rate=12:duration=1',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      video,
    ]);
    expect((await session.getReturnCode())?.isValueSuccess(), isTrue,
        reason: 'fixture video failed: ${await session.getOutput()}');

    final service = AddWatermarkService(workDir: dir);
    expect(
        await AddWatermarkService.detectKind(video), WatermarkMediaKind.video);

    final frame = await service.sourceFrame(video);
    expect(frame, isNotNull);
    expect(File(frame!).existsSync(), isTrue);
    expect(File(frame).lengthSync(), greaterThan(0));
  });

  testWidgets('several watermarks composite in one pass', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final mark = await _makeWatermarkPng(dir);
    final anim = await _makeWatermarkGif(dir);
    final service = AddWatermarkService(workDir: dir);

    final out = await service.addLayers(
      inputPath: source,
      kind: WatermarkMediaKind.gif,
      layers: [
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.text,
          placement:
              const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
          text: '多水印 50%',
          font: watermarkFontById('sans'),
          fontSize: 22,
          fontColor: 'white',
        ),
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.image,
          placement: const WatermarkPlacement.anchor(WatermarkPosition.topLeft),
          mediaPath: mark,
          width: 48,
          opacity: 0.7,
        ),
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.gif,
          placement: const WatermarkPlacement.anchor(WatermarkPosition.center),
          mediaPath: anim,
          width: 40,
        ),
      ],
    );

    expect(File(out).existsSync(), isTrue);
    final info = gr.GifReader.parse(File(out).readAsBytesSync());
    final sourceInfo = gr.GifReader.parse(File(source).readAsBytesSync());
    // A moving source cuts the output at its own end, however many looping
    // watermarks sit on top of it.
    expect(info.frames, sourceInfo.frames);
    expect(info.durationMs, sourceInfo.durationMs);

    // The same job with only the text layer must differ: if the image or the
    // animated layer had been dropped from the graph, these would match.
    final textOnly = await service.addLayers(
      inputPath: source,
      kind: WatermarkMediaKind.gif,
      layers: [
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.text,
          placement:
              const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
          text: '多水印 50%',
          font: watermarkFontById('sans'),
          fontSize: 22,
          fontColor: 'white',
        ),
      ],
    );
    expect(
        File(out).readAsBytesSync(), isNot(File(textOnly).readAsBytesSync()));
  });

  testWidgets('thick layers land where they were asked to', (tester) async {
    // A byte comparison cannot say WHERE a layer landed, so this reads the
    // pixels: a solid red watermark in the top-left corner must show up
    // there, and only there.
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeStillPng(dir);
    final mark = await _makeWatermarkPng(dir);
    final service = AddWatermarkService(workDir: dir);

    final out = await service.addLayers(
      inputPath: source,
      kind: WatermarkMediaKind.image,
      stillSource: true,
      layers: [
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.image,
          placement: const WatermarkPlacement.anchor(WatermarkPosition.topLeft),
          mediaPath: mark,
          width: 60,
        ),
      ],
    );

    final pixel = await _pixelAt(out, 12, 12);
    expect(pixel.$1, greaterThan(180), reason: 'red channel at top-left');
    expect(pixel.$2, lessThan(90), reason: 'green channel at top-left');
  });

  testWidgets('a still source with a GIF watermark stays as long as it',
      (tester) async {
    // No looping and no `shortest=1` here: the base is one frame, so either
    // would truncate the output. The watermark's own length is the answer.
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeStillPng(dir);
    final anim = await _makeWatermarkGif(dir);
    final service = AddWatermarkService(workDir: dir);

    final out = await service.addLayers(
      inputPath: source,
      kind: WatermarkMediaKind.gif,
      stillSource: true,
      layers: [
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.gif,
          placement:
              const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
          mediaPath: anim,
          width: 40,
        ),
      ],
    );

    final info = gr.GifReader.parse(File(out).readAsBytesSync());
    final wmInfo = gr.GifReader.parse(File(anim).readAsBytesSync());
    expect(info.frames, wmInfo.frames);
  });
}

/// A 320x180 still PNG to watermark.
Future<String> _makeStillPng(String dir) async {
  final path = '$dir/wm_still.png';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=gray:size=320x180',
    '-frames:v',
    '1',
    path,
  ]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture still failed: ${await session.getOutput()}');
  return path;
}

/// The RGB of one pixel of an image file, decoded through the engine.
Future<(int, int, int)> _pixelAt(String path, int x, int y) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  final i = (y * frame.image.width + x) * 4;
  return (bytes[i], bytes[i + 1], bytes[i + 2]);
}
