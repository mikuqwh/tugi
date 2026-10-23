// SPDX-License-Identifier: GPL-3.0-or-later

library images_to_gif_service;

/// Tugi Images to GIF service.
/// Reuses 90% of VideoToGifService pipeline; only the frame source differs:
/// video decode -> single image duplicated N times (emptyGIFFramesLenth=10).
/// ASSUMPTION: spec-level (n_frames=10, duration=1000ms, loop=0, size=derived).

import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';
import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import '../models/creation.dart';
import '../utils/params.dart';

class ImagesToGifService {
  final String workDir;

  /// GIF by default; APNG skips the palette pass.
  final FormatSpec? format;
  final String _framesSubdir;
  late final String _concatList;
  final String _outputPath;

  ImagesToGifService({
    required this.workDir,
    String? outputDir,
    this.format,
  })  : _framesSubdir =
            '$workDir/frames_${DateTime.now().millisecondsSinceEpoch}',
        // Distinct per-run name: the Video-to-GIF pipeline writes into the same
        // workDir and used to clobber this file.
        _outputPath = outputDir ??
            '$workDir/images_${DateTime.now().millisecondsSinceEpoch}'
                '.${format?.extension ?? 'gif'}' {
    _concatList = '$_framesSubdir/concat_list.txt';
    Directory(_framesSubdir).createSync(recursive: true);
  }

  /// Remove this run's intermediate frames.
  void cleanup() {
    final dir = Directory(_framesSubdir);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // Best-effort: leftover frames only waste disk, never break the result.
      }
    }
  }

  /// Duplicate a single image N times to create N identical frames.
  /// N = emptyGIFFramesLenth (default 10).
  Future<int> expandFrames(String imagePath, {int frameCount = 10}) async {
    final src = File(imagePath);
    if (!src.existsSync()) {
      throw Exception('Image not found: $imagePath');
    }

    for (var i = 0; i < frameCount; i++) {
      final dst = File('$_framesSubdir/image_${i + 1}.png');
      await src.copy(dst.path);
    }
    return frameCount;
  }

  /// Build concat list for the expanded frames.
  Future<void> buildConcatList(int frameCount) async {
    final buf = StringBuffer();
    for (var i = 0; i < frameCount; i++) {
      buf.writeln("file '$_framesSubdir/image_${i + 1}.png'");
      // creation.fps=1.0 -> 1 frame per second -> duration=1000ms
      buf.writeln('duration 1.0');
    }
    await File(_concatList).writeAsString(buf.toString());
  }

  /// Encode GIF: concat → palettegen/paletteuse → gif.
  ///
  /// Timing: the concat list carries `duration <secondsPerFrame>` per frame,
  /// and the output needs a matching `-r 1/secondsPerFrame`. The duration
  /// directives alone are NOT enough — the gif muxer takes the delay from the
  /// output stream's frame rate, which for concat input defaults to 25fps, so
  /// every frame came out as 40ms no matter what the user picked (measured on
  /// device: UI said "1.0 秒/帧", file said 40ms). `-r` as an OUTPUT option is
  /// what actually reaches the muxer; adding it as an input option or using
  /// `fps=`/`-fps_mode passthrough` does not work (passthrough errors out with
  /// "Invalid argument" on the gif muxer).
  ///
  /// [frameRate] must be 1/[secondsPerFrame]. It has to agree with the concat
  /// durations or CFR resampling duplicates/drops frames (duration 1.0 with
  /// `-r 2` yields 7 frames instead of 4).
  ///
  /// [outputWidth] scales every frame down when set (null keeps source size).
  /// Applied BEFORE the palette split so the palette matches the scaled frames.
  Future<String> encodeGif({
    bool loop = true,
    double? outputWidth,
    double frameRate = 1.0,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
  }) async {
    final scale = (outputWidth != null && outputWidth > 0)
        ? 'scale=${outputWidth.toInt()}:-2,'
        : '';
    if (format?.id == 'apng') {
      final args = ffmpeg.apngFromFrames(
        concatListPath: _concatList,
        outputPath: _outputPath,
        loop: loop,
        prefixFilter: scale.isEmpty ? '' : scale.substring(0, scale.length - 1),
      );
      try {
        final job = await runWithProgress(args, onProgress: onProgress);
        onJob?.call(job);
        await job.wait();
      } on FfmpegCancelled {
        rethrow;
      } on FfmpegException catch (e) {
        throw Exception('APNG encoding failed: ${e.output}');
      }
      return _outputPath;
    }
    const filter = 'split[s1][s2];'
        '[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1';

    final args = <String>[
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      _concatList,
      '-filter_complex',
      '$scale$filter',
      ...gifFlags,
      if (loop) '-loop',
      '0',
      '-r',
      frameRate.toString(),
      '-f',
      'gif',
      _outputPath,
    ];

    try {
      final job = await runWithProgress(args, onProgress: onProgress);
      onJob?.call(job);
      await job.wait();
    } on FfmpegCancelled {
      rethrow;
    } on FfmpegException catch (e) {
      throw Exception('GIF encoding failed: ${e.output}');
    }
    return _outputPath;
  }

  /// Full pipeline: single image -> GIF.
  /// [frameCount] defaults to 10 (emptyGIFFramesLenth).
  /// Each frame gets 1000ms (duration 1.0 -> frameRate 1.0).
  Future<String> convertImagesToGif(
    String imagePath, {
    int frameCount = 10,
    bool loop = true,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
  }) async {
    final actualCount = await expandFrames(imagePath, frameCount: frameCount);
    await buildConcatList(actualCount);
    return encodeGif(
      loop: loop,
      frameRate: 1.0,
      onProgress: onProgress,
      onJob: onJob,
    );
  }

  /// Full pipeline: N distinct images -> N-frame GIF (one frame per image).
  /// This is the real Images-to-GIF feature path (the single-image variant
  /// above is the old test-scaffold entry point).
  ///
  /// [secondsPerFrame] goes into the concat list `duration` entries AND into
  /// the output frame rate (1/secondsPerFrame) — both must agree, see
  /// [encodeGif].
  /// [outputWidth] scales frames down when set (null keeps source size).
  Future<String> convertImagesToGifMulti(
    List<String> imagePaths, {
    double secondsPerFrame = 1.0,
    bool loop = true,
    double? outputWidth,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
  }) async {
    if (imagePaths.isEmpty) {
      throw Exception('没有选择图片');
    }
    if (secondsPerFrame <= 0) {
      throw Exception('每张时长必须大于 0');
    }

    final frameNames = <String>[];
    for (var i = 0; i < imagePaths.length; i++) {
      final src = File(imagePaths[i]);
      if (!src.existsSync()) {
        throw Exception('图片不存在: ${imagePaths[i]}');
      }
      // Keep the source extension: gallery photos are usually JPEG, and the
      // concat demuxer probes each file by content. The old single-image path
      // renamed everything to .png — that was a no-op for its PNG test asset
      // but is a needless risk for real gallery input.
      final dot = imagePaths[i].lastIndexOf('.');
      final ext = dot > imagePaths[i].lastIndexOf(Platform.pathSeparator)
          ? imagePaths[i].substring(dot)
          : '.png';
      final name = 'image_${(i + 1).toString().padLeft(6, '0')}$ext';
      await src.copy('$_framesSubdir/$name');
      frameNames.add(name);
    }

    final buf = StringBuffer();
    for (final name in frameNames) {
      buf.writeln("file '$_framesSubdir/$name'");
      buf.writeln('duration $secondsPerFrame');
    }
    await File(_concatList).writeAsString(buf.toString());

    return encodeGif(
      loop: loop,
      outputWidth: outputWidth,
      frameRate: 1.0 / secondsPerFrame,
      onProgress: onProgress,
      onJob: onJob,
    );
  }

  /// Build a Creation object for this Images to GIF result.
  Creation buildCreation({
    required String imagePath,
    required double imageWidth,
    required double imageHeight,
    int frameCount = 10,
  }) =>
      Creation.imagesToGif(
        imagePath: imagePath,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        frameCount: frameCount,
      );
}
