/// Device matrix: every format in the registry, converted for real (S3.1).
///
/// S3 shipped the three conversion paths and verified four representative
/// cases; the exhaustive per-format run was deferred. This is that run: one
/// tiny source per kind, every available target, each output opened by ffprobe
/// and compared against the codec the registry promised.
///
/// A failure here is information, not necessarily a bug: it says this ffmpeg
/// build cannot write that format the way we assumed, and the registry entry
/// should be corrected (or probed out) rather than the test relaxed.
// SPDX-License-Identifier: GPL-3.0-or-later

library convert_matrix_device_test;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/convert/capability_probe.dart';
import 'package:tugi/services/convert_service.dart';

/// The codec ffprobe should report for each format id.
///
/// Two entries look "wrong" and are not: ffprobe names the STREAM codec, not
/// the container. An APNG's frames are PNG (`codec=png`, the apng demuxer
/// only knows it is animated from its own chunk handling), and an ICO embeds
/// a BMP DIB (`codec=bmp`). Both were measured, not assumed.
const Map<String, String> expectedCodec = {
  'png': 'png',
  'jpg': 'mjpeg',
  'webp': 'webp',
  'avif': 'av1',
  'gif': 'gif',
  'apng': 'png',
  'bmp': 'bmp',
  'tiff': 'tiff',
  'j2k': 'jpeg2000',
  'qoi': 'qoi',
  'ico': 'bmp',
  'tga': 'targa',
  'exr': 'exr',
  'pam': 'pam',
  'ppm': 'ppm',
  'mp3': 'mp3',
  'm4a': 'aac',
  'aac': 'aac',
  'flac': 'flac',
  'ogg': 'vorbis',
  'opus': 'opus',
  'wav': 'pcm_s16le',
  'mp4_h264': 'h264',
  'mp4_h265': 'hevc',
  'webm_vp9': 'vp9',
  'mkv_h264': 'h264',
  'mov_h264': 'h264',
  'avi_mjpeg': 'mjpeg',
};

Future<String> _fixture(String dir, String name, List<String> args) async {
  final path = '$dir/$name';
  final session = await FFmpegKit.executeWithArguments(['-y', ...args, path]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture $name: ${await session.getOutput()}');
  return path;
}

/// Codec of the first stream (video preferred), or '' when ffprobe sees none.
Future<String> _codec(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = session.getMediaInformation();
  if (info == null) return '';
  final streams = info.getStreams();
  final video = streams.where((s) => s.getType() == 'video');
  if (video.isNotEmpty) return video.first.getCodec() ?? '';
  final audio = streams.where((s) => s.getType() == 'audio');
  return audio.isEmpty ? '' : (audio.first.getCodec() ?? '');
}

void main() {
  testWidgets('every image format in the registry converts on device',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _fixture(dir, 'matrix_src.png', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=64x64',
      '-frames:v',
      '1',
    ]);
    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed, isNotNull);

    final names = await CapabilityProbe().availableNames();
    final targets = availableFormats(names, kind: MediaKind.image);
    expect(targets.length, greaterThanOrEqualTo(10),
        reason: 'capability probe hid too much: ${targets.map((f) => f.id)}');

    final failures = <String>[];
    for (final format in targets) {
      try {
        final out = await service.convert(ConvertRequest(
          source: probed!,
          format: format,
          quality: 85,
          backgroundArgb: 0xFFFFFF,
        ));
        expect(File(out).existsSync(), isTrue, reason: format.id);
        expect(File(out).lengthSync(), greaterThan(0), reason: format.id);
        final codec = await _codec(out);
        final want = expectedCodec[format.id];
        if (want != null && codec != want) {
          failures.add('${format.id}: codec=$codec want=$want');
        }
      } catch (e) {
        failures.add('${format.id}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  testWidgets('every audio format in the registry converts on device',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _fixture(dir, 'matrix_src.m4a', [
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
    ]);
    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed, isNotNull);

    final names = await CapabilityProbe().availableNames();
    final targets = availableFormats(names, kind: MediaKind.audio);

    final failures = <String>[];
    for (final format in targets) {
      try {
        final out = await service.convert(ConvertRequest(
          source: probed!,
          format: format,
          quality: 128,
        ));
        expect(File(out).existsSync(), isTrue, reason: format.id);
        final codec = await _codec(out);
        final want = expectedCodec[format.id];
        if (want != null && codec != want) {
          failures.add('${format.id}: codec=$codec want=$want');
        }
      } catch (e) {
        failures.add('${format.id}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  testWidgets('every video container in the registry converts on device',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _fixture(dir, 'matrix_src.mp4', [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=64x64:rate=10:duration=0.3',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
    ]);
    final service = ConvertService(workDir: dir);
    final probed = await service.probe(source);
    expect(probed, isNotNull);

    final names = await CapabilityProbe().availableNames();
    final targets = availableFormats(names, kind: MediaKind.video)
        .where((f) => f.kind == MediaKind.video);

    final failures = <String>[];
    for (final format in targets) {
      try {
        final out = await service.convert(ConvertRequest(
          source: probed!,
          format: format,
          quality: 70,
          dropAudio: true,
        ));
        expect(File(out).existsSync(), isTrue, reason: format.id);
        final codec = await _codec(out);
        final want = expectedCodec[format.id];
        if (want != null && codec != want) {
          failures.add('${format.id}: codec=$codec want=$want');
        }
      } catch (e) {
        failures.add('${format.id}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
