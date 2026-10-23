// SPDX-License-Identifier: GPL-3.0-or-later

/// Add Watermark — screen structure.
///
/// An IMAGE source can be pumped on the host: `initialSourcePath` feeds the
/// screen directly, and `_loadSource` is pure Dart for images (byte
/// sniffing plus header parsing — only a video needs ffmpeg for its first
/// frame). The picker and the ffmpeg pipeline stay on the device, covered
/// by integration_test/ui/add_watermark_ui_test.dart.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/add_watermark_screen.dart';
import 'package:tugi/ui/app_palette.dart';

/// Reduced motion for the whole test: the primary CTA carries an animated
/// rainbow border, and a forever-repeating animation makes `pumpAndSettle`
/// hang. The animation itself is covered by test/ui/rainbow_glow_test.dart.
Widget _noAnimations(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

void main() {
  testWidgets('the empty state asks for a file', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(builder: _noAnimations, home: AddWatermarkScreen()));
    await tester.pump();

    expect(find.text('Add watermark'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('给 GIF、图片或视频加上水印'), findsOneWidget);
  });

  testWidgets('the empty state has no preview and no apply button',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(builder: _noAnimations, home: AddWatermarkScreen()));
    await tester.pump();

    expect(find.text('添加水印'), findsNothing);
    expect(find.text('位置'), findsNothing);
  });

  testWidgets('the app bar carries the feature accent', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(builder: _noAnimations, home: AddWatermarkScreen()));
    await tester.pump();

    // Since the palette rework the fill is a gradient, so the bar background
    // is transparent and the wash carries the feature's pair.
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, Colors.transparent);

    final wash = tester.widget<AccentGradientBackground>(
        find.byType(AccentGradientBackground));
    expect(wash.accent.base, FeatureColors.addWatermark);
    expect(wash.accent.tail, FeatureColors.addWatermarkTail);
  });

  testWidgets('a tall phone-screenshot source cannot swallow the screen',
      (tester) async {
    // The bug this guards: the preview was an AspectRatio forced to the
    // source's shape, so a 1080x2400 screenshot asked for a 2400-ish px tall
    // stage. The Column overflowed, `Expanded` handed the control panel zero
    // height, and nothing below the image could be dragged or tapped.
    await _pumpWithSource(tester, _writePng('tall', 1080, 2400));

    // Capped in HEIGHT — the same stage contract Edit Image uses — so the
    // width shrinks with the source's aspect ratio instead of the stage
    // growing to 2400-ish px.
    final stage = tester.getSize(find.byKey(const Key('wm_stage')));
    expect(stage.height, lessThanOrEqualTo(300));
    expect(stage.width / stage.height, closeTo(1080 / 2400, 0.01));

    // The panel below keeps a real, scrollable height.
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(150));
    // The caption under the stage stays on screen (600px tall surface).
    expect(tester.getTopLeft(find.text('拖动水印可自由摆位')).dy, lessThan(400));
  });

  testWidgets('a tall source fits a landscape screen too', (tester) async {
    // A landscape phone has ~360 logical px of height. A flat 300px stage
    // plus the app bar and the caption would leave the panel nothing — the
    // same overflow, one rotation later.
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await _pumpWithSource(tester, _writePng('tall_landscape', 1080, 2400));

    final stage = tester.getSize(find.byKey(const Key('wm_stage')));
    expect(stage.height, lessThan(360 * 0.5));
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(50));
  });

  testWidgets('the panel of a tall source still scrolls to the apply button',
      (tester) async {
    await _pumpWithSource(tester, _writePng('tall_scroll', 1080, 2400));

    // Under the bug the panel had no height to scroll inside, so this button
    // could never be reached.
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('wm_apply'));
    expect(button, findsOneWidget);
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(view.height));
  });

  testWidgets('the cap does not shrink a wide source', (tester) async {
    // The cap only bites on tall sources: a 4:1 panorama stays full width.
    await _pumpWithSource(tester, _writePng('wide', 2400, 600));

    final stage = tester.getSize(find.byKey(const Key('wm_stage')));
    expect(stage.width, closeTo(768, 0.5)); // 800 wide surface minus 16+16
    expect(stage.height, closeTo(768 / 4, 0.5));
  });

  testWidgets('the watermark is still draggable on a capped tall stage',
      (tester) async {
    // The point of the cap is that the panel works again; the point of the
    // preview is that placing the watermark still works. On a tall source
    // the stage is only ~135 logical px wide, so this is the case where a
    // shrink-to-fit frame could quietly break the drag.
    await _pumpWithSource(tester, _writePng('tall_drag', 1080, 2400));
    await _addWatermarkText(tester, 'WM');

    // No preset badge before the drag.
    expect(find.text('自由'), findsNothing);

    final resting = tester.getSize(_stage).height;

    // Hold the gesture so the in-flight sizes can be read: the stage grows
    // for as long as the watermark is under the finger.
    final gesture = await tester.startGesture(tester.getCenter(_stage));
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump(); // the target changes here; the animation is at t=0
    await tester.pump(const Duration(milliseconds: 60));
    final midway = tester.getSize(_stage).height;

    // One third into the transition the stage is somewhere between the two
    // caps: a jump cut would already be at the grown height by now.
    expect(midway, greaterThan(resting + 5));

    await tester.pumpAndSettle();
    final grown = tester.getSize(_stage).height;
    expect(grown, greaterThan(resting + 100));
    expect(midway, lessThan(grown - 5));
    // The panel gives the height up, but must stay usable (not overflowed).
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(20));

    await gesture.moveBy(const Offset(10, 10));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // Release puts the stage and the panel back -- also over an animation,
    // which `pumpAndSettle` has just run to completion.
    expect(tester.getSize(_stage).height, closeTo(resting, 0.5));
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(150));

    // The badge lives in the position section, which the ListView above may
    // have recycled while scrolled to the text field.
    await tester.scrollUntilVisible(
      find.text('位置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // The screen says it is no longer on a preset anchor.
    expect(find.text('自由'), findsOneWidget);
  });

  testWidgets('growing the stage on drag does not overflow a landscape screen',
      (tester) async {
    // Growing on drag is the risky half of the fix: it hands the stage more
    // height, and a landscape phone has very little to hand over.
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await _pumpWithSource(tester, _writePng('landscape_drag', 1080, 2400));
    await _addWatermarkText(tester, 'WM');

    final gesture = await tester.startGesture(tester.getCenter(_stage));
    await gesture.moveBy(const Offset(30, 30));
    // Run the growth animation to its end: the risky moment is the final
    // size, not the first frame of the transition.
    await tester.pumpAndSettle();

    // Still leaves a slice of the panel, and nothing overflowed (an overflow
    // would have been reported as a framework exception by now).
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(20));
    expect(tester.getSize(_stage).height, lessThan(360 * 0.7));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a second watermark can be added and edited independently',
      (tester) async {
    // The complaint this fixes: after picking a GIF watermark the panel only
    // offered 「更换」, so a second one had nowhere to go.
    await _pumpWithSource(tester, _writePng('multi', 1600, 1200));
    await _addWatermarkText(tester, 'A');

    expect(find.byKey(const Key('wm_layer_chip_0')), findsOneWidget);
    expect(find.byKey(const Key('wm_layer_chip_1')), findsNothing);

    await tester.tap(find.byKey(const Key('wm_add_layer')));
    await tester.pumpAndSettle();

    // Two chips, the new one selected and therefore empty: applying must
    // stay disabled until it has content.
    expect(find.byKey(const Key('wm_layer_chip_1')), findsOneWidget);
    expect(await _applyEnabled(tester), isFalse);

    await _addWatermarkText(tester, 'B');
    expect(await _applyEnabled(tester), isTrue);

    // Both layers are drawn in the preview at the same time.
    expect(
      find.descendant(of: _stage, matching: find.text('A')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _stage, matching: find.text('B')),
      findsOneWidget,
    );

    // Switching layers points the panel at that layer's own text.
    await _scrollToTop(tester);
    await tester.tap(find.byKey(const Key('wm_layer_chip_0')));
    await tester.pumpAndSettle();
    expect(await _textInField(tester), 'A');

    await _scrollToTop(tester);
    await tester.tap(find.byKey(const Key('wm_layer_chip_1')));
    await tester.pumpAndSettle();
    expect(await _textInField(tester), 'B');
  });

  testWidgets('two fingers zoom the preview without moving the mark',
      (tester) async {
    await _pumpWithSource(tester, _writePng('zoom', 600, 400));
    await _addWatermarkText(tester, 'WM');

    final stage = find.byKey(const Key('wm_stage'));
    final center = tester.getCenter(stage);
    final a = await tester.startGesture(center + const Offset(-15, 0));
    final b = await tester.startGesture(center + const Offset(15, 0));
    await tester.pump();
    await a.moveBy(const Offset(-40, 0));
    await b.moveBy(const Offset(40, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    final transform = tester.widget<Transform>(
      find.byKey(const Key('wm_stage_transform')),
    );
    expect(transform.transform.getMaxScaleOnAxis(), greaterThan(1.4));

    // One finger afterwards must still drag the mark, not pan the zoom: the
    // placement is what the export uses.
    final before = tester.getTopLeft(find.text('WM'));
    await tester.dragFrom(center, const Offset(-20, -20));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('WM')), isNot(before));
  });

  testWidgets('a layer can be removed, but not the last one', (tester) async {
    await _pumpWithSource(tester, _writePng('remove', 1600, 1200));
    await _addWatermarkText(tester, 'A');

    // With one layer there is no remove button at all.
    expect(find.byKey(const Key('wm_remove_layer_0')), findsNothing);

    await tester.tap(find.byKey(const Key('wm_add_layer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm_remove_layer_1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('wm_remove_layer_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm_layer_chip_1')), findsNothing);
    // The surviving layer keeps its content.
    expect(await _textInField(tester), 'A');
  });

  testWidgets('the layer list stops at six', (tester) async {
    await _pumpWithSource(tester, _writePng('cap', 1600, 1200));
    await _addWatermarkText(tester, 'A');
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const Key('wm_add_layer')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    // Six layers exist and the "continue adding" button is disabled, not
    // absent: the ceiling should be visible rather than mysterious.
    expect(find.byKey(const Key('wm_layer_chip_5')), findsOneWidget);
    expect(find.byKey(const Key('wm_layer_chip_6')), findsNothing);
    final add =
        tester.widget<TextButton>(find.byKey(const Key('wm_add_layer')));
    expect(add.onPressed, isNull);
  });

  testWidgets('switching the source keeps every watermark', (tester) async {
    // The batch contract: process one file, then the next, without
    // re-assembling the watermark. This is what 「继续下一个」 does once the
    // picker has answered.
    await _pumpWithSource(tester, _writePng('batch_a', 1600, 1200));
    await _addWatermarkText(tester, 'A');
    await tester.tap(find.byKey(const Key('wm_add_layer')));
    await tester.pumpAndSettle();
    await _addWatermarkText(tester, 'B');

    final dynamic state = tester.state(find.byType(AddWatermarkScreen));
    final second = _writePng('batch_b', 1200, 1600);
    // Real file I/O, so it has to run on a real event loop.
    await tester.runAsync(() => state.switchSourceForTest(second));
    await tester.pumpAndSettle();

    // Both layers survive, with their own text, and both still draw.
    expect(find.byKey(const Key('wm_layer_chip_1')), findsOneWidget);
    expect(
      find.descendant(of: _stage, matching: find.text('A')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _stage, matching: find.text('B')),
      findsOneWidget,
    );

    // The new source is what the card reports, so the swap really happened.
    expect(find.text('1200×1600'), findsOneWidget);
  });
}

final Finder _stage = find.byKey(const Key('wm_stage'));

/// Whether the apply button is tappable, scrolling the panel down to it.
Future<bool> _applyEnabled(WidgetTester tester) async {
  await _scrollToTop(tester);
  await tester.scrollUntilVisible(
    find.byKey(const Key('wm_apply')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  final button =
      tester.widget<ElevatedButton>(find.byKey(const Key('wm_apply')));
  return button.onPressed != null;
}

/// Read the text field's content, scrolling the panel to it first: the panel
/// is a lazy `ListView`, so an off-screen field is not in the tree at all.
Future<String> _textInField(WidgetTester tester) async {
  await _scrollToTop(tester);
  await tester.scrollUntilVisible(
    find.byKey(const Key('wm_text_field')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  return tester
      .widget<TextField>(find.byKey(const Key('wm_text_field')))
      .controller!
      .text;
}

/// Type a watermark into the selected layer's text field, which the panel
/// may have to scroll to first.
Future<void> _addWatermarkText(WidgetTester tester, String text) async {
  await _scrollToTop(tester);
  await tester.scrollUntilVisible(
    find.byKey(const Key('wm_text_field')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('wm_text_field')), text);
  await tester.pumpAndSettle();
  await _scrollToTop(tester);
}

/// Scroll the control panel back to its top, so the layer chips are built.
Future<void> _scrollToTop(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, 3000));
  await tester.pumpAndSettle();
}

/// Pump [AddWatermarkScreen] and load [path] through the screen's own load
/// path, then build the loaded state.
///
/// The load normally runs from a post-frame callback, and real file I/O
/// started in the fake async zone of `testWidgets` never completes — the test
/// would hang instead of failing. Driving the same method from inside
/// [WidgetTester.runAsync] puts it on a real event loop.
Future<void> _pumpWithSource(WidgetTester tester, String path) async {
  await tester.pumpWidget(
      const MaterialApp(builder: _noAnimations, home: AddWatermarkScreen()));
  // The state class is private to the screen; the seam is its only handle.
  final dynamic state = tester.state(find.byType(AddWatermarkScreen));
  await tester.runAsync(() async => await state.loadSourceForTest(path));
  await tester.pump();
}

/// Write a real, decodable PNG of the given size and return its path.
///
/// Synchronous on purpose: `await file.writeAsBytes(...)` inside a widget
/// test is the hang described above. The delete is best-effort because
/// `Image.file` may still hold the file open when the test ends.
String _writePng(String name, int width, int height) {
  final dir = Directory.systemTemp.createTempSync('wm_${name}_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the handle while the image cache holds the decoded file.
    }
  });
  final file = File('${dir.path}/$name.png');
  file.writeAsBytesSync(_solidPng(width: width, height: height));
  return file.path;
}

/// A minimal but fully valid solid-colour PNG, so `Image.file` decodes it for
/// real and the screen builds exactly what a picked screenshot builds.
///
/// Hand-rolled because the project has no image-writing dependency; the pixel
/// buffer is filled as bytes rather than built with list spreads, which is
/// several seconds slower on a 1080x2400 source.
Uint8List _solidPng({required int width, required int height}) {
  const poly = 0xEDB88320;
  final table = List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = c.isOdd ? poly ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  int crc32(List<int> bytes) {
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  final out = BytesBuilder();
  void chunk(String type, List<int> data) {
    out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    out.add(type.codeUnits);
    out.add(data);
    out.add((ByteData(4)
          ..setUint32(0, crc32(<int>[...type.codeUnits, ...data])))
        .buffer
        .asUint8List());
  }

  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // truecolour RGB
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter
    ..setUint8(12, 0); // interlace
  chunk('IHDR', ihdr.buffer.asUint8List());

  // One filter byte (None) followed by width RGB triples, per row.
  final stride = width * 3 + 1;
  final raw = Uint8List(stride * height);
  for (var y = 0; y < height; y++) {
    raw.fillRange(y * stride + 1, (y + 1) * stride, 0x66);
  }
  chunk('IDAT', ZLibCodec(level: 6).encode(raw));
  chunk('IEND', const <int>[]);
  return out.toBytes();
}
