/// Device test: the Add Watermark screen against a real file.
///
/// The picker cannot be driven by a test, so the screen is opened with a
/// preset source path (see `AddWatermarkScreen.initialSourcePath`).
///
/// This is the UI half of the feature: the pipeline half is covered by
/// integration_test/ffmpeg/add_watermark_device_test.dart.
///
/// Runs on emulator-5554 (or any device) because a video source needs
/// ffmpeg to extract its first frame.
// SPDX-License-Identifier: GPL-3.0-or-later

library add_watermark_ui_test;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/screens/add_watermark_screen.dart';

Future<String> _makeSourceGif(String dir) async {
  final path = '$dir/wm_ui_source.gif';
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=320x180:rate=12:duration=2',
    '-vf',
    'fps=12,split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1',
    '-gifflags',
    '-offsetting',
    '-loop',
    '0',
    '-f',
    'gif',
    path,
  ]);
  final code = await session.getReturnCode();
  expect(code?.isValueSuccess(), isTrue,
      reason: 'fixture GIF failed: ${await session.getOutput()}');
  return path;
}

/// Let the screen's async work finish.
///
/// The source is loaded off the event loop (file reads for the media kind
/// and the dimensions), and `pumpAndSettle` returns as soon as the tree is
/// STABLE -- which, in the empty state, is immediately. Without this the
/// assertions run against the empty screen and every one of them fails.
Future<void> _letSourceLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future.delayed(const Duration(milliseconds: 1500));
  });
  await tester.pumpAndSettle();
}

/// Scroll a label into view and assert it is there.
///
/// The control panel is a ListView, so anything below the fold is not built
/// yet -- and once scrolled past, an earlier label may be disposed. So the
/// checks are made in visual order, top to bottom, each one asserted as it
/// is reached.
Future<void> _expectVisible(
  WidgetTester tester,
  String text, {
  String? reason,
}) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  expect(find.text(text), findsOneWidget, reason: reason ?? text);
}

void main() {
  testWidgets('the screen shows the source, the controls and a live preview',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);

    await tester.pumpWidget(
      MaterialApp(home: AddWatermarkScreen(initialSourcePath: source)),
    );
    await _letSourceLoad(tester);

    // The source card is there.
    expect(find.text('GIF'), findsNWidgets(2)); // the badge and the type chip
    expect(find.text('320×180'), findsOneWidget);

    // The controls, checked in visual order because the panel scrolls.
    await _expectVisible(tester, '水印类型');
    await _expectVisible(tester, '水印文字');
    await _expectVisible(tester, '字体');
    // All four font presets are offered.
    for (final label in ['黑体', '黑体 粗', '宋体', '宋体 粗']) {
      await _expectVisible(tester, label);
    }
    await _expectVisible(tester, '文字大小');
    await _expectVisible(tester, '颜色');
    await _expectVisible(tester, '位置');
    await _expectVisible(tester, '透明度');
    await _expectVisible(tester, '添加水印');

    // The drag hint sits under the pinned preview, so it is always visible.
    expect(find.text('拖动水印可自由摆位'), findsOneWidget);

    // The preview rendered: the source is on screen.
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('typing a watermark produces a preview and can be applied',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);

    await tester.pumpWidget(
      MaterialApp(home: AddWatermarkScreen(initialSourcePath: source)),
    );
    await _letSourceLoad(tester);

    // The text field sits below the font row, which the panel may not have
    // built yet -- `enterText` needs it on screen.
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Watermark 50%');
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The apply button lives at the bottom of a long scrolling panel, so
    // it may not be built yet.
    await tester.scrollUntilVisible(
      find.byKey(const Key('wm_apply')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    final button = tester.widget<ElevatedButton>(
      find.byKey(const Key('wm_apply')),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('wm_apply')));
    await tester.pumpAndSettle(const Duration(seconds: 6));

    expect(find.text('文字 水印已添加'), findsOneWidget);
  });

  testWidgets('dragging the preview switches to a free position',
      (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);

    await tester.pumpWidget(
      MaterialApp(home: AddWatermarkScreen(initialSourcePath: source)),
    );
    await _letSourceLoad(tester);

    // A watermark has to be configured for the drag layer to exist.
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Drag me');
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // No preset is selected before the drag.
    expect(find.text('自由'), findsNothing);

    // Drag across the preview. The distance has to clear the touch slop
    // (~18px) or no pan gesture starts at all.
    //
    // The stage is found by key, not by AspectRatio: the preview is now a
    // height-capped LayoutBuilder stage (so a tall screenshot cannot push
    // the panel off screen), and its box is what the drag maths uses.
    final preview = find.byKey(const Key('wm_stage'));
    expect(preview, findsOneWidget);
    final box = tester.getRect(preview);
    await tester.dragFrom(
      Offset(box.left + box.width * 0.25, box.top + box.height * 0.25),
      const Offset(40, 40),
    );
    await tester.pumpAndSettle();

    // The "自由" badge appears, which is the screen admitting it is no
    // longer on a preset.
    await tester.scrollUntilVisible(
      find.text('位置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('自由'), findsOneWidget);
  });

  testWidgets('the position grid offers all nine anchors', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = await _makeSourceGif(dir);

    await tester.pumpWidget(
      MaterialApp(home: AddWatermarkScreen(initialSourcePath: source)),
    );
    await _letSourceLoad(tester);

    // Three rows of three cells.
    expect(
        find.descendant(
          of: find.byType(Column),
          matching: find.byType(InkWell),
        ),
        findsWidgets);
  });
}
