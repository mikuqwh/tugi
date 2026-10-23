/// Device test: both Compress GIFs modes actually run on the device.
///
/// The frame-rate maths is the risky part: `fps=` has to produce FEWER frames
/// at the SAME duration, and only the device's ffmpeg-kit build can prove it
/// (the host's ffmpeg is a different binary; see tool/wmprobe for the host
/// side of the same checks).
// SPDX-License-Identifier: GPL-3.0-or-later

library compress_gif_device_test;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/services/compress_gif_service.dart';
import 'package:tugi/utils/gif_reader.dart' as gr;

/// A 320x180 / 2 s / 30 fps GIF (60 frames) built by ffmpeg-kit.
Future<String> _makeSourceGif(String dir) async {
  final path = '$dir/compress_source.gif';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=320x180:rate=30:duration=2',
    '-vf',
    'fps=30,split[s1][s2];[s1]palettegen=stats_mode=single[p];'
        '[s2][p]paletteuse=new=1',
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
  return path;
}

void main() {
  testWidgets('Reduce Resolution halves the picture, keeps the frames',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final before = gr.GifReader.parse(File(source).readAsBytesSync());

    final service = CompressGifService(workDir: dir);
    final out = await service.compress(inputPath: source, ratio: 0.5);
    final after = gr.GifReader.parse(File(out).readAsBytesSync());

    expect(after.width, (before.width / 2).round());
    expect(after.height, (before.height / 2).round());
    expect(after.frames, before.frames);
    expect(File(out).lengthSync(), lessThan(File(source).lengthSync()));
  });

  testWidgets('Extract Frames keeps the duration and drops frames',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);
    final before = gr.GifReader.parse(File(source).readAsBytesSync());
    final sourceBytes = File(source).lengthSync();
    final sourceFps = before.frames * 1000 / before.durationMs;

    final service = CompressGifService(workDir: dir);
    final out = await service.compressByFrameStep(
      inputPath: source,
      frameStep: 3,
      sourceFps: sourceFps,
    );
    final after = gr.GifReader.parse(File(out).readAsBytesSync());

    // One frame in three, at the same size...
    expect(after.frames, closeTo(before.frames / 3, 2));
    expect(after.width, before.width);
    expect(after.height, before.height);
    // ...and the same wall-clock length, so the GIF does not play faster.
    expect(after.durationMs, closeTo(before.durationMs, 120));
    // The whole point: fewer bytes.
    expect(File(out).lengthSync(), lessThan(sourceBytes));
  });
}
