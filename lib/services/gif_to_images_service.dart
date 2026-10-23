/// Tugi - GIF to Images service (frame extraction).
///
///   confirmation     `Confirm to save all frames?` / `Confirm to save all images?`
///   cancellable      `cancel_extracting_frames`
///
/// Frames land in a fresh timestamped subdirectory so two extractions never
/// collide, and each frame keeps its sequential index in the filename so the
/// on-disk order matches the GIF timeline.
// SPDX-License-Identifier: GPL-3.0-or-later

library gif_to_images_service;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';

import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;

class GifToImagesService {
  final String workDir;

  GifToImagesService({required this.workDir});

  /// Directory holding the frames produced by the most recent call, so the
  /// screen can clean up exactly what it created.
  String? _lastFramesDir;

  String? get lastFramesDir => _lastFramesDir;

  /// Extract frames from [gifPath].
  ///
  /// [framestep] keeps 1 frame out of every N (1 = every frame).
  /// [outputWidth] optionally scales the frames; height follows the aspect ratio.
  ///
  /// Throws [GifToImagesException] when ffmpeg reports a non-zero exit code.
  Future<List<String>> extractFrames(
    String gifPath, {
    int framestep = 1,
    int? outputWidth,
    FormatSpec? format,
    int quality = 90,
    void Function(int frame, int total)? onProgress,
    void Function(double progress)? onFfmpegProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    final spec = format ?? formatById('png')!;
    final extension = spec.extension == 'jpg' ? 'jpg' : spec.extension;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final framesDir = '$workDir/gif_frames_$stamp';
    await Directory(framesDir).create(recursive: true);
    _lastFramesDir = framesDir;

    final args = ffmpeg.gifToImages(
      inputPath: gifPath,
      outputPattern: '$framesDir/frame_%06d.$extension',
      framestep: framestep,
      outputWidth: outputWidth,
      encoderArgs: spec.encoderArgs,
      qualityArgs: spec.quality == QualityPolicy.none
          ? const []
          : qualityArgs(spec.quality, quality),
    );
    String? failure;
    try {
      final job = await runWithProgress(
        args,
        totalMs: totalMs,
        onProgress: onFfmpegProgress,
      );
      onJob?.call(job);
      await job.wait();
    } on FfmpegCancelled {
      _safeDelete(framesDir);
      rethrow;
    } on FfmpegException catch (e) {
      failure = e.output;
    }
    final output = failure ?? '';

    if (failure != null) {
      // Do not leave an empty directory behind on failure.
      _safeDelete(framesDir);
      throw GifToImagesException(
        'ffmpeg failed',
        output,
      );
    }

    final files = Directory(framesDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.$extension'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      _safeDelete(framesDir);
      throw GifToImagesException(
        'no frames were produced',
        'framestep=$framestep outputWidth=$outputWidth\n$output',
      );
    }

    final paths = files.map((f) => f.path).toList();
    onProgress?.call(paths.length, paths.length);
    return paths;
  }

  /// Best-effort recursive delete of a directory this service created.
  void cleanup([String? framesDir]) {
    _safeDelete(framesDir ?? _lastFramesDir ?? '');
  }

  static void _safeDelete(String path) {
    if (path.isEmpty) return;
    try {
      final dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Temp files are the OS's problem if we cannot remove them.
    }
  }
}

class GifToImagesException implements Exception {
  final String message;
  final String? details;
  GifToImagesException(this.message, [this.details]);

  @override
  String toString() =>
      'GifToImagesException: $message${details != null ? '\n$details' : ''}';
}
