/// The single-file converter's service (Tugi S3).
///
/// One probe, three dispatch paths (image / video / audio), one output. The
/// decisions the screen relies on are made here and are all driven by facts
/// from ffprobe, not by the file extension:
///
///  * what the source actually is (an image can be called `.gif`);
///  * whether it has alpha (to decide on the background flatten);
///  * whether it has audio (video -> video without audio must not invent one);
///  * whether an audio conversion can be a stream copy.
// SPDX-License-Identifier: GPL-3.0-or-later

library convert_service;

import 'dart:io';

import 'ffmpeg_progress.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:format_core/format_core.dart';

import '../ffmpeg/convert_commands.dart' as commands;

class ConvertException implements Exception {
  ConvertException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the source file is, in the converter's terms.
class ConvertSource {
  const ConvertSource({
    required this.path,
    required this.kind,
    required this.bytes,
    required this.width,
    required this.height,
    required this.duration,
    required this.hasAudio,
    required this.audioCodec,
    required this.videoCodec,
    required this.hasAlpha,
    required this.frames,
  });

  final String path;
  final MediaKind kind;
  final int bytes;
  final int width;
  final int height;
  final Duration duration;
  final bool hasAudio;
  final String audioCodec;
  final String videoCodec;
  final bool hasAlpha;

  /// Frame count when the container reports one (animated sources); 0 when it
  /// does not.
  final int frames;

  String get sizeLabel => '$width×$height';
}

/// One conversion, as the screen describes it.
///
/// A value object rather than a long argument list because the screen injects
/// a fake converter in tests and a six-argument callback is unreadable.
class ConvertRequest {
  const ConvertRequest({
    required this.source,
    required this.format,
    required this.quality,
    this.width,
    this.fps,
    this.dropAudio = false,
    this.hardware = false,
    this.backgroundArgb = 0xFFFFFFFF,
  });

  final ConvertSource source;
  final FormatSpec format;
  final int quality;
  final int? width;
  final double? fps;
  final bool dropAudio;
  final bool hardware;
  final int backgroundArgb;
}

class ConvertService {
  ConvertService({required this.workDir});

  final String workDir;

  /// Read what [path] is. Returns null when ffprobe cannot make sense of it.
  Future<ConvertSource?> probe(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;

      final streams = info.getStreams();
      final videoStreams =
          streams.where((s) => s.getType() == 'video').toList();
      final audioStreams =
          streams.where((s) => s.getType() == 'audio').toList();
      final video = videoStreams.isEmpty ? null : videoStreams.first;
      final audio = audioStreams.isEmpty ? null : audioStreams.first;

      final seconds = double.tryParse(info.getDuration() ?? '') ?? 0;
      final codec = video?.getCodec() ?? '';
      final pixFmt = video?.getStringProperty('pix_fmt') ?? '';
      final frames =
          int.tryParse(video?.getStringProperty('nb_frames') ?? '') ?? 0;

      final kind = _classify(
        hasVideo: video != null,
        hasAudio: audio != null,
        videoCodec: codec,
        durationSeconds: seconds,
        frames: frames,
      );

      return ConvertSource(
        path: path,
        kind: kind,
        bytes: file.lengthSync(),
        width: int.tryParse(video?.getWidth()?.toString() ?? '') ?? 0,
        height: int.tryParse(video?.getHeight()?.toString() ?? '') ?? 0,
        duration: Duration(milliseconds: (seconds * 1000).round()),
        hasAudio: audio != null,
        audioCodec: audio?.getCodec() ?? '',
        videoCodec: codec,
        hasAlpha: _hasAlpha(pixFmt),
        frames: frames,
      );
    } catch (_) {
      return null;
    }
  }

  /// Image vs animated vs video vs audio.
  ///
  /// The extension is not consulted: a `.gif` that is really a JPEG has to be
  /// treated as the JPEG it is, and an animated WebP has to count as animated
  /// even though its codec name says webp.
  static MediaKind _classify({
    required bool hasVideo,
    required bool hasAudio,
    required String videoCodec,
    required double durationSeconds,
    required int frames,
  }) {
    if (!hasVideo && hasAudio) return MediaKind.audio;
    if (!hasVideo && !hasAudio) return MediaKind.image;
    if (videoCodec == 'gif' || videoCodec == 'apng') return MediaKind.animated;
    if (videoCodec == 'webp' && frames > 1) return MediaKind.animated;
    // A still image decodes as a single-frame video stream: ffprobe either has
    // no duration for it or a fraction of a second.
    if (durationSeconds <= 0.1) return MediaKind.image;
    return MediaKind.video;
  }

  static bool _hasAlpha(String pixFmt) {
    final f = pixFmt.toLowerCase();
    return f.contains('a') && f != 'gray' && f != 'pal8';
  }

  /// Run one [request].
  ///
  /// [ConvertRequest.width] applies to image and video output (aspect
  /// preserved); `fps` and `hardware` only to video; `backgroundArgb` is the
  /// flatten colour for targets without an alpha channel.
  Future<String> convert(
    ConvertRequest request, {
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    final source = request.source;
    final format = request.format;
    final quality = request.quality;
    final width = request.width;
    final fps = request.fps;
    final dropAudio = request.dropAudio;
    final hardware = request.hardware;
    final backgroundArgb = request.backgroundArgb;
    await Directory(workDir).create(recursive: true);
    final output = '$workDir/converted_${DateTime.now().millisecondsSinceEpoch}'
        '.${format.extension}';

    final args = switch (format.kind) {
      MediaKind.audio => commands.convertAudio(
          inputPath: source.path,
          outputPath: output,
          format: format,
          quality: quality,
          copy: source.kind == MediaKind.audio &&
              canStreamCopyAudio(format.id, source.audioCodec),
        ),
      MediaKind.video => commands.convertVideo(
          inputPath: source.path,
          outputPath: output,
          format: format,
          quality: quality,
          width: width,
          fps: fps,
          dropAudio: dropAudio || !source.hasAudio,
          hardware: hardware,
        ),
      MediaKind.image || MediaKind.animated => commands.convertImage(
          inputPath: source.path,
          outputPath: output,
          format: format,
          quality: quality,
          width: width,
          height: null,
          // Flatten only when the target cannot carry alpha AND the source has
          // it: an opaque JPEG to JPEG has no transparency to lose.
          backgroundArgb: (!format.supportsAlpha && source.hasAlpha)
              ? backgroundArgb
              : null,
          dropAnimation: format.kind == MediaKind.image &&
              source.kind == MediaKind.animated,
        ),
    };

    try {
      final job = await runWithProgress(
        args,
        totalMs: totalMs,
        onProgress: onProgress,
      );
      onJob?.call(job);
      await job.wait();
    } on FfmpegCancelled {
      rethrow;
    } on FfmpegException catch (e) {
      throw ConvertException('转换失败: ${_summarize(e.output)}');
    }
    final file = File(output);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw ConvertException('转换结束但没有产出文件');
    }
    return output;
  }

  static String _summarize(String log) {
    final lines = log
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where((l) =>
            l.toLowerCase().contains('error') ||
            l.toLowerCase().contains('invalid') ||
            l.toLowerCase().contains('unsupported'))
        .toList();
    if (lines.isNotEmpty) return lines.take(3).join(' | ');
    final all = log.trim().split('\n');
    return all.isEmpty ? '(no output)' : all.last;
  }
}
