// SPDX-License-Identifier: GPL-3.0-or-later

/// Device test: extracting audio from a real video, both paths.
///
/// The copy path is the one that needs a device: it only works if the
/// bundled ffmpeg-kit build accepts `-c:a copy` into an M4A, and the whole
/// promise of "lossless and instant" rests on that.
// SPDX-License-Identifier: GPL-3.0-or-later

library extract_audio_device_test;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/services/audio_extract_service.dart';

/// A 3 s 160x120 H.264 + AAC video.
Future<String> _makeVideo(String dir) async {
  final path = '$dir/audio_source.mp4';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=160x120:rate=10:duration=3',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:duration=3',
    '-c:v',
    'libx264',
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-pix_fmt',
    'yuv420p',
    path,
  ]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture video failed: ${await session.getOutput()}');
  return path;
}

Future<Map<String, String?>> _probeStreams(String path, String type) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  expect(info, isNotNull, reason: 'ffprobe returned nothing for $path');
  final stream = info!.getStreams().firstWhere(
        (s) => s.getType() == type,
        orElse: () => throw StateError('no $type stream in $path'),
      );
  return {
    'codec': stream.getCodec(),
    'duration': info.getDuration(),
  };
}

void main() {
  testWidgets('probe reports the audio track of a video', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final video = await _makeVideo(dir);

    final info = await AudioExtractService(workDir: dir).probe(video);
    expect(info, isNotNull);
    expect(info!.hasAudio, isTrue);
    expect(info.codec, 'aac');
    expect(info.duration.inMilliseconds, closeTo(3000, 200));
    expect(info.bitrateKbps, greaterThan(0));
    // aac -> m4a is copyable; aac -> mp3 is not.
    expect(info.canCopyTo(formatById('m4a')!), isTrue);
    expect(info.canCopyTo(formatById('mp3')!), isFalse);
  });

  testWidgets('a stream copy keeps the audio codec and the duration',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final video = await _makeVideo(dir);
    final service = AudioExtractService(workDir: dir);

    final out = await service.extract(
      inputPath: video,
      format: formatById('m4a')!,
      quality: 192,
      copy: true,
    );

    expect(File(out).existsSync(), isTrue);
    final source = await _probeStreams(video, 'audio');
    final extracted = await _probeStreams(out, 'audio');
    expect(extracted['codec'], source['codec']);
    expect(double.parse(extracted['duration']!),
        closeTo(double.parse(source['duration']!), 0.1));
    // A copy is smaller than the video that carried it, but not empty.
    expect(File(out).lengthSync(), greaterThan(1000));
    expect(File(out).lengthSync(), lessThan(File(video).lengthSync()));
  });

  testWidgets('a re-encode produces a valid MP3 with the same duration',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final video = await _makeVideo(dir);
    final service = AudioExtractService(workDir: dir);

    final out = await service.extract(
      inputPath: video,
      format: formatById('mp3')!,
      quality: 128,
      copy: false,
    );

    expect(File(out).existsSync(), isTrue);
    final streams = await _probeStreams(out, 'audio');
    expect(streams['codec'], 'mp3');
    expect(double.parse(streams['duration']!), closeTo(3.0, 0.2));
  });

  testWidgets('a video with no audio track is reported as such',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final silent = '$dir/silent.mp4';
    await FFmpegKit.executeWithArguments([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=160x120:rate=10:duration=1',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      silent,
    ]);

    final info = await AudioExtractService(workDir: dir).probe(silent);
    expect(info, isNotNull);
    expect(info!.hasAudio, isFalse);
    expect(info.canCopyTo(formatById('m4a')!), isFalse);
  });
}
