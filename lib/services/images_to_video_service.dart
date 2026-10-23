// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - Images to Video pipeline (roadmap 4.4).
///
/// Distinct images -> concat -> libx264 mp4, one video frame sequence.
///
/// Split like the other services: the argv comes from the pure builders in
/// `commands.dart` (unit-tested without an ffmpeg runtime), and this file only
/// owns file staging, the concat list, and execution.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';

import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import '../utils/params.dart' show h264Encode;
import '../utils/image_reader.dart' as ir;
import 'video_to_gif_service.dart' show summarizeFfmpegOutput;

class ImagesToVideoException implements Exception {
  ImagesToVideoException(this.message, [this.details]);
  final String message;
  final String? details;
  @override
  String toString() =>
      'ImagesToVideoException: $message${details != null ? '\n$details' : ''}';
}

/// What one Images-to-Video run produced.
class ImagesToVideoResult {
  const ImagesToVideoResult({
    required this.outputPath,
    required this.bytes,
    required this.width,
    required this.height,
    required this.imageCount,
    required this.secondsPerImage,
    required this.fps,
    required this.usedCanvas,
  });

  final String outputPath;
  final int bytes;
  final int width;
  final int height;
  final int imageCount;
  final double secondsPerImage;
  final int fps;

  /// False when the canvas could not be sized and the images went through at
  /// their own dimensions (only safe if the sources already agree).
  final bool usedCanvas;

  /// Expected duration, N x D. The concat `duration` directives control this --
  /// see [ffmpeg.imagesToVideo] for the measurement that established it.
  double get expectedSeconds => imageCount * secondsPerImage;
}

/// Smallest multiple worth of frames each image must occupy.
///
/// The rule and its measured justification live in `commands.dart`
/// ([ffmpeg.imagesToVideoMinFramesPerImage]) so `dart test` can reach them --
/// this file imports ffmpeg_kit, which pulls in Flutter.
///
/// Exposed here as a thin re-export for callers that already import the service.
const int imagesToVideoMinFramesPerImage =
    ffmpeg.imagesToVideoMinFramesPerImage;

class ImagesToVideoService {
  ImagesToVideoService({required this.workDir, this.format});

  final String workDir;

  /// Container/codec to write. Null keeps the historical H.264 MP4.
  ///
  /// The segments are encoded with this format's encoder and (for WebM) in its
  /// container, then joined with a stream copy -- so the choice has to be made
  /// BEFORE the first image is rendered, not at join time.
  final FormatSpec? format;

  String get _segmentExtension => format?.extension == 'webm' ? 'webm' : 'mp4';

  String? get _joinMuxer => switch (format?.extension) {
        'webm' => 'webm',
        'mkv' => 'matroska',
        _ => null,
      };

  late final String _stagingDir;
  late final String _concatList;

  void _initPaths() {
    _stagingDir = '$workDir/itv_frames';
    _concatList = '$workDir/itv_concat.txt';
  }

  /// Stage copies of [imagePaths] and write the concat list.
  ///
  /// Files are COPIED rather than referenced in place: the gallery URIs behind
  /// image_picker can be temp files that vanish, and the concat demuxer needs
  /// stable paths for the whole encode.
  ///
  /// Render every image onto the canvas and emit one fixed-rate SEGMENT per
  /// image, then write a concat list over those segments.
  ///
  /// **Why per-image segments instead of concatenating the images directly.**
  /// Two independent device failures ruled out the obvious approaches:
  ///
  ///  1. Concatenating images of differing dimensions loses everything after
  ///     the first resolution change -- the demuxer hands files to the decoder
  ///     as one continuous stream, and a `-vf scale/pad` chain runs AFTER it,
  ///     so the filter cannot repair the truncation. Measured on host ffmpeg
  ///     9.0.2, 3 images at 0.5 s: uniform sources gave 1.500000 s / 18 frames,
  ///     mixed sizes gave 0.500000 s / 6 frames.
  ///
  ///  2. Even after normalizing to a uniform canvas, relying on the concat
  ///     `duration` directive plus an `fps` filter to synthesise the missing
  ///     frames is not portable. On the device (ffmpeg-kit, ffmpeg n8.1.2) the
  ///     input reported `Duration: 00:00:04.00` and yet the encode ended at
  ///     `frame=36 time=00:00:02.75` -- three of four images' worth -- while
  ///     the same command on host ffmpeg 9.0.2 produced 48 frames / 4.00 s.
  ///     Neither `setsar=1`, `-t` (before or after `-vf`), nor `-fps_mode cfr`
  ///     changed it; the truncation is in how that build's `fps` resampler
  ///     fills the gaps between still images.
  ///
  /// Rendering each image to its own `-t <seconds> -r <fps>` segment removes
  /// the gap-filling entirely: every segment already contains exactly the
  /// frames it needs, and the concat is a stream copy. Verified 4.000000 s /
  /// 48 frames for 4 images at 1 s / 12 fps.
  ///
  /// [canvas] is therefore REQUIRED. There is no passthrough: concatenating the
  /// originals only works when they happen to share dimensions, and when they
  /// do not, the result is a plausible-looking video that has silently dropped
  /// every image after the first. See the note on the concat list below.
  Future<void> stage(
    List<String> imagePaths,
    double secondsPerImage, {
    required (int, int) canvas,
    required int fps,
    void Function(int done, int total)? onProgress,
  }) async {
    _initPaths();
    final dir = Directory(_stagingDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    await dir.create(recursive: true);

    final names = <String>[];
    for (var i = 0; i < imagePaths.length; i++) {
      onProgress?.call(i, imagePaths.length);
      final src = File(imagePaths[i]);
      if (!src.existsSync()) {
        throw ImagesToVideoException('图片不存在: ${imagePaths[i]}');
      }
      final stem = 'img_${(i + 1).toString().padLeft(6, '0')}';

      await _renderSegment(
        src: src.path,
        dst: '$_stagingDir/$stem.$_segmentExtension',
        canvas: canvas,
        seconds: secondsPerImage,
        fps: fps,
      );
      names.add('$stem.$_segmentExtension');
    }

    // Every entry is a pre-encoded segment with a real stream, so the join is a
    // stream copy and needs no `duration` directive.
    //
    // That directive is what makes the alternative -- concatenating the still
    // images directly -- fail even when it looks like it works. A concat list of
    // bare `file` lines yields an EMPTY output ("Output file is empty, nothing
    // was encoded", 261 bytes, no streams, duration=N/A) while ffmpeg still
    // exits 0; adding `duration` fixes the same-size case (3 images -> 3.000000
    // s / 36 frames) but NOT mixed sizes, which still collapse to 1.000000 s /
    // 12 frames because the demuxer ends the input at the first resolution
    // change. A silent wrong-length video is worse than an empty one, so this
    // path refuses to accept non-uniform input at all rather than half-support
    // it.
    final buf = StringBuffer();
    for (final name in names) {
      buf.writeln("file '$_stagingDir/$name'");
    }
    await File(_concatList).writeAsString(buf.toString());
  }

  /// Render one image to a fixed-rate video segment of [seconds] duration.
  ///
  /// Thin wrapper over [ffmpeg.imagesToVideoSegment] so the argv shape and the
  /// letterbox filter chain stay testable in `dart test`, which cannot load
  /// this file (it imports FFmpegKit).
  Future<void> _renderSegment({
    required String src,
    required String dst,
    required (int, int) canvas,
    required double seconds,
    required int fps,
  }) async {
    final args = ffmpeg.imagesToVideoSegment(
      inputPath: src,
      outputPath: dst,
      canvas: canvas,
      seconds: seconds,
      fps: fps,
      encoderArgs: format?.encoderArgs ?? h264Encode,
    );
    final session = await FFmpegKit.executeWithArguments(args);
    final rc = await session.getReturnCode();
    if (rc == null || !rc.isValueSuccess()) {
      throw ImagesToVideoException(
        '图片预处理失败: $src',
        summarizeFfmpegOutput(await session.getOutput()),
      );
    }
  }

  /// Size the letterbox canvas from the first image's aspect ratio.
  ///
  /// Returns null when the header cannot be read, which makes the builder emit
  /// the passthrough chain instead of failing the whole run -- the same
  /// degradation the compression path uses for an unreadable source.
  ///
  /// [targetWidth] is the user's chosen width; the height follows the first
  /// image's ratio. Both come back even, as yuv420p requires.
  Future<(int, int)?> canvasFor(
    String firstImagePath,
    int targetWidth,
  ) async {
    try {
      final info =
          ir.ImageReader.parse(await File(firstImagePath).readAsBytes());
      if (info.width <= 0 || info.height <= 0) return null;
      final ratio = info.height / info.width;
      final w = ffmpeg.imagesToVideoCanvas(targetWidth);
      final h = ffmpeg.imagesToVideoCanvas((targetWidth * ratio).round());
      if (w == null || h == null) return null;
      return (w, h);
    } catch (_) {
      return null;
    }
  }

  /// Full pipeline: [imagePaths] -> mp4 at [outputPath].
  ///
  /// [fps] is raised by [imagesToVideoSettleFps] when needed so no image is
  /// dropped; the settled value is what the result reports and what the builder
  /// is given.
  Future<ImagesToVideoResult> convertImagesToVideo({
    required List<String> imagePaths,
    required String outputPath,
    double secondsPerImage = 1.0,
    int fps = 12,
    int? canvasWidth,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
  }) async {
    if (imagePaths.isEmpty) {
      throw ImagesToVideoException('没有选择图片');
    }
    if (secondsPerImage <= 0) {
      throw ImagesToVideoException('每张时长必须大于 0');
    }
    await Directory(workDir).create(recursive: true);

    final settledFps = ffmpeg.imagesToVideoSettleFps(
      secondsPerImage: secondsPerImage,
      requestedFps: fps,
    );
    // The clamp should already guarantee this. Asserting it here means a future
    // change to either function breaks loudly instead of quietly shipping a
    // video that has dropped images -- which is exactly the failure mode that
    // is invisible afterwards, because ffmpeg still exits 0 and the length can
    // still look plausible.
    if (!ffmpeg.imagesToVideoTimingIsSafe(
      secondsPerImage: secondsPerImage,
      fps: settledFps,
    )) {
      throw ImagesToVideoException(
        '每张时长与帧率不匹配，会丢图',
        '每张 $secondsPerImage 秒、$settledFps fps 时，'
            '有图片可能整张不出现在视频里。请加长每张时长或提高帧率。',
      );
    }

    // Resolve the canvas BEFORE staging: staging renders each image to a
    // canvas-sized segment, which is what allows mixed dimensions at all.
    final canvas = canvasWidth != null
        ? await canvasFor(imagePaths.first, canvasWidth)
        : await canvasFor(imagePaths.first, ffmpeg.imagesToVideoDefaultWidth);
    if (canvas == null) {
      throw ImagesToVideoException(
        '无法读取第一张图片的尺寸，无法建立统一画布',
        '混合尺寸的图片必须先归一化到同一画布再拼接，否则会丢图。',
      );
    }
    // Staging is the slow part (one encode per image), so it owns 0..0.9 of
    // the bar; the concat join takes the rest.
    await stage(
      imagePaths,
      secondsPerImage,
      canvas: canvas,
      fps: settledFps,
      onProgress: onProgress == null
          ? null
          : (done, total) {
              onProgress(0.9 * done / (total <= 0 ? 1 : total));
            },
    );

    final (cw, ch) = canvas;

    // The concat list holds pre-encoded segments, so the join is a stream copy;
    // the builder must not re-encode or resample them.
    final args = ffmpeg.imagesToVideoSegments(
      concatListPath: _concatList,
      outputPath: outputPath,
      muxer: _joinMuxer,
    );
    try {
      final job = await runWithProgress(
        args,
        onProgress:
            onProgress == null ? null : (v) => onProgress(0.9 + 0.1 * v),
      );
      onJob?.call(job);
      await job.wait();
    } on FfmpegCancelled {
      rethrow;
    } on FfmpegException catch (e) {
      throw ImagesToVideoException('视频生成失败', summarizeFfmpegOutput(e.output));
    }

    // A non-empty file is NOT proof of success. ffmpeg exits 0 and leaves a
    // 261-byte mp4 with no streams and duration=N/A when the concat input
    // contributes nothing ("Output file is empty, nothing was encoded"), and a
    // length check passes that happily. Only the container header in the output
    // distinguishes a real video from that stub, so require it.
    final out = File(outputPath);
    if (!out.existsSync() || out.lengthSync() == 0) {
      throw ImagesToVideoException('处理结束但没有产出文件');
    }
    if (!_looksLikeVideo(out, _outputExtension)) {
      throw ImagesToVideoException(
        '产出文件不是有效的视频',
        '文件 ${out.lengthSync()} 字节，但缺少视频容器头。',
      );
    }

    return ImagesToVideoResult(
      outputPath: outputPath,
      bytes: out.lengthSync(),
      width: cw,
      height: ch,
      imageCount: imagePaths.length,
      secondsPerImage: secondsPerImage,
      fps: settledFps,
      usedCanvas: true,
    );
  }

  /// Cheap structural check that [file] really is a video of [extension].
  ///
  /// The stub ffmpeg leaves behind when the concat input contributes nothing
  /// still exits 0, so the header is what separates a real file from a
  /// 261-byte lie. Each container is recognised by its own magic:
  ///
  ///  * mp4/mov: an `ftyp` box in the first 64 bytes;
  ///  * webm/mkv: the EBML header `1A 45 DF A3`;
  ///  * avi: `RIFF`.
  bool _looksLikeVideo(File file, String extension) {
    try {
      final head = file.openSync();
      try {
        final len = file.lengthSync();
        final take = len < 64 ? len : 64;
        final bytes = head.readSync(take);

        bool ascii(String needle) {
          final pattern = needle.codeUnits;
          for (var i = 0; i + pattern.length <= bytes.length; i++) {
            var hit = true;
            for (var k = 0; k < pattern.length; k++) {
              if (bytes[i + k] != pattern[k]) {
                hit = false;
                break;
              }
            }
            if (hit) return true;
          }
          return false;
        }

        switch (extension) {
          case 'webm':
          case 'mkv':
            return bytes.length >= 4 &&
                bytes[0] == 0x1A &&
                bytes[1] == 0x45 &&
                bytes[2] == 0xDF &&
                bytes[3] == 0xA3;
          case 'avi':
            return ascii('RIFF');
          default:
            return ascii('ftyp');
        }
      } finally {
        head.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  String get _outputExtension => format?.extension ?? 'mp4';

  /// Remove the staged copies and the concat list.
  void cleanup() {
    try {
      final dir = Directory('$workDir/itv_frames');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      final list = File('$workDir/itv_concat.txt');
      if (list.existsSync()) list.deleteSync();
    } catch (_) {
      // Best-effort: a leftover temp file is not worth failing a success on.
    }
  }
}
