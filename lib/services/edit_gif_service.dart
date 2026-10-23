// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - Edit GIF service (play speed + reverse).
///
/// Both operations are single ffmpeg passes against the source GIF:
///   - reverse: the `reverse` filter, which keeps each frame's own duration
///     (an extract-to-PNG + reversed-concat pipeline was measured first, but
///     the concat demuxer quantized per-frame delays to its 1/25 s ticks).
/// A speed multiplier other than 1.0 composes after the reversal.
/// See commands.editGifSpeed / commands.editGifReverse for the measured
/// behavior and the rejected alternatives.
// SPDX-License-Identifier: GPL-3.0-or-later

library edit_gif_service;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import '../models/encode_preset.dart';
import 'ffmpeg_progress.dart';
import 'video_to_gif_service.dart' show summarizeFfmpegOutput;

class EditGifException implements Exception {
  EditGifException(this.message, [this.details]);
  final String message;
  final String? details;
  @override
  String toString() =>
      'EditGifException: $message${details != null ? '\n$details' : ''}';
}

class EditGifService {
  EditGifService({required this.workDir});

  final String workDir;

  /// Apply play-speed and/or reverse to [gifPath], return the output path.
  ///
  /// [speedMultiplier] is the setpts multiplier: < 1 plays faster, > 1 plays
  /// slower (measured, see commands.editGifSpeed).
  Future<String> edit({
    required String gifPath,
    required double speedMultiplier,
    required bool reverse,
    bool loop = true,
    FormatSpec? format,
    double? start,
    double? end,
    String? crop,
    void Function(double progress)? onProgress,
    int? totalMs,
    void Function(FfmpegJob job)? onJob,
    EncodePreset preset = EncodePreset.balanced,
  }) async {
    final source = File(gifPath);
    if (!source.existsSync()) {
      throw EditGifException('找不到 GIF 文件: $gifPath');
    }

    final args = reverse
        ? ffmpeg.editGifReverse(
            inputPath: gifPath,
            outputPath: _outputPath(format),
            speedMultiplier: speedMultiplier,
            loop: loop,
            format: format,
            start: start,
            end: end,
            crop: crop,
            preset: preset,
          )
        : ffmpeg.editGifSpeed(
            inputPath: gifPath,
            outputPath: _outputPath(format),
            speedMultiplier: speedMultiplier,
            loop: loop,
            format: format,
            start: start,
            end: end,
            crop: crop,
            preset: preset,
          );
    return _run(
      args,
      onProgress: onProgress,
      totalMs: totalMs,
      onJob: onJob,
    );
  }

  String _outputPath(FormatSpec? format) =>
      '$workDir/edit_${DateTime.now().millisecondsSinceEpoch}'
      '.${format?.extension ?? 'gif'}';

  Future<String> _run(
    List<String> args, {
    void Function(double progress)? onProgress,
    int? totalMs,
    void Function(FfmpegJob job)? onJob,
    EncodePreset preset = EncodePreset.balanced,
  }) async {
    try {
      await runAndWait(args, totalMs: totalMs, onProgress: onProgress);
    } on FfmpegCancelled {
      rethrow;
    } on FfmpegException catch (e) {
      throw EditGifException('编辑失败: ${e.message}');
    }
    final out = File(args.last);
    if (!out.existsSync() || out.lengthSync() == 0) {
      throw EditGifException('转换结束但没有产出文件');
    }
    return args.last;
  }
}
