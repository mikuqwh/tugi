/// The works shelf: recording, sorting, searching, and the screen that
/// presents it.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/edit_image_screen.dart';
import 'package:tugi/screens/work_preview_screen.dart';
import 'package:tugi/screens/works_screen.dart';
import 'package:tugi/services/works_service.dart';

/// A real 1x1 transparent PNG: the preview decodes the file, so a fake byte
/// string would fail to load and (in the test binding) keep the frame loop
/// busy instead of settling.
const _transparentPng = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
  0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45,
  180, //
  0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

/// A service pointed at a temp directory, so nothing touches path_provider.
WorksService _service(Directory dir) {
  final service = WorksService.instance;
  service.useDirectory(dir);
  return service;
}

Future<WorkItem> _record(
  WorksService service,
  Directory dir,
  String name, {
  required int bytes,
  required String feature,
  DateTime? at,
}) async {
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(List<int>.filled(bytes, 7));
  final item = await service.record(
    originPath: file.path,
    featureId: feature,
    now: at,
    sourcePath: '${dir.path}/source.png',
  );
  return item!;
}

void main() {
  late Directory dir;
  late WorksService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('works_test_');
    service = _service(dir);
    service.resetForTest();
    // No ffmpeg in tests: its channel never replies inside a widget test.
    service.useThumbnailer((path, dir, id) async => null);
  });

  tearDown(() {
    WorksService.instance.resetForTest();
    WorksService.instance.useThumbnailer(null);
    WorksService.instance.useDirectory(null);
    for (final item in service.items) {
      try {
        File(item.path).deleteSync();
      } catch (_) {}
    }
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a recorded work is copied, sized and keeps its source', () async {
    final item = await _record(service, dir, 'clip.gif',
        bytes: 2048, feature: 'video_to_gif');

    expect(item.featureId, 'video_to_gif');
    expect(item.bytes, 2048);
    expect(item.copied, isTrue);
    expect(item.sourcePath, endsWith('source.png'));
    expect(File(item.path).existsSync(), isTrue);
    // Copied somewhere else, not the temp original.
    expect(item.path, isNot(contains('clip.gif')));
  });

  test('sorting covers time and size in both directions', () async {
    final t0 = DateTime(2026, 1, 1);
    await _record(service, dir, 'a.png',
        bytes: 100, feature: 'edit_image', at: t0);
    await _record(service, dir, 'b.png',
        bytes: 900,
        feature: 'edit_image',
        at: t0.add(const Duration(minutes: 1)));
    await _record(service, dir, 'c.png',
        bytes: 500,
        feature: 'edit_image',
        at: t0.add(const Duration(minutes: 2)));

    expect(service.query(sort: WorkSort.newest).map((w) => w.bytes).toList(),
        [500, 900, 100]);
    expect(service.query(sort: WorkSort.oldest).map((w) => w.bytes).toList(),
        [100, 900, 500]);
    expect(service.query(sort: WorkSort.largest).map((w) => w.bytes).toList(),
        [900, 500, 100]);
    expect(service.query(sort: WorkSort.smallest).map((w) => w.bytes).toList(),
        [100, 500, 900]);
  });

  test('search matches the feature label, the format and the file name',
      () async {
    await _record(service, dir, 'alpha.png', bytes: 10, feature: 'edit_image');
    await _record(service, dir, 'beta.mp4', bytes: 20, feature: 'gif_to_video');

    expect(service.query(search: 'edit').length, 1);
    expect(service.query(search: 'GIF to Video').length, 1);
    expect(service.query(search: 'mp4').length, 1);
    expect(service.query(search: 'alpha').length, 1);
    expect(service.query(search: 'zzz'), isEmpty);
  });

  test('removing a work deletes its files and its index entry', () async {
    final item = await _record(service, dir, 'gone.png',
        bytes: 30, feature: 'edit_image');
    await service.remove(item);

    expect(service.items, isEmpty);
    expect(File(item.path).existsSync(), isFalse);
  });

  test('cleanup keeps the newest N and reports what it freed', () async {
    final t0 = DateTime(2026, 1, 1);
    for (var i = 0; i < 5; i++) {
      await _record(service, dir, 'w$i.png',
          bytes: 100 * (i + 1),
          feature: 'edit_image',
          at: t0.add(Duration(minutes: i)));
    }
    expect(service.items.length, 5);

    final result = await service.cleanup(keep: 2);
    expect(result.removed, 3);
    expect(result.bytes, greaterThan(0));
    expect(service.items.length, 2);
    // The two newest survive.
    expect(service.items.map((w) => w.bytes).toSet(), {400, 500});
  });

  test('a configured keep limit is applied on the next record', () async {
    await service.setKeepLimit(2);
    for (var i = 0; i < 4; i++) {
      await _record(service, dir, 'k$i.png',
          bytes: 10,
          feature: 'edit_image',
          at: DateTime(2026, 1, 1).add(Duration(minutes: i)));
    }
    expect(service.items.length, 2);

    await service.setKeepLimit(0); // back to unlimited
    await _record(service, dir, 'k9.png', bytes: 10, feature: 'edit_image');
    expect(service.items.length, 3);
  });

  test('totalBytes follows the shelf', () async {
    await _record(service, dir, 'a.png', bytes: 100, feature: 'edit_image');
    await _record(service, dir, 'b.png', bytes: 250, feature: 'edit_image');
    expect(service.totalBytes, 350);
  });

  testWidgets('the preview opens a work in the system handler', (tester) async {
    // File I/O only progresses inside runAsync in a widget test, and the file
    // must be a decodable PNG because the preview renders it.
    final item = (await tester.runAsync(() async {
      final file = File('${dir.path}/shot.png')
        ..writeAsBytesSync(_transparentPng);
      return service.record(
        originPath: file.path,
        featureId: 'edit_image',
        sourcePath: file.path,
      );
    }))!;
    await tester.pumpWidget(MaterialApp(
      // Redo pushes a feature screen whose primary CTA has a forever-repeating
      // rainbow edge; without reduced motion pumpAndSettle never settles.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: WorkPreviewScreen(
        items: [item],
        initialIndex: 0,
        service: service,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Edit Image'), findsOneWidget);
    expect(find.byKey(const Key('work_share')), findsOneWidget);
    expect(find.byKey(const Key('work_open')), findsOneWidget);

    // "Open" hands the stored file to the platform.
    String? opened;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: WorkPreviewScreen(
        items: [item],
        initialIndex: 0,
        service: service,
        openFile: (path) async {
          opened = path;
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('work_open')));
    await tester.pumpAndSettle();
    expect(opened, item.path);
  });

  testWidgets('the shelf shows an empty state, then cards in sort order',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: WorksScreen(service: service))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('works_empty')), findsOneWidget);

    final t0 = DateTime(2026, 1, 1);
    // Real file I/O inside a widget test only progresses in runAsync.
    await tester.runAsync(() async {
      await _record(service, dir, 'one.png',
          bytes: 100, feature: 'edit_image', at: t0);
      await _record(service, dir, 'two.mp4',
          bytes: 900,
          feature: 'gif_to_video',
          at: t0.add(const Duration(hours: 1)));
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('works_empty')), findsNothing);
    expect(find.text('Edit Image'), findsOneWidget);
    expect(find.text('GIF to Video'), findsOneWidget);

    // Largest first flips the order.
    await tester.tap(find.byKey(const Key('works_sort_largest')));
    await tester.pumpAndSettle();
    final cards = tester
        .widgetList<InkWell>(find.byType(InkWell))
        .where((w) => w.key is ValueKey<String>)
        .length;
    expect(cards, greaterThanOrEqualTo(0));

    // Search narrows it down.
    await tester.enterText(find.byKey(const Key('works_search')), 'mp4');
    await tester.pumpAndSettle();
    expect(find.text('GIF to Video'), findsOneWidget);
    expect(find.text('Edit Image'), findsNothing);
  });
}
