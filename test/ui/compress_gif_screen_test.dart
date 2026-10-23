/// Compress GIFs screen: the two modes and the size estimate.
///
/// The fixture is a real 3-frame GIF (red / green / blue, 100 ms each) so the
/// screen parses it exactly as it parses a picked file: frame count and rate
/// are what the Extract Frames mode and its estimate are built on.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/compress_gif_screen.dart';
import 'package:tugi/utils/size_estimate.dart';

/// 8x8, three frames, 100 ms each: 3 frames at 10 fps, 177 bytes.
const String _gifB64 =
    'R0lGODlhCAAIAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAA'
    'CAAIAAAIDwABCBxIsKDBgwgTKkwYEAAh+QQBCgABACwAAAAACAAIAIEA/wAAAAAAAAAAAAAIDwAB'
    'CBxIsKDBgwgTKkwYEAAh+QQBCgABACwAAAAACAAIAIEAAP8AAAAAAAAAAAAIDwABCBxIsKDBgwgT'
    'KkwYEAA7';

String _writeFixture() {
  final dir = Directory.systemTemp.createTempSync('compress_fixture_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the handle while the image cache holds the file.
    }
  });
  final file = File('${dir.path}/three.gif');
  file.writeAsBytesSync(base64Decode(_gifB64));
  return file.path;
}

Future<void> _pumpWithGif(WidgetTester tester, String path) async {
  await tester.pumpWidget(
      const MaterialApp(builder: _noAnimations, home: CompressGifScreen()));
  final dynamic state = tester.state(find.byType(CompressGifScreen));
  await tester.runAsync(() => state.loadGifForTest(path));
  await tester.pump();
}

String _fmt(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String _estimateText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('compress_estimate'))).data!;

/// Reduced motion: the primary CTA's rainbow edge animates forever, which
/// makes `pumpAndSettle` hang. The animation itself is covered by
/// test/ui/rainbow_glow_test.dart.
Widget _noAnimations(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

void main() {
  testWidgets('the empty state asks for a GIF', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CompressGifScreen()));
    await tester.pump();
    expect(find.text('选择 GIF'), findsOneWidget);
    expect(find.byKey(const Key('compress_estimate')), findsNothing);
  });

  testWidgets('both compress modes are selectable', (tester) async {
    // Extract Frames used to be greyed out ("即将推出"); it now runs.
    await _pumpWithGif(tester, _writeFixture());
    final extract = find.byKey(const Key('compress_mode_Extract_Frames'));
    expect(extract, findsOneWidget);
    expect(tester.widget<ListTile>(extract).enabled, isTrue);
  });

  testWidgets('the estimate follows the ratio', (tester) async {
    final path = _writeFixture();
    final bytes = File(path).lengthSync();
    await _pumpWithGif(tester, path);

    final expected50 = estimateCompressedGif(bytes, 0.5);
    expect(
      _estimateText(tester),
      contains('${_fmt(expected50.lowBytes)} – ${_fmt(expected50.highBytes)}'),
    );

    // 20% is a much smaller promise than 50%.
    await tester.tap(find.text('20%'));
    await tester.pumpAndSettle();
    final expected20 = estimateCompressedGif(bytes, 0.2);
    expect(
      _estimateText(tester),
      contains('${_fmt(expected20.lowBytes)} – ${_fmt(expected20.highBytes)}'),
    );
    expect(expected20.midBytes, lessThan(expected50.midBytes));
  });

  testWidgets('Extract Frames shows the stride and its own estimate',
      (tester) async {
    final path = _writeFixture();
    final bytes = File(path).lengthSync();
    await _pumpWithGif(tester, path);

    await tester.tap(find.byKey(const Key('compress_mode_Extract_Frames')));
    await tester.pumpAndSettle();

    // The source line tells the user what the stride does to their file.
    expect(find.textContaining('源：3 帧 · 10.0 fps'), findsOneWidget);
    expect(find.byKey(const Key('compress_step_2')), findsOneWidget);
    expect(find.byKey(const Key('compress_step_3')), findsOneWidget);
    expect(find.byKey(const Key('compress_step_5')), findsOneWidget);

    final expected2 = estimateFrameStepGif(bytes, 3, 2);
    expect(
      _estimateText(tester),
      contains('${_fmt(expected2.lowBytes)} – ${_fmt(expected2.highBytes)}'),
    );

    // Keeping one of three frames promises less than one of two.
    await tester.tap(find.byKey(const Key('compress_step_3')));
    await tester.pumpAndSettle();
    expect(find.textContaining('→ 约 1 帧'), findsOneWidget);
    final expected3 = estimateFrameStepGif(bytes, 3, 3);
    expect(expected3.midBytes, lessThan(expected2.midBytes));
  });

  testWidgets('the custom ratio dialog previews the size as you type',
      (tester) async {
    final path = _writeFixture();
    final bytes = File(path).lengthSync();
    await _pumpWithGif(tester, path);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    // The dialog opens on the current ratio, already carrying its band.
    final opened = estimateCompressedGif(bytes, 0.5);
    expect(
      find.text('预计输出 ≈ ${_fmt(opened.lowBytes)} – '
          '${_fmt(opened.highBytes)}'),
      findsOneWidget,
    );

    // A nonsense value says so instead of showing a stale band.
    await tester.enterText(find.byType(TextField), '0');
    await tester.pumpAndSettle();
    expect(find.text('输入 1 - 99 查看预计大小'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '30');
    await tester.pumpAndSettle();
    final expected = estimateCompressedGif(bytes, 0.3);
    expect(
      find.text('预计输出 ≈ ${_fmt(expected.lowBytes)} – '
          '${_fmt(expected.highBytes)}'),
      findsOneWidget,
    );

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    // The chip now carries the custom value.
    expect(find.text('30%（自定义）'), findsOneWidget);
  });
}
