// SPDX-License-Identifier: GPL-3.0-or-later

library compress_gif_service;

/// Tugi Compress GIFs service (Reduce Resolution mode).
///
/// EMPIRICALLY VERIFIED against this app on 2026-10-15:
/// the host-ffmpeg reproduction of this pipeline is BYTE-IDENTICAL (md5)
/// to this app's output for the same input and ratio.
/// See commands.dart compressGif() for the measured facts.

import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';
import '../ffmpeg/commands.dart' as ffmpeg;

class CompressGifService {
  final String workDir;

  CompressGifService({required this.workDir});

  /// Compress a GIF by scaling its resolution.
  ///
  /// [ratio] is the linear scale factor applied to width (height follows the
  /// aspect ratio). The previous implementation app exposes presets 0.8 / 0.5 / 0.2 plus a
  /// custom value.
  ///
  /// Returns the output path. Frame count, per-frame delays, loop flag and
  /// palette size (256) are all preserved by the underlying pipeline.
  Future<String> compress({
    required String inputPath,
    required double ratio,
    bool loop = true,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    final src = File(inputPath);
    if (!src.existsSync()) {
      throw Exception('GIF 不存在: $inputPath');
    }
    if (ratio <= 0 || ratio > 1) {
      throw Exception('压缩比例必须在 0 和 1 之间');
    }

    await Directory(workDir).create(recursive: true);
    final outputPath =
        '$workDir/compressed_${DateTime.now().millisecondsSinceEpoch}.gif';

    final args = ffmpeg.compressGif(
      inputPath: inputPath,
      outputPath: outputPath,
      ratio: ratio,
      loop: loop,
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
      throw Exception('压缩失败: ${e.output}');
    }
    if (!File(outputPath).existsSync()) {
      throw Exception('压缩失败: 输出文件未生成');
    }
    return outputPath;
  }

  /// Compress a GIF by keeping one frame in every [frameStep].
  ///
  /// The previous implementation app's "Extract Frames" mode. The output keeps the source's
  /// duration (frames are re-timed, not dropped from the end) and its
  /// resolution; only the frame rate falls by [frameStep].
  ///
  /// [sourceFps] is the source's average rate. It is a parameter rather than
  /// something read here so the caller -- which already parsed the GIF for the
  /// UI -- stays the single place that knows it.
  Future<String> compressByFrameStep({
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
    required String inputPath,
    required int frameStep,
    required double sourceFps,
    bool loop = true,
  }) async {
    if (!File(inputPath).existsSync()) {
      throw Exception('GIF 不存在: $inputPath');
    }
    if (frameStep < 2) {
      throw Exception('抽帧间隔至少为 2');
    }

    await Directory(workDir).create(recursive: true);
    final outputPath =
        '$workDir/compressed_${DateTime.now().millisecondsSinceEpoch}.gif';

    final args = ffmpeg.compressGifByFrames(
      inputPath: inputPath,
      outputPath: outputPath,
      sourceFps: sourceFps,
      frameStep: frameStep,
      loop: loop,
    );

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();
    if (returnCode == null || !returnCode.isValueSuccess()) {
      throw Exception('抽帧失败: ${await session.getOutput()}');
    }
    if (!File(outputPath).existsSync()) {
      throw Exception('抽帧失败: 输出文件未生成');
    }
    return outputPath;
  }
}
