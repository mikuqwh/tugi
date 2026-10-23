// SPDX-License-Identifier: GPL-3.0-or-later

library video_to_gif_service;

/// Tugi Video to GIF service.
/// Uses ffmpeg-kit for frame extraction + palette encoding.
/// Pipeline: video -> frames -> concat -> palettegen/paletteuse -> GIF
///
/// dedup=true (default): mpdecimate removes duplicate frames, reducing file size
///   but altering frame timing. Video->GIF typically wants dedup ON.
///   Effect: frame count <= extracted count; duration = frameCount / fps.

import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import '../models/encode_preset.dart';
import 'ffmpeg_progress.dart';
import '../models/creation.dart';
import '../utils/params.dart';

class VideoToGifService {
  final String workDir;

  /// GIF by default; an APNG target skips the palette pass entirely.
  final FormatSpec? format;
  final String _framesSubdir;
  late final String _concatList;
  final String _outputPath;

  VideoToGifService({
    required this.workDir,
    String? outputDir,
    this.format,
  })  : _framesSubdir =
            '$workDir/frames_${DateTime.now().millisecondsSinceEpoch}',
        // Distinct per-run name: the Images-to-GIF pipeline writes into the same
        // workDir and used to clobber this file.
        _outputPath = outputDir ??
            '$workDir/video_${DateTime.now().millisecondsSinceEpoch}'
                '.${format?.extension ?? 'gif'}' {
    _concatList = '$_framesSubdir/concat_list.txt';
    Directory(_framesSubdir).createSync(recursive: true);
  }

  /// Step 1: Extract frames from video, resampled to [fps].
  ///
  /// Scaling happens here rather than at encode time so the palette pass works
  /// on the final pixel dimensions (and peak memory stays low).
  /// Uses ffmpeg: -i video -vf "fps=<fps>[,scale=<w>:-2]" frame_%06d.png
  Future<void> extractFrames(
    String videoPath, {
    required int fps,
    double? outputWidth,
  }) async {
    final vf = (outputWidth != null && outputWidth > 0)
        ? 'fps=$fps,scale=${outputWidth.toInt()}:-2'
        : 'fps=$fps';

    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      videoPath,
      '-vf',
      vf,
      '$_framesSubdir/video_to_image_%06d.png',
    ]);
    final returnCode = await session.getReturnCode();
    if (returnCode == null || !returnCode.isValueSuccess()) {
      throw Exception('Frame extraction failed: ${await session.getOutput()}');
    }
  }

  /// Step 2: Count extracted frames (isolated in this run's subdirectory).
  int countFrames() {
    final dir = Directory(_framesSubdir);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains(RegExp(r'video_to_image_\d+\.png$')))
        .toList();
    return files.length;
  }

  /// Step 3: Build concat list file.
  ///
  /// Frame names must match the `%06d` template used by [extractFrames]
  /// (`video_to_image_000001.png`). An unpadded `video_to_image_1.png` makes
  /// the concat demuxer fail with "No such file or directory".
  Future<void> buildConcatList(int frameCount, {required int fps}) async {
    final buf = StringBuffer();
    for (var i = 0; i < frameCount; i++) {
      final name = 'video_to_image_${(i + 1).toString().padLeft(6, '0')}.png';
      buf.writeln("file '$_framesSubdir/$name'");
      buf.writeln('duration ${1.0 / fps}');
    }
    await File(_concatList).writeAsString(buf.toString());
  }

  /// Step 4: Encode GIF: concat -> palettegen/paletteuse -> gif.
  /// Uses ffmpeg-kit full-gpl (matching App's ffmpeg-kit 8.0.0).
  Future<String> encodeGif({
    int fps = 12,
    bool loop = true,
    bool dedup = false,
  }) async {
    if (format?.id == 'apng') {
      final args = ffmpeg.apngFromFrames(
        concatListPath: _concatList,
        outputPath: _outputPath,
        loop: loop,
        prefixFilter: dedup ? 'mpdecimate,setpts=N/FRAME_RATE/TB' : '',
      );
      final session = await FFmpegKit.executeWithArguments(args);
      if ((await session.getReturnCode())?.isValueSuccess() != true) {
        throw Exception('APNG encoding failed: ${await session.getOutput()}');
      }
      return _outputPath;
    }
    final filter = dedup
        ? 'mpdecimate,setpts=N/FRAME_RATE/TB,fps=$fps,'
            'split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1'
        : 'fps=$fps,split[s1][s2];'
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
      filter,
      ...gifFlags,
      // Spread both tokens: `if (loop) '-loop', '0'` would leave a bare '0' in
      // argv when loop is off, which ffmpeg reads as the output filename.
      ...['-loop', loop ? '0' : '1'],
      '-r',
      fps.toString(),
      '-f',
      'gif',
      _outputPath,
    ];

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();
    if (returnCode == null || !returnCode.isValueSuccess()) {
      throw Exception('GIF encoding failed: ${await session.getOutput()}');
    }
    return _outputPath;
  }

  /// Full pipeline: video -> GIF in one call.
  ///
  /// [fps] drives both the extraction resample and the GIF frame rate.
  /// [outputWidth] null/<=0 keeps the source width (`:original:` preset).
  /// [dedup] defaults to true: mpdecimate removes duplicate frames for smaller
  ///   output. When dedup=true, output frame count <= extracted count, and
  ///   duration adjusts accordingly.
  Future<String> convertVideoToGif(
    String videoPath, {
    int fps = Creation.layerFps,
    bool loop = true,
    bool dedup = true,
    double? outputWidth,
  }) async {
    await extractFrames(videoPath, fps: fps, outputWidth: outputWidth);

    final frameCount = countFrames();
    if (frameCount == 0) {
      throw Exception('No frames extracted from $videoPath');
    }
    await buildConcatList(frameCount, fps: fps);

    return encodeGif(fps: fps, loop: loop, dedup: dedup);
  }

  /// Path of the GIF this run produced.
  String get outputPath => _outputPath;

  /// Single-pass convert: video -> GIF, no intermediate PNG frames.
  ///
  /// This mirrors this app, whose filter chain
  /// directly. The extract/concat path above is kept because the Images-to-GIF
  /// flow shares it, but it costs a full frame decode plus disk round-trip.
  ///
  /// [dedup] prepends `mpdecimate,setpts=N/FRAME_RATE/TB`; output frame count
  /// then no longer equals `duration * fps`.
  Future<String> convertDirect({
    required String videoPath,
    int fps = 12,
    int? outputWidth,
    bool loop = true,
    bool dedup = false,
    double? start,
    double? duration,
    String? crop,
    void Function(double progress)? onProgress,
    int? totalMs,
    void Function(FfmpegJob job)? onJob,
    EncodePreset preset = EncodePreset.balanced,
  }) async {
    final isApng = format?.id == 'apng';
    final args = isApng
        ? ffmpeg.videoToApng(
            inputPath: videoPath,
            outputPath: _outputPath,
            fps: fps,
            outputWidth: outputWidth,
            loop: loop,
            dedup: dedup,
            start: start,
            duration: duration,
            crop: crop,
          )
        : ffmpeg.videoToGif(
            inputPath: videoPath,
            outputPath: _outputPath,
            fps: fps,
            outputWidth: outputWidth,
            loop: loop,
            dedup: dedup,
            start: start,
            duration: duration,
            crop: crop,
            preset: preset,
          );
    final job = await runWithProgress(
      args,
      totalMs: totalMs,
      onProgress: onProgress,
    );
    onJob?.call(job);
    await job.wait();
    return _outputPath;
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

  /// Create a Creation object from the result.
  Creation buildCreation({
    required String videoPath,
    required double videoWidth,
    required double videoHeight,
    required String gifPath,
  }) =>
      Creation.videoToGif(
        videoPath: videoPath,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
      );
}

/// Extract the actionable tail of ffmpeg's log.
///
/// `FFmpegKit` returns the full log: the ~40-line `configuration:` block, the
/// `Stream mapping:` dump, every `Stream #0:N(und):` header, and the encoder
/// banner. The actual failure is always in the LAST few lines (e.g.
/// `Error initializing output stream 0:0`, `Conversion failed!`), so keep a
/// short window from the end plus any line that looks like a real error.
String summarizeFfmpegOutput(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '(no output)';
  final lines =
      raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return '(no output)';

  // Grep for real diagnostics anywhere in the log, then always append the tail.
  final interesting = <String>[];
  for (final l in lines) {
    final lower = l.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('invalid') ||
        lower.contains('failed') ||
        lower.contains('cannot') ||
        lower.contains('unable') ||
        lower.contains('no such') ||
        lower.contains('not found') ||
        lower.contains('unsupported') ||
        lower.contains('unrecognized') ||
        lower.contains('conversion failed')) {
      interesting.add(l);
    }
  }
  final tail = lines.skip(lines.length > 6 ? lines.length - 6 : 0);
  final out = <String>[
    ...interesting,
    if (interesting.isNotEmpty) '---',
    ...tail
  ];
  return out.take(10).join('\n');
}
