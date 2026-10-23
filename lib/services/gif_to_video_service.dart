/// Tugi GIF to Video service.
///
/// Single ffmpeg pass: GIF -> H.264 mp4. No intermediate frames.
///
///
/// See commands.dart gifToVideo() for the resolution model (the previous implementation lets
/// you keep the source width or pick one; there is no hidden 50% scale).

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';

import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import 'video_to_gif_service.dart' show summarizeFfmpegOutput;

class GifToVideoException implements Exception {
  GifToVideoException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GifToVideoService {
  GifToVideoService({
    required this.workDir,
    String? outputDir,
    FormatSpec? format,
  })  : _format = format ?? formatById('mp4_h264')!,
        _outputPath = outputDir ??
            '$workDir/video_${DateTime.now().millisecondsSinceEpoch}'
                '.${(format ?? formatById('mp4_h264')!).extension}';

  final String workDir;

  /// The container/codec to write. Defaults to the historical H.264 MP4.
  final FormatSpec _format;

  FormatSpec get format => _format;

  final String _outputPath;

  String get outputPath => _outputPath;

  /// Convert [gifPath] to an H.264 mp4.
  ///
  /// [fps] re-times the GIF onto a constant frame rate, which changes the frame
  /// count as well as the timing: a 77-frame / 5.14 s GIF yields 62 frames at
  /// 12 fps and 77 at 15 fps.
  ///
  /// [outputWidth] == null keeps the source resolution.
  Future<String> convert({
    required String gifPath,
    int fps = 12,
    int? outputWidth,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    final file = File(gifPath);
    if (!file.existsSync()) {
      throw GifToVideoException('找不到 GIF 文件: $gifPath');
    }

    final args = ffmpeg.gifToVideo(
      inputPath: gifPath,
      outputPath: _outputPath,
      fps: fps,
      outputWidth: outputWidth,
      format: _format,
    );
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
      throw GifToVideoException('视频转换失败: ${e.message}');
    }

    final out = File(_outputPath);
    if (!out.existsSync() || out.lengthSync() == 0) {
      throw GifToVideoException('转换结束但没有产出文件');
    }
    return _outputPath;
  }
}
