// SPDX-License-Identifier: GPL-3.0-or-later

/// Device test: the output formats added to the existing features.
///
/// The pickers are UI; what matters is that the container/codec actually
/// changes on the device's ffmpeg build and the file is what it claims to be.
// SPDX-License-Identifier: GPL-3.0-or-later

library output_format_device_test;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart' show formatById;
import 'package:path_provider/path_provider.dart';

import 'package:tugi/ffmpeg/commands.dart'
    show
        WatermarkLayerKind,
        WatermarkMediaKind,
        WatermarkPlacement,
        WatermarkPosition;
import 'package:tugi/services/add_watermark_service.dart';
import 'package:tugi/services/gif_to_images_service.dart';
import 'package:tugi/services/gif_to_video_service.dart';
import 'package:tugi/utils/watermark_fonts.dart';

Future<String> _fixture(String dir, String name, List<String> args) async {
  final path = '$dir/$name';
  final session = await FFmpegKit.executeWithArguments(['-y', ...args, path]);
  expect((await session.getReturnCode())?.isValueSuccess(), isTrue,
      reason: 'fixture $name failed: ${await session.getOutput()}');
  return path;
}

Future<String> _codecOf(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  expect(info, isNotNull, reason: 'ffprobe failed for $path');
  final streams = info!.getStreams();
  final video = streams.where((s) => s.getType() == 'video');
  if (video.isNotEmpty) return video.first.getCodec() ?? '';
  final audio = streams.where((s) => s.getType() == 'audio');
  return audio.isEmpty ? '' : (audio.first.getCodec() ?? '');
}

void main() {
  testWidgets('GIF to WebM writes VP9, not an mp4', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final gif = await _fixture(dir, 'fmt_src.gif', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=120x90:rate=10:duration=0.5',
      '-vf',
      'fps=10',
      '-f',
      'gif',
    ]);

    final service = GifToVideoService(
      workDir: dir,
      format: formatById('webm_vp9'),
    );
    final out = await service.convert(gifPath: gif, fps: 10);

    expect(out.endsWith('.webm'), isTrue);
    expect(File(out).existsSync(), isTrue);
    expect(await _codecOf(out), 'vp9');
  });

  testWidgets('GIF to Images can write JPEG frames', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final gif = await _fixture(dir, 'fmt_frames.gif', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=80x60:rate=10:duration=0.4',
      '-vf',
      'fps=10',
      '-f',
      'gif',
    ]);

    final service = GifToImagesService(workDir: dir);
    final frames = await service.extractFrames(
      gif,
      format: formatById('jpg'),
      quality: 90,
    );

    expect(frames, isNotEmpty);
    expect(frames.every((f) => f.toLowerCase().endsWith('.jpg')), isTrue);
    expect(await _codecOf(frames.first), 'mjpeg');
  });

  testWidgets('a watermarked still can be saved as JPEG', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final still = await _fixture(dir, 'fmt_still.png', [
      '-f',
      'lavfi',
      '-i',
      'color=c=navy:size=120x90',
      '-frames:v',
      '1',
    ]);

    final service = AddWatermarkService(workDir: dir);
    final out = await service.addLayers(
      inputPath: still,
      kind: WatermarkMediaKind.image,
      layers: [
        WatermarkLayerRequest(
          kind: WatermarkLayerKind.text,
          placement: const WatermarkPlacement.anchor(
            WatermarkPosition.bottomRight,
          ),
          text: 'Tugi',
          font: watermarkFontById('sans'),
        ),
      ],
      format: formatById('jpg'),
    );

    expect(out.endsWith('.jpg'), isTrue);
    expect(await _codecOf(out), 'mjpeg');
  });
}
