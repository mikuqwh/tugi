/// Replacing a custom background must actually change the stored file.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/services/background_store.dart';

void main() {
  test('a second import uses a new file and removes the first', () async {
    final dir = Directory.systemTemp.createTempSync('bg_store_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    final a = File('${dir.path}/a.png')..writeAsBytesSync([1, 2, 3]);
    final b = File('${dir.path}/b.png')..writeAsBytesSync([4, 5, 6, 7]);

    final first = await importBackground(a.path, into: dir);
    expect(File(first).existsSync(), isTrue);

    final second = await importBackground(b.path, into: dir);
    expect(second, isNot(first),
        reason: 'same path means the image cache serves the old bytes');
    expect(File(second).readAsBytesSync(), [4, 5, 6, 7]);

    // The old one is gone, and the sources were not touched.
    expect(File(first).existsSync(), isFalse);
    expect(a.existsSync(), isTrue);

    await clearCustomBackgrounds(from: dir);
    expect(File(second).existsSync(), isFalse);
  });
}
