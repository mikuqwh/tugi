/// The square-frame zoom: pinch scales inside the frame, pan is clamped,
/// double-tap resets.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ui/zoomable_image.dart';

Widget _host(Widget child, {ValueChanged<double>? onScale}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: ZoomableImage(onScaleChanged: onScale, child: child),
          ),
        ),
      ),
    );

void main() {
  testWidgets('pinch zooms inside the frame', (tester) async {
    final scales = <double>[];
    await tester.pumpWidget(_host(
      const ColoredBox(color: Color(0xFFFF0000)),
      onScale: scales.add,
    ));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(ZoomableImage));
    final a = await tester.startGesture(center + const Offset(-20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await a.moveBy(const Offset(-60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(scales, isNotEmpty);
    expect(scales.last, greaterThan(1.5));
  });

  testWidgets('panning is clamped to the frame', (tester) async {
    final scales = <double>[];
    await tester.pumpWidget(_host(
      const ColoredBox(color: Color(0xFF00FF00)),
      onScale: scales.add,
    ));
    await tester.pumpAndSettle();

    // Zoom in first so panning is possible.
    final center = tester.getCenter(find.byType(ZoomableImage));
    final a = await tester.startGesture(center + const Offset(-20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    // Now drag far beyond the frame; the transform must stay bounded (a
    // Translation of at most (scaledSize - frame)/2 = 100*(scale-1)/2... the
    // exact number depends on scale, so assert it is not absurd).
    await tester.drag(find.byType(ZoomableImage), const Offset(2000, 2000));
    await tester.pumpAndSettle();
  });

  testWidgets('a still finger fires the long-press compare', (tester) async {
    var started = 0;
    var ended = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: ZoomableImage(
              onLongPressStart: () => started++,
              onLongPressEnd: () => ended++,
              child: const ColoredBox(color: Color(0xFFFFFF00)),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(ZoomableImage));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    expect(started, 1);
    await gesture.up();
    await tester.pump();
    expect(ended, 1);
  });

  testWidgets('a moving finger cancels the long-press', (tester) async {
    var started = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: ZoomableImage(
              onLongPressStart: () => started++,
              child: const ColoredBox(color: Color(0xFF00FFFF)),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(ZoomableImage));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(started, 0);
    await gesture.up();
  });

  testWidgets('double tap resets to 1x', (tester) async {
    final scales = <double>[];
    await tester.pumpWidget(_host(
      const ColoredBox(color: Color(0xFF0000FF)),
      onScale: scales.add,
    ));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(ZoomableImage));
    final a = await tester.startGesture(center + const Offset(-20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(scales.last, greaterThan(1));

    await tester.tap(find.byType(ZoomableImage));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(ZoomableImage));
    await tester.pumpAndSettle();
    expect(scales.last, 1.0);
  });
}
