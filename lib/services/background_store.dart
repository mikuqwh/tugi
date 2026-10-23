/// Copies a user-picked image into the app's support directory so the
/// background survives the picker's cache being cleared.
// SPDX-License-Identifier: GPL-3.0-or-later

library background_store;

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// Import [sourcePath] as the custom background and return the stored path.
///
/// The file name is UNIQUE per import (`background-<micros>.png`). Reusing one
/// fixed name made "replace the background" look broken: Flutter's image cache
/// keys by file path, so a new picture written to the same path kept showing
/// the old bytes until the app restarted.
///
/// The previous custom file is deleted on success, and [evict] drops the
/// decoded image from the cache so the new one appears immediately.
Future<String> importBackground(
  String sourcePath, {
  Directory? into,
  DateTime? now,
}) async {
  final dir = into ?? await getApplicationSupportDirectory();
  await dir.create(recursive: true);

  final stamp = (now ?? DateTime.now()).microsecondsSinceEpoch;
  final target = File('${dir.path}/background-$stamp.png');
  await File(sourcePath).copy(target.path);

  // Drop the old background(s); a stale one is dead weight and, worse, could
  // come back if a settings file still pointed at it.
  //
  // Compare URIs, not strings: `target.path` was built with '/' while
  // `listSync` returns '\' on Windows, so string equality never matched and
  // the brand-new file deleted itself.
  final keep = target.absolute.uri;
  for (final entity in dir.listSync()) {
    if (entity is File &&
        entity.absolute.uri != keep &&
        _isBackgroundFile(entity)) {
      try {
        entity.deleteSync();
      } catch (_) {
        // Best effort: the new import already succeeded.
      }
    }
  }

  await evictBackgroundImage(target.path);
  return target.path;
}

bool _isBackgroundFile(File file) {
  final name = file.uri.pathSegments.last;
  return name.startsWith('background-') || name == 'background_custom.png';
}

/// Remove a background file from Flutter's image cache.
///
/// Safe to call for a path that was never decoded: the cache simply has no
/// entry to drop.
Future<void> evictBackgroundImage(String path) async {
  try {
    await FileImage(File(path)).evict();
  } catch (_) {
    // Cache eviction is an optimisation, never a correctness requirement.
  }
}

/// Delete every stored background. Used when the user switches away from the
/// image mode, so the files do not accumulate forever.
Future<void> clearCustomBackgrounds({Directory? from}) async {
  final dir = from ?? await getApplicationSupportDirectory();
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync()) {
    if (entity is File && _isBackgroundFile(entity)) {
      try {
        entity.deleteSync();
      } catch (_) {
        // Best effort.
      }
    }
  }
}
