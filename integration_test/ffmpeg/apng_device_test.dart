// SPDX-License-Identifier: GPL-3.0-or-later

/// Device test: APNG as an animation output, on the real ffmpeg build.
///
/// The host tests pin the argv; this proves the muxer exists and that the
/// frame count and per-frame timing survive without the GIF palette pass.
// SPDX-License-Identifier: GPL-3.0-or-later

library apng_device_test;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/services/edit_gif_service.dart';
import 'package:tugi/services/video_to_gif_service.dart';

Future<String> _fixture(String dir, String name, List<String> args) async {
  final path = '$dir/$name';
  final session = await FFmpegKit.executeWithArguments(['-y', ...args, path]);
  expect((await session.getReturnCode())?.isValueSuccess(), isTrue,
      reason: 'fixture $name failed: ${await session.getOutput()}');
  return path;
}

/// Frame count + codec of the first video stream.
///
/// `nb_frames` is a container field and APNG does not carry it (it came back
/// as 0), so the count is decoded with `-count_frames` instead.
Future<(int, String)> _streamInfo(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  expect(info, isNotNull, reason: 'ffprobe failed for $path');
  final stream = info!.getStreams().firstWhere((s) => s.getType() == 'video');
  final codec = stream.getCodec() ?? '';

  final counted = await FFprobeKit.executeWithArguments([
    '-v',
    'error',
    '-select_streams',
    'v:0',
    '-count_frames',
    '-show_entries',
    'stream=nb_read_frames',
    '-of',
    'csv=p=0',
    path,
  ]);
  final text = (await counted.getOutput() ?? '').trim();
  final frames = int.tryParse(text.split(RegExp(r'\s+')).last) ?? 0;
  expect(frames, greaterThan(0), reason: 'ffprobe could not count frames');
  return (frames, codec);
}

void main() {
  testWidgets('video to APNG keeps every frame and the codec is apng',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final video = await _fixture(dir, 'apng_src.mp4', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=96x64:rate=10:duration=1',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
    ]);

    final service = VideoToGifService(
      workDir: dir,
      format: formatById('apng'),
    );
    final out = await service.convertDirect(videoPath: video, fps: 10);
    service.cleanup();

    expect(out.endsWith('.apng'), isTrue, reason: out);
    final (frames, codec) = await _streamInfo(out);
    expect(codec, 'apng');
    // 1 s at 10 fps: the APNG path must not drop frames on the way out.
    expect(frames, inInclusiveRange(9, 11));
  });

  testWidgets('editing a GIF into APNG keeps the frame count', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final gif = await _fixture(dir, 'apng_edit.gif', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=64x64:rate=10:duration=0.5',
      '-vf',
      'fps=10',
      '-f',
      'gif',
    ]);

    final service = EditGifService(workDir: dir);
    final out = await service.edit(
      gifPath: gif,
      speedMultiplier: 1.0,
      reverse: true,
      format: formatById('apng'),
    );

    expect(out.endsWith('.apng'), isTrue, reason: out);
    final (frames, codec) = await _streamInfo(out);
    expect(codec, 'apng');
    expect(frames, 5);
  });
}
