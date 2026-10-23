// SPDX-License-Identifier: GPL-3.0-or-later

/// Hand a file to the system: gallery for images, a player for video or audio.
///
/// Goes through the same method channel as the save dialog (there is no plugin
/// for this that builds without symlink support on Windows, and the channel is
/// already there). The native side wraps the file in a FileProvider URI, so the
/// receiving app gets read access without any storage permission.
library open_service;

import 'package:flutter/services.dart';

class OpenService {
  const OpenService();

  static const MethodChannel _channel = MethodChannel('tugi/export');

  /// True when an app accepted the file, false when none did (or the platform
  /// side failed) — the caller should then offer share instead.
  Future<bool> open(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>('open', {'path': path});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // Host tests and desktop: nothing to open with.
      return false;
    }
  }
}
