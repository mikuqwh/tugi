/// Tugi - Edit Image service.
///
/// Every applied edit is a single ffmpeg pass that re-runs the WHOLE current
/// edit state against the ORIGINAL file (no generation loss from chaining
/// JPEG re-encodes), producing a new output plus a 1080-wide display copy
/// for the editor. See commands.editImageTransform for the measured filter
/// behavior and the golden-set md5 replication.
// SPDX-License-Identifier: GPL-3.0-or-later

library edit_image_service;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import '../utils/image_reader.dart' as ir;
import 'video_to_gif_service.dart' show summarizeFfmpegOutput;

class EditImageException implements Exception {
  EditImageException(this.message, [this.details]);
  final String message;
  final String? details;
  @override
  String toString() =>
      'EditImageException: $message${details != null ? '\n$details' : ''}';
}

/// A full-size apply result plus the 1080-wide copy the editor displays.
class TransformResult {
  const TransformResult({required this.outputPath, required this.previewPath});

  /// The file the user saves / shares.
  final String outputPath;

  /// The file the editor renders. Never the same as [outputPath].
  final String previewPath;
}

class EditImageService {
  EditImageService({required this.workDir});

  final String workDir;

  /// What one apply produced: the full-size result and its display copy.
  ///
  /// Both come out of a SINGLE ffmpeg pass (see
  /// [ffmpeg.editImageTransformWithPreview]), so callers must not also call
  /// [makePreview] on [outputPath] -- that would decode the source again and
  /// give back the time this path exists to save.
  Future<TransformResult> transformWithPreview({
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
    required String inputPath,
    required ffmpeg.EditImageGeometry geometry,
    required ffmpeg.EditImageAdjust adjust,
    String preset = 'none',
    int presetStrength = 100,
    required String format,
    int jpegQuality = 2,
  }) async {
    final source = File(inputPath);
    if (!source.existsSync()) {
      throw EditImageException('找不到图片文件: $inputPath');
    }
    await Directory(workDir).create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final ext =
        switch (format) { 'png' => 'png', 'webp' => 'webp', _ => 'jpg' };
    final out = '$workDir/editimg_$stamp.$ext';
    final preview = '$workDir/editimg_preview_$stamp.jpg';

    final args = ffmpeg.editImageTransformWithPreview(
      inputPath: inputPath,
      outputPath: out,
      previewPath: preview,
      geometry: geometry,
      adjust: adjust,
      preset: preset,
      presetStrength: presetStrength,
      format: format,
      jpegQuality: jpegQuality,
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
      throw EditImageException('处理失败: ${summarizeFfmpegOutput(e.output)}');
    }
    final outFile = File(out);
    if (!outFile.existsSync() || outFile.lengthSync() == 0) {
      throw EditImageException('处理结束但没有产出文件');
    }
    // The preview output is a second -map; ffmpeg can fail to write it without
    // failing the run. Fall back to the standalone builder so a missing display
    // copy degrades to "slower" rather than "the editor has nothing to show".
    final previewFile = File(preview);
    if (!previewFile.existsSync() || previewFile.lengthSync() == 0) {
      return TransformResult(
        outputPath: out,
        previewPath: await makePreview(out),
      );
    }
    return TransformResult(outputPath: out, previewPath: preview);
  }

  /// Run the full edit state against [inputPath], return the output path.
  Future<String> transform({
    required String inputPath,
    required ffmpeg.EditImageGeometry geometry,
    required ffmpeg.EditImageAdjust adjust,
    String preset = 'none',
    int presetStrength = 100,
    required String format,
    int jpegQuality = 2,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    final source = File(inputPath);
    if (!source.existsSync()) {
      throw EditImageException('找不到图片文件: $inputPath');
    }
    await Directory(workDir).create(recursive: true);
    final ext =
        switch (format) { 'png' => 'png', 'webp' => 'webp', _ => 'jpg' };
    final out =
        '$workDir/editimg_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final args = ffmpeg.editImageTransform(
      inputPath: inputPath,
      outputPath: out,
      geometry: geometry,
      adjust: adjust,
      preset: preset,
      presetStrength: presetStrength,
      format: format,
      jpegQuality: jpegQuality,
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
      throw EditImageException('处理失败: ${summarizeFfmpegOutput(e.output)}');
    }
    final file = File(out);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw EditImageException('处理结束但没有产出文件');
    }
    return out;
  }

  /// 1080-wide display copy: the editor only ever shows this file (decoded
  /// with cacheWidth), while all real work happens on the previous implementation.
  Future<String> makePreview(String inputPath) async {
    await Directory(workDir).create(recursive: true);
    final out =
        '$workDir/editimg_preview_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final session = await FFmpegKit.executeWithArguments(
        ffmpeg.editImagePreview(inputPath: inputPath, outputPath: out));
    final returnCode = await session.getReturnCode();
    if (returnCode?.isValueSuccess() != true) {
      throw EditImageException(
        '生成预览失败 (code ${returnCode?.getValue()}): '
        '${summarizeFfmpegOutput(await session.getOutput())}',
      );
    }
    return out;
  }

  /// Compress [inputPath] down to [plan]'s target byte count.
  ///
  /// ffmpeg's mjpeg encoder has no target-size mode, so the size is reached by
  /// searching. See [ffmpeg.compressionSearchPhases] for the phase order and
  /// why the worst-quality probe comes first at each width.
  ///
  /// Every attempt re-runs the FULL filter chain against [inputPath] — never
  /// against the previous attempt's output — so repeated JPEG re-encodes
  /// cannot stack up generation loss.
  ///
  /// [maxIterations] is a safety valve, not a tuning knob: the default covers
  /// the measured worst case ([ffmpeg.compressionWorstCaseEncodes]) with
  /// headroom, so hitting it means something is genuinely unreachable rather
  /// than the search being cut short.
  Future<ffmpeg.ImageCompressionResult> compress({
    required String inputPath,
    required ffmpeg.ImageCompressionPlan plan,
    required ffmpeg.EditImageGeometry geometry,
    ffmpeg.EditImageAdjust adjust = const ffmpeg.EditImageAdjust(),
    String preset = 'none',
    int presetStrength = 100,
    String format = 'jpg',
    int? maxIterations,
    void Function(int iteration, int maxIterations, int bytes)? onProgress,
  }) async {
    final source = File(inputPath);
    if (!source.existsSync()) {
      throw EditImageException('找不到图片文件: $inputPath');
    }
    if (format == 'png') {
      throw EditImageException('PNG 不支持按体积压缩，请改用 JPG 输出');
    }
    await Directory(workDir).create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;

    // The width ladder needs a starting point even when the caller has no cap
    // of its own ("输出宽度: 原始"). Read the source's real width so an
    // aggressive target can still narrow the image; without it the ladder came
    // out empty and "允许缩小尺寸" silently did nothing.
    int? sourceWidth;
    try {
      final info = ir.ImageReader.parse(await source.readAsBytes());
      sourceWidth = info.width;
    } catch (_) {
      // Unreadable header: fall back to "no ladder" rather than failing the
      // whole compression. The quality walk still runs.
      sourceWidth = null;
    }

    final phases = ffmpeg.compressionSearchPhases(
      startQuality: plan.quality,
      startWidth: geometry.scaleWidth,
      allowScale: ffmpeg.compressionAllowsScaling(plan.mode),
      sourceWidth: sourceWidth,
    );
    // Default budget: the plan's own worst case plus headroom. Callers may
    // lower it to trade completeness for speed, but not silently.
    final budget = maxIterations ??
        (ffmpeg.compressionWorstCaseEncodes(phases) * 2).clamp(20, 200);

    var attempt = 0;
    ffmpeg.ImageCompressionResult? last;

    /// Encode one candidate and measure it. Returns null once the budget is
    /// spent, which every caller treats as "stop searching".
    Future<ffmpeg.ImageCompressionResult?> encodeAt(int? width, int q) async {
      if (attempt >= budget) return null;
      final out = '$workDir/editimg_c${stamp}_$attempt.jpg';
      final file = File(out);
      if (file.existsSync()) file.deleteSync();
      final args = ffmpeg.editImageTransform(
        inputPath: inputPath,
        outputPath: out,
        geometry: ffmpeg.EditImageGeometry(
          quarterTurns: geometry.quarterTurns,
          flipH: geometry.flipH,
          flipV: geometry.flipV,
          scaleWidth: width,
          crop: geometry.crop,
        ),
        adjust: adjust,
        preset: preset,
        presetStrength: presetStrength,
        format: format,
        jpegQuality: q,
      );
      final session = await FFmpegKit.executeWithArguments(args);
      final returnCode = await session.getReturnCode();
      if (returnCode?.isValueSuccess() != true) {
        if (file.existsSync()) file.deleteSync();
        throw EditImageException(
          '压缩失败 (code ${returnCode?.getValue()}): '
          '${summarizeFfmpegOutput(await session.getOutput())}',
        );
      }
      final bytes = file.lengthSync();
      attempt++;
      final previous = last;
      if (previous != null) {
        final stale = File(previous.path);
        if (stale.existsSync()) stale.deleteSync();
      }
      last = ffmpeg.ImageCompressionResult(
        path: out,
        bytes: bytes,
        quality: q,
        width: width,
      );
      onProgress?.call(attempt, budget, bytes);
      return last;
    }

    // Width is searched by bisection, not by walking every rung: output size is
    // monotonic in width for a fixed quality, so the widest rung that fits can
    // be found in ~log2(N) probes.
    //
    // Phase 0 is special: it keeps the caller's own width (null = full size),
    // so a target the source already meets never enters the width search.
    final head = phases.isEmpty ? null : phases.first;
    final rungs = ffmpeg.compressionWidthRungs(phases);

    if (head != null) {
      final probe = await encodeAt(head.width, head.probeQuality);
      if (probe == null) return _finish(last);
      if (probe.bytes <= plan.targetBytes) {
        // The source width already fits at the worst rung, so a better rung
        // exists. Walk quality upward from the best and take the first fit.
        for (final q in head.walkQuality) {
          final r = await encodeAt(head.width, q);
          if (r == null) return _finish(last);
          if (r.bytes <= plan.targetBytes) return r;
        }
        return probe;
      }
    }

    if (rungs.isEmpty) return _finish(last);

    // Rungs are widest-first, so a fitting rung sits at a HIGHER index than an
    // overshooting one. `compressionWidestFittingRung` owns that invariant and
    // is unit-tested; here we only supply the measurement.
    final worst = ffmpeg.imageCompressionQualityLadder.last;
    final idx = await ffmpeg.compressionWidestFittingRung(
      rungs: rungs,
      fitsAt: (i) async {
        final r = await encodeAt(rungs[i], worst);
        return r == null ? null : r.bytes <= plan.targetBytes;
      },
    );
    if (idx == null) return _finish(last);
    final best = await encodeAt(rungs[idx], worst);
    if (best == null) return _finish(last);

    // Refine quality at that width: `best` is the WORST rung, so a finer
    // quality may also fit. Bisect for it, for the same monotonicity reason.
    final order = ffmpeg.imageCompressionSearchOrder(plan.quality);
    var loQ = order.length - 1; // worst rung: measured fitting
    var hiQ = -1; // nothing known to overshoot yet
    ffmpeg.ImageCompressionResult? bestQ;
    while (loQ - hiQ > 1) {
      final mid = (loQ + hiQ) ~/ 2;
      final r = await encodeAt(rungs[idx], order[mid]);
      if (r == null) break; // budget spent
      if (r.bytes <= plan.targetBytes) {
        loQ = mid;
        bestQ = r;
      } else {
        hiQ = mid;
      }
    }
    return bestQ ?? best;
  }

  /// Keep the last measured candidate, or fail if nothing was ever produced.
  ffmpeg.ImageCompressionResult _finish(ffmpeg.ImageCompressionResult? last) {
    final kept = last;
    if (kept == null) {
      throw EditImageException('压缩失败：没有产出任何文件');
    }
    return kept;
  }
}
