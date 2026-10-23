// SPDX-License-Identifier: GPL-3.0-or-later

/// Filmstrips for the trim timeline: N evenly-spaced thumbnails from a video
/// or an animated GIF.
///
/// The strip is deliberately low resolution (64 px tall). A 10-frame strip
/// costs ~10 short ffmpeg runs on first use, so the result is cached next to
/// the source's mtime: switching back and forth between two files does not
/// re-extract.
library filmstrip_service;

import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

class FilmstripService {
  FilmstripService({String? workDir})
      : workDir = workDir ?? Directory.systemTemp.path;

  final String workDir;

  /// How many thumbnails a strip holds. Ten reads as a filmstrip on a phone
  /// without making the extraction feel slow.
  static const int frameCount = 10;

  /// `path -> [frame files]`, keyed with the source mtime so a re-encoded file
  /// at the same path is not served from a stale strip.
  static final Map<String, List<String>> _cache = {};

  static String _key(String path) {
    final file = File(path);
    final mtime =
        file.existsSync() ? file.lastModifiedSync().millisecondsSinceEpoch : 0;
    return '$path|$mtime';
  }

  /// Thumbnails for [path], left to right, or an empty list on failure.
  Future<List<String>> frames({
    required String path,
    required double seconds,
    int count = frameCount,
  }) async {
    if (seconds <= 0 || !File(path).existsSync()) return const [];
    final key = _key(path);
    final cached = _cache[key];
    if (cached != null) return cached;

    final dir = Directory(
        '$workDir/filmstrip_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);

    final out = <String>[];
    final step = seconds / count;
    for (var i = 0; i < count; i++) {
      final at = step * i + step / 2;
      final target = '${dir.path}/f${i.toString().padLeft(2, '0')}.jpg';
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        // Seeking before -i is the fast path; the strip is a preview, so a
        // frame or two of drift is irrelevant.
        '-ss',
        at.toStringAsFixed(3),
        '-i',
        path,
        '-frames:v',
        '1',
        '-vf',
        'scale=-2:64',
        '-q:v',
        '6',
        target,
      ]);
      final code = await session.getReturnCode();
      if (code?.isValueSuccess() == true && File(target).existsSync()) {
        out.add(target);
      }
    }
    if (out.isEmpty) return const [];
    _cache[key] = out;
    return out;
  }

  /// A poster large enough to crop against (max 1280 px wide). The 64 px
  /// filmstrip thumbnails are useless for judging a crop.
  Future<String?> posterFull({required String path, required double at}) async {
    if (!File(path).existsSync()) return null;
    final dir =
        Directory('$workDir/poster_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final target = '${dir.path}/poster.jpg';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-ss',
      (at < 0 ? 0 : at).toStringAsFixed(3),
      '-i',
      path,
      '-frames:v',
      '1',
      '-vf',
      "scale='min(1280,iw)':-2",
      '-q:v',
      '3',
      target,
    ]);
    final code = await session.getReturnCode();
    return code?.isValueSuccess() == true && File(target).existsSync()
        ? target
        : null;
  }

  /// Bytes of the first frame, for the empty/large preview tile.
  Future<String?> poster(
      {required String path, required double seconds}) async {
    final frames = await this.frames(path: path, seconds: seconds, count: 1);
    return frames.isEmpty ? null : frames.first;
  }

  /// Drop every cached strip (called when the app's temp dir is cleared).
  static void clearCache() => _cache.clear();

  /// Debug helper: the cache as JSON, for the settings screen's storage row.
  static String describeCache() => jsonEncode(
        _cache.map((k, v) => MapEntry(k.split('|').first, v.length)),
      );
}
