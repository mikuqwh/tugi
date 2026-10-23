/// The "common + 更多格式" picker.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/ui/output_format_picker.dart';

Future<void> _pump(
  WidgetTester tester, {
  FormatSpec? selected,
  ValueChanged<FormatSpec>? onSelected,
  Set<String>? available,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: OutputFormatPicker(
        formats: formatsFor(MediaKind.video),
        selected: selected ?? formatById('mp4_h264')!,
        common: const ['mp4_h264', 'mp4_h265', 'webm_vp9'],
        available: available,
        onSelected: onSelected ?? (_) {},
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('common formats are visible, the rest are behind one tap',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('format_chip_mp4_h264')), findsOneWidget);
    expect(find.byKey(const Key('format_chip_webm_vp9')), findsOneWidget);
    // MKV/MOV/AVI are the long tail.
    expect(find.byKey(const Key('format_chip_mkv_h264')), findsNothing);
    expect(find.byKey(const Key('format_picker_more')), findsOneWidget);

    await tester.tap(find.byKey(const Key('format_picker_more')));
    await tester.pump();
    expect(find.byKey(const Key('format_chip_mkv_h264')), findsOneWidget);
    expect(find.byKey(const Key('format_picker_less')), findsOneWidget);

    await tester.tap(find.byKey(const Key('format_picker_less')));
    await tester.pump();
    expect(find.byKey(const Key('format_chip_mkv_h264')), findsNothing);
  });

  testWidgets('a selection hidden behind "更多" stays visible', (tester) async {
    // Choosing MKV must not make the picker collapse to a set of chips that
    // no longer includes the current choice.
    await _pump(tester, selected: formatById('mkv_h264'));
    expect(find.byKey(const Key('format_chip_mkv_h264')), findsOneWidget);
  });

  testWidgets('tapping a format reports it', (tester) async {
    FormatSpec? picked;
    await _pump(tester, onSelected: (f) => picked = f);
    await tester.tap(find.byKey(const Key('format_chip_webm_vp9')));
    await tester.pump();
    expect(picked?.id, 'webm_vp9');
  });

  testWidgets('a format the build cannot write is disabled, not hidden',
      (tester) async {
    // A build without x265: H.265 stays on screen but is not selectable.
    await _pump(tester, available: const {'libx264', 'libvpx-vp9', 'mp4'});
    final h265 = tester
        .widget<ChoiceChip>(find.byKey(const Key('format_chip_mp4_h265')));
    expect(h265.onSelected, isNull);
    final h264 = tester
        .widget<ChoiceChip>(find.byKey(const Key('format_chip_mp4_h264')));
    expect(h264.onSelected, isNotNull);
  });
}
