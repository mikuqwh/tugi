// SPDX-License-Identifier: GPL-3.0-or-later

/// User-saved colours, shared by every colour picker in the app.
///
/// A flat list in `colors.json` in the support directory. Saving a colour from
/// the watermark panel makes it available anywhere else that asks for one --
/// that is the point of a preset.
// SPDX-License-Identifier: GPL-3.0-or-later

library color_presets;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class ColorPresetStore extends ChangeNotifier {
  ColorPresetStore._();

  static final ColorPresetStore instance = ColorPresetStore._();

  static const int maxPresets = 12;

  List<Color> _colors = const [];
  List<Color> get colors => _colors;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/colors.json');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is List) {
        _colors = raw
            .whereType<int>()
            .where((v) => v >> 24 != 0)
            .map(Color.new)
            .toList();
        notifyListeners();
      }
    } catch (_) {
      // Ignore a corrupt preset file.
    }
  }

  Future<void> _persist() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file
          .writeAsString(jsonEncode(_colors.map((c) => c.toARGB32()).toList()));
    } catch (_) {
      // Presets are a convenience; losing them is not worth an error.
    }
  }

  /// Save [color] (newest first, de-duplicated, capped).
  Future<void> add(Color color) async {
    final v = color.toARGB32();
    _colors = [
      color,
      ..._colors.where((c) => c.toARGB32() != v),
    ].take(maxPresets).toList();
    notifyListeners();
    await _persist();
  }

  Future<void> remove(Color color) async {
    final v = color.toARGB32();
    _colors = _colors.where((c) => c.toARGB32() != v).toList();
    notifyListeners();
    await _persist();
  }
}
