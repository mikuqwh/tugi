// SPDX-License-Identifier: GPL-3.0-or-later

/// Favourites and the single "last used" entry, persisted as one small JSON.
///
/// Deliberately not sqflite: this is a list of ids plus one id, and a table
/// would be more code, more schema and more to break. The file lives in the
/// app's support directory, so it survives restarts and dies with the app.
///
/// The interface exists so widget tests can use [MemoryHomePrefs] instead of
/// hitting path_provider, which is not available on the host.
// SPDX-License-Identifier: GPL-3.0-or-later

library home_prefs;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ui/feature_catalog.dart';

/// What the home screen remembers.
class HomePrefsData {
  const HomePrefsData({this.favorites = const [], this.lastUsed});

  /// Ids the user starred, in star order.
  final List<String> favorites;

  /// The single most recently opened feature.
  ///
  /// This replaced a six-entry "recent" list: the home now shows one card, so
  /// keeping a list would only be storage nobody reads.
  final String? lastUsed;

  HomePrefsData copyWith({List<String>? favorites, String? lastUsed}) =>
      HomePrefsData(
        favorites: favorites ?? this.favorites,
        lastUsed: lastUsed ?? this.lastUsed,
      );
}

abstract class HomePrefs {
  Future<HomePrefsData> load();
  Future<void> save(HomePrefsData data);
}

/// JSON file in the app support directory.
class FileHomePrefs implements HomePrefs {
  static const _fileName = 'home_prefs.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<HomePrefsData> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const HomePrefsData();
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return const HomePrefsData();

      final favorites = (raw['favorites'] is List)
          ? (raw['favorites'] as List).whereType<String>().toList()
          : const <String>[];

      // Migration: older builds stored a `recent` array. Its head is exactly
      // what the single card should show, so no information is lost.
      final String? lastUsed;
      if (raw['lastUsed'] is String) {
        lastUsed = raw['lastUsed'] as String;
      } else if (raw['recent'] is List) {
        final recent = (raw['recent'] as List).whereType<String>();
        lastUsed = recent.isEmpty ? null : recent.first;
      } else {
        lastUsed = null;
      }

      return HomePrefsData(favorites: favorites, lastUsed: lastUsed);
    } catch (_) {
      // A corrupt preferences file must never stop the app from opening.
      return const HomePrefsData();
    }
  }

  @override
  Future<void> save(HomePrefsData data) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'favorites': data.favorites,
        'lastUsed': data.lastUsed,
      }));
    } catch (_) {
      // Losing a favourite is not worth crashing over.
    }
  }
}

/// In-memory implementation for tests.
class MemoryHomePrefs implements HomePrefs {
  MemoryHomePrefs([HomePrefsData? initial])
      : _data = initial ?? const HomePrefsData();

  HomePrefsData _data;

  @override
  Future<HomePrefsData> load() async => _data;

  @override
  Future<void> save(HomePrefsData data) async => _data = data;
}

/// Drop ids that no longer exist in the catalog.
///
/// Renaming or removing a feature would otherwise leave a favourite that
/// renders nothing and can never be removed.
HomePrefsData sanitize(HomePrefsData data) => HomePrefsData(
      favorites: data.favorites.where((id) => featureById(id) != null).toList(),
      lastUsed: featureById(data.lastUsed ?? '') == null ? null : data.lastUsed,
    );
