// SPDX-License-Identifier: GPL-3.0-or-later

/// Device test: Images to Video into WebM and MKV, not just MP4.
///
/// The segment/join split is the risk: each image is encoded as its own
/// segment and the join is a stream copy, so a container mismatch shows up as
/// a zero-length video rather than an ffmpeg error.
// SPDX-License-Identifier: GPL-3.0-or-later

library images_to_video_containers_device_test;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/services/images_to_video_service.dart';

Future<List<String>> _fixtureImages(String dir) async {
  final paths = <String>[];
  for (final (i, size) in [(0, '96x64'), (1, '96x64'), (2, '96x64')]) {
    final path = '$dir/itv_$i.png';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'color=c=0x3366cc:size=$size',
      '-frames:v',
      '1',
      path,
    ]);
    expect((await session.getReturnCode())?.isValueSuccess(), isTrue,
        reason: 'fixture $i: ${await session.getOutput()}');
    paths.add(path);
  }
  return paths;
}

Future<(String, double)> _videoInfo(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  expect(info, isNotNull, reason: 'ffprobe failed for $path');
  final stream = info!.getStreams().firstWhere((s) => s.getType() == 'video');
  return (
    stream.getCodec() ?? '',
    double.tryParse(info.getDuration() ?? '') ?? 0,
  );
}

void main() {
  for (final (id, codec, ext) in [
    ('mp4_h265', 'hevc', 'mp4'),
    ('webm_vp9', 'vp9', 'webm'),
    ('mkv_h264', 'h264', 'mkv'),
  ]) {
    testWidgets('Images to Video writes $id', (tester) async {
      final dir = (await getTemporaryDirectory()).path;
      final images = await _fixtureImages(dir);
      final out = '$dir/itv_out_$id.$ext';

      final service = ImagesToVideoService(
        workDir: dir,
        format: formatById(id),
      );
      final result = await service.convertImagesToVideo(
        imagePaths: images,
        outputPath: out,
        secondsPerImage: 1,
        fps: 10,
      );
      service.cleanup();

      expect(File(result.outputPath).existsSync(), isTrue);
      final (actualCodec, duration) = await _videoInfo(result.outputPath);
      expect(actualCodec, codec);
      // 3 images x 1 s.
      expect(duration, closeTo(3.0, 0.4));
    });
  }
}
