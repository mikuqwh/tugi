// SPDX-License-Identifier: GPL-3.0-or-later

/// "Save my result" — one action, three destinations.
///
/// The gallery only holds images and videos. Audio has no gallery equivalent
/// on Android, so an exported MP3 sent to `Gal.putImage` throws, which is
/// exactly the bug this file fixes: the Extract Audio screen told the user
/// 「存到相册」 and then failed.
///
/// The rule is decided by the file we just wrote, which is by construction the
/// format we asked for:
///
///  * image  -> gallery (Gal.putImage)
///  * video  -> gallery (Gal.putVideo)
///  * audio  -> the system save dialog (ACTION_CREATE_DOCUMENT via the
///              `tugi/export` channel), because Music/ and Downloads/ are the
///              only sensible homes and this needs no storage permission.
///
/// If the gallery refuses a file anyway, the action falls back to the save
/// dialog instead of erroring: the user asked to save something, and the
/// destination is an implementation detail until it fails.
// SPDX-License-Identifier: GPL-3.0-or-later

library export_service;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

/// Where a file can go.
enum ExportKind { image, video, audio }

/// What the primary button should say.
enum ExportAction { gallery, file }

/// Classify an output file by its extension.
///
/// Only extensions are consulted: the app produced the file, so the extension
/// is its own statement of format. Anything unknown is treated as [audio]'s
/// action (the save dialog), which is the safe destination for a file the
/// gallery would refuse.
ExportKind exportKindFor(String path) {
  final ext = _extension(path);
  if (_videoExtensions.contains(ext)) return ExportKind.video;
  if (_imageExtensions.contains(ext)) return ExportKind.image;
  return ExportKind.audio;
}

ExportAction exportActionFor(String path) =>
    exportKindFor(path) == ExportKind.audio
        ? ExportAction.file
        : ExportAction.gallery;

const Set<String> _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'apng',
  'bmp',
  'tiff',
  'tif',
  'avif',
  'jp2',
  'qoi',
  'ico',
  'tga',
  'heic',
};

const Set<String> _videoExtensions = {
  'mp4',
  'mov',
  'mkv',
  'webm',
  'avi',
  'm4v',
  '3gp',
  'flv',
  'ts',
};

String _extension(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// What happened, in terms we can show the user.
class ExportOutcome {
  const ExportOutcome(this.status, {this.message});

  final ExportStatus status;
  final String? message;

  bool get isSuccess =>
      status == ExportStatus.savedToGallery ||
      status == ExportStatus.savedToFile;
}

enum ExportStatus {
  savedToGallery,
  savedToFile,
  cancelled,
  failed,
}

class ExportService {
  ExportService({
    Future<void> Function(String path, String album)? saveImage,
    Future<void> Function(String path, String album)? saveVideo,
    Future<bool> Function(String path, String? suggestedName)? saveAs,
  })  : _saveImage =
            saveImage ?? ((path, album) => Gal.putImage(path, album: album)),
        _saveVideo =
            saveVideo ?? ((path, album) => Gal.putVideo(path, album: album)),
        _saveAs = saveAs ?? _systemSaveAs;

  final Future<void> Function(String path, String album) _saveImage;
  final Future<void> Function(String path, String album) _saveVideo;
  final Future<bool> Function(String path, String? suggestedName) _saveAs;

  /// The system save dialog, implemented in MainActivity (one method).
  static Future<bool> _systemSaveAs(String path, String? suggestedName) async {
    const channel = MethodChannel('tugi/export');
    final saved = await channel.invokeMethod<bool>('saveAs', {
      'path': path,
      'fileName': suggestedName,
    });
    return saved ?? false;
  }

  /// Save [path] to the destination its type deserves.
  /// [suggestedName] is what the save dialog pre-fills; the gallery ignores it.
  Future<ExportOutcome> save(
    String path, {
    String album = 'Tugi',
    String? suggestedName,
  }) async {
    if (!File(path).existsSync()) {
      return const ExportOutcome(ExportStatus.failed, message: '文件不存在');
    }

    switch (exportKindFor(path)) {
      case ExportKind.image:
        return _tryGallery(
          () => _saveImage(path, album),
          path,
          album,
        );
      case ExportKind.video:
        return _tryGallery(
          () => _saveVideo(path, album),
          path,
          album,
        );
      case ExportKind.audio:
        return _saveToFile(path, suggestedName);
    }
  }

  /// Gallery first, save dialog on refusal.
  Future<ExportOutcome> _tryGallery(
    Future<void> Function() toGallery,
    String path,
    String album,
  ) async {
    try {
      await toGallery();
      return const ExportOutcome(ExportStatus.savedToGallery);
    } catch (e) {
      // A video the gallery will not take is still a file the user wants.
      final fallback = await _saveToFile(path, null);
      if (fallback.status == ExportStatus.savedToFile) {
        return const ExportOutcome(ExportStatus.savedToFile,
            message: '相册不接受这个文件，已改为保存到文件');
      }
      return ExportOutcome(ExportStatus.failed, message: '保存失败：${_short(e)}');
    }
  }

  Future<ExportOutcome> _saveToFile(String path, String? suggestedName) async {
    try {
      final saved = await _saveAs(path, suggestedName);
      return ExportOutcome(
        saved ? ExportStatus.savedToFile : ExportStatus.cancelled,
      );
    } on MissingPluginException {
      return const ExportOutcome(ExportStatus.failed,
          message: '当前环境不支持“保存到文件”，请用分享');
    } catch (e) {
      return ExportOutcome(ExportStatus.failed, message: '保存失败：${_short(e)}');
    }
  }

  static String _short(Object e) {
    final text = e.toString();
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }
}
