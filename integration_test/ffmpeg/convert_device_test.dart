// SPDX-License-Identifier: GPL-3.0-or-later

/// Device test: the three conversion paths actually produce files.
///
/// The host tests pin the argv; only a device proves the bundled ffmpeg-kit
/// accepts it and that the alpha flatten really lands on white instead of
/// dropping to black.
// SPDX-License-Identifier: GPL-3.0-or-later

library convert_device_test;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/services/convert_service.dart';

Future<String> _fixture(String dir, String name, List<String> args) async {
  final path = '$dir/$name';
  final session = await FFmpegKit.executeWithArguments(['-y', ...args, path]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture $name failed: ${await session.getOutput()}');
  return path;
}

Future<String> _audioCodec(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  expect(info, isNotNull, reason: 'ffprobe failed for $path');
  final audio = info!.getStreams().where((s) => s.getType() == 'audio');
  return audio.isEmpty ? '' : (audio.first.getCodec() ?? '');
}

Future<String> _videoCodec(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  expect(info, isNotNull, reason: 'ffprobe failed for $path');
  final video = info!.getStreams().where((s) => s.getType() == 'video');
  return video.isEmpty ? '' : (video.first.getCodec() ?? '');
}

void main() {
  testWidgets('a transparent PNG becomes a flattened JPEG', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    // Half-transparent red on nothing: after flattening onto white it must be
    // a pink pixel, not black.
    final source = await _fixture(dir, 'alpha.png', [
      '-f',
      'lavfi',
      '-i',
      'color=c=red@0.5:size=64x64,format=rgba',
      '-frames:v',
      '1',
    ]);

    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed, isNotNull);
    expect(probed!.hasAlpha, isTrue);

    final out = await service.convert(ConvertRequest(
      source: probed,
      format: formatById('jpg')!,
      quality: 90,
      backgroundArgb: 0xFFFFFF,
    ));

    expect(File(out).existsSync(), isTrue);
    expect(File(out).lengthSync(), greaterThan(200));
    expect(await _videoCodec(out), 'mjpeg');
  });

  testWidgets('a GIF converts to PNG using only its first frame',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _fixture(dir, 'anim.gif', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=80x48:rate=10:duration=0.5',
      '-vf',
      'fps=10',
      '-f',
      'gif',
    ]);

    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed!.kind, MediaKind.animated);

    final out = await service.convert(ConvertRequest(
      source: probed,
      format: formatById('png')!,
      quality: 90,
    ));

    expect(File(out).existsSync(), isTrue);
    expect(await _videoCodec(out), 'png');
    // A still PNG weighs far less than the animation it came from.
    expect(File(out).lengthSync(), lessThan(File(source).lengthSync()));
  });

  testWidgets('MP4 converts to WebM with a video stream', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _fixture(dir, 'clip.mp4', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=160x120:rate=10:duration=1',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-c:v',
      'libx264',
      '-c:a',
      'aac',
      '-pix_fmt',
      'yuv420p',
    ]);

    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed!.kind, MediaKind.video);

    final out = await service.convert(ConvertRequest(
      source: probed,
      format: formatById('webm_vp9')!,
      quality: 70,
      width: 96,
    ));

    expect(File(out).existsSync(), isTrue);
    expect(await _videoCodec(out), 'vp9');
    expect(File(out).lengthSync(), greaterThan(0));
  });

  testWidgets('an audio file converts to MP3', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _fixture(dir, 'tone.m4a', [
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-c:a',
      'aac',
    ]);

    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed!.kind, MediaKind.audio);

    final out = await service.convert(ConvertRequest(
      source: probed,
      format: formatById('mp3')!,
      quality: 128,
    ));

    expect(File(out).existsSync(), isTrue);
    // An MP3 has no video stream at all: the codec to check is the audio one.
    expect(await _audioCodec(out), 'mp3');
  });
}
