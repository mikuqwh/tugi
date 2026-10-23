// SPDX-License-Identifier: GPL-3.0-or-later

/// The works shelf: every exported file, kept with its thumbnail, its source
/// and the feature that produced it.
///
/// Exports are written to the system temp directory, which the OS may clear at
/// any time, so a work is COPIED into the app's support directory before it is
/// indexed. Very large files are not copied (the shelf is for browsing, not a
/// second gallery); they keep a reference to the previous implementation path and are flagged
/// so the UI can say so.
// SPDX-License-Identifier: GPL-3.0-or-later

library works_service;

import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One exported file.
@immutable
class WorkItem {
  const WorkItem({
    required this.id,
    required this.path,
    required this.featureId,
    required this.bytes,
    required this.createdAt,
    required this.formatExtension,
    required this.originalName,
    this.sourcePath,
    this.thumbnailPath,
    this.copied = true,
  });

  final String id;

  /// Where the work lives now (inside the works dir when [copied]).
  final String path;

  /// The file it was made from, when the feature knows it.
  final String? sourcePath;

  final String featureId;
  final int bytes;
  final DateTime createdAt;
  final String formatExtension;

  /// The file name the export had before it was copied into the shelf. The
  /// stored copy is renamed to its id, so searching by the name the user saw
  /// needs this.
  final String originalName;

  /// A small JPEG next to the file, generated with ffmpeg. Null when the
  /// media has no video stream (audio) or the probe failed.
  final String? thumbnailPath;

  /// False when the file was too large to copy and [path] still points at the
  /// original location.
  final bool copied;

  String get fileName => path.split(Platform.pathSeparator).last;

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'sourcePath': sourcePath,
        'featureId': featureId,
        'bytes': bytes,
        'createdAt': createdAt.toIso8601String(),
        'format': formatExtension,
        'originalName': originalName,
        'thumbnailPath': thumbnailPath,
        'copied': copied,
      };

  static WorkItem? fromJson(Map<String, Object?> raw) {
    final id = raw['id'];
    final path = raw['path'];
    final feature = raw['featureId'];
    final bytes = raw['bytes'];
    final created = raw['createdAt'];
    if (id is! String || path is! String || feature is! String) return null;
    if (bytes is! int || created is! String) return null;
    final at = DateTime.tryParse(created);
    if (at == null) return null;
    return WorkItem(
      id: id,
      path: path,
      featureId: feature,
      bytes: bytes,
      createdAt: at,
      formatExtension: raw['format'] is String ? raw['format'] as String : '',
      originalName: raw['originalName'] is String
          ? raw['originalName'] as String
          : path.split(Platform.pathSeparator).last,
      sourcePath:
          raw['sourcePath'] is String ? raw['sourcePath'] as String : null,
      thumbnailPath: raw['thumbnailPath'] is String
          ? raw['thumbnailPath'] as String
          : null,
      copied: raw['copied'] is bool ? raw['copied'] as bool : true,
    );
  }
}

class WorksService extends ChangeNotifier {
  WorksService._();

  static final WorksService instance = WorksService._();

  /// Above this size the file is referenced instead of copied.
  static const int copyLimitBytes = 120 * 1024 * 1024;

  List<WorkItem> _items = const [];
  List<WorkItem> get items => _items;

  /// How many works to keep; 0 means unlimited. Persisted next to the index.
  int _keepLimit = 0;
  int get keepLimit => _keepLimit;

  /// Total bytes on the shelf, for the storage line in the UI.
  int get totalBytes => _items.fold<int>(0, (sum, item) => sum + item.bytes);

  Directory? _injectedDir;

  /// Overridable in tests: generating a thumbnail goes through ffmpeg, whose
  /// platform channel never answers inside a widget test (the future would
  /// hang forever).
  Future<String?> Function(String path, Directory dir, String id) _thumbnail =
      _ffmpegThumbnail;

  /// Test seam: point the shelf at a temp directory.
  @visibleForTesting
  void useDirectory(Directory? dir) => _injectedDir = dir;

  /// Test seam: replace the thumbnailer (see [_thumbnail]).
  @visibleForTesting
  void useThumbnailer(
    Future<String?> Function(String path, Directory dir, String id)? fn,
  ) =>
      _thumbnail = fn ?? _ffmpegThumbnail;

  /// Test seam: forget everything in memory (the singleton is shared across
  /// tests, so a stale list would leak between them).
  @visibleForTesting
  void resetForTest() {
    _items = const [];
    notifyListeners();
  }

  Future<Directory> _dir() async {
    final base = _injectedDir ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/works');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _indexFile() async {
    final dir = await _dir();
    return File('${dir.path}/index.json');
  }

  Future<File> _configFile() async {
    final dir = await _dir();
    return File('${dir.path}/config.json');
  }

  Future<void> load() async {
    try {
      final config = await _configFile();
      if (config.existsSync()) {
        final raw = jsonDecode(await config.readAsString());
        if (raw is Map && raw['keepLimit'] is int) {
          _keepLimit = (raw['keepLimit'] as int).clamp(0, 100000);
        }
      }
    } catch (_) {
      // A corrupt config must not stop the shelf from loading.
    }
    try {
      final file = await _indexFile();
      if (!file.existsSync()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return;
      _items = raw
          .whereType<Map>()
          .map((e) => WorkItem.fromJson(e.cast<String, Object?>()))
          .whereType<WorkItem>()
          .toList();
      // A file removed from disk (or by the OS) should not linger as a card.
      _items = _items.where((w) => File(w.path).existsSync()).toList();
      notifyListeners();
    } catch (_) {
      // A corrupt shelf must not stop the app from opening.
    }
  }

  Future<void> setKeepLimit(int limit) async {
    _keepLimit = limit.clamp(0, 100000);
    notifyListeners();
    try {
      final file = await _configFile();
      await file.writeAsString(jsonEncode({'keepLimit': _keepLimit}));
    } catch (_) {
      // Best effort.
    }
  }

  /// Delete the oldest works beyond [keep] (or [keepLimit] when omitted).
  ///
  /// Returns the number of works removed and the bytes freed, so the UI can
  /// report what happened instead of silently deleting files.
  Future<({int removed, int bytes})> cleanup({int? keep}) async {
    final limit = keep ?? _keepLimit;
    if (limit <= 0 || _items.length <= limit) return (removed: 0, bytes: 0);

    final ordered = List<WorkItem>.from(_items)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final doomed = ordered.skip(limit).toList();
    var freed = 0;
    for (final item in doomed) {
      freed += item.bytes;
      for (final path in [item.path, item.thumbnailPath]) {
        if (path == null) continue;
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // Best effort.
        }
      }
    }
    final doomedIds = doomed.map((d) => d.id).toSet();
    _items = _items.where((w) => !doomedIds.contains(w.id)).toList();
    notifyListeners();
    await _persist();
    return (removed: doomed.length, bytes: freed);
  }

  Future<void> _persist() async {
    try {
      final file = await _indexFile();
      await file.writeAsString(
        jsonEncode(_items.map((w) => w.toJson()).toList()),
      );
    } catch (_) {
      // Best effort.
    }
  }

  /// Record an exported file. [originPath] is the file that was just written.
  Future<WorkItem?> record({
    required String originPath,
    required String featureId,
    String? sourcePath,
    DateTime? now,
  }) async {
    final origin = File(originPath);
    if (!origin.existsSync()) return null;

    final dir = await _dir();
    final at = now ?? DateTime.now();
    final id = at.microsecondsSinceEpoch.toString();
    final ext = origin.path.contains('.')
        ? origin.path.split('.').last.toLowerCase()
        : '';
    final copy = origin.lengthSync() <= copyLimitBytes;

    var stored = originPath;
    if (copy) {
      try {
        stored = '${dir.path}/$id${ext.isEmpty ? '' : '.$ext'}';
        await origin.copy(stored);
      } catch (_) {
        stored = originPath;
      }
    }

    final thumb = await _thumbnail(stored, dir, id);

    final item = WorkItem(
      id: id,
      path: stored,
      sourcePath: sourcePath,
      featureId: featureId,
      bytes: File(stored).lengthSync(),
      createdAt: at,
      formatExtension: ext,
      originalName: origin.uri.pathSegments.last,
      thumbnailPath: thumb,
      copied: copy,
    );
    _items = [item, ..._items];
    notifyListeners();
    await _persist();
    if (_keepLimit > 0) await cleanup();
    return item;
  }

  /// A 320 px JPEG from the first frame, or null for audio / a broken file.
  static Future<String?> _ffmpegThumbnail(
    String path,
    Directory dir,
    String id,
  ) async {
    final thumb = '${dir.path}/$id.jpg';
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        path,
        '-vf',
        'scale=320:-2:force_original_aspect_ratio=decrease',
        '-frames:v',
        '1',
        '-q:v',
        '4',
        thumb,
      ]);
      final code = await session.getReturnCode();
      if (code?.isValueSuccess() == true && File(thumb).existsSync()) {
        return thumb;
      }
    } catch (_) {
      // Audio has no video stream; a failure here is expected.
    }
    return null;
  }

  Future<void> remove(WorkItem item) async {
    _items = _items.where((w) => w.id != item.id).toList();
    notifyListeners();
    for (final path in [item.path, item.thumbnailPath]) {
      if (path == null) continue;
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // Best effort.
      }
    }
    await _persist();
  }

  /// Filter + sort, for the shelf screen.
  List<WorkItem> query({
    String search = '',
    WorkSort sort = WorkSort.newest,
  }) {
    final q = search.trim().toLowerCase();
    final matched = q.isEmpty
        ? List<WorkItem>.from(_items)
        : _items.where((w) {
            final hay = [
              w.fileName,
              w.originalName,
              w.featureId,
              w.formatExtension,
              _featureLabel(w.featureId),
            ].join(' ').toLowerCase();
            return hay.contains(q);
          }).toList();
    matched.sort(switch (sort) {
      WorkSort.newest => (a, b) => b.createdAt.compareTo(a.createdAt),
      WorkSort.oldest => (a, b) => a.createdAt.compareTo(b.createdAt),
      WorkSort.largest => (a, b) => b.bytes.compareTo(a.bytes),
      WorkSort.smallest => (a, b) => a.bytes.compareTo(b.bytes),
    });
    return matched;
  }
}

enum WorkSort {
  newest('最新', '按导出时间，新的在前'),
  oldest('最早', '按导出时间，旧的在前'),
  largest('最大', '按文件大小，大的在前'),
  smallest('最小', '按文件大小，小的在前');

  const WorkSort(this.label, this.blurb);
  final String label;
  final String blurb;
}

/// Human label for a feature id, used by the cards and by search.
String _featureLabel(String id) => switch (id) {
      'video_to_gif' => 'Video to GIF',
      'images_to_gif' => 'Images to GIF',
      'edit_gif' => 'Edit GIF',
      'gif_to_video' => 'GIF to Video',
      'gif_to_images' => 'GIFs to Images',
      'compress_gif' => 'Compress GIFs',
      'add_watermark' => 'Add watermark',
      'edit_image' => 'Edit Image',
      'images_to_video' => 'Images to Video',
      'extract_audio' => 'Extract Audio',
      'format_convert' => 'Format Convert',
      _ => id,
    };

String featureLabelOf(String id) => _featureLabel(id);
