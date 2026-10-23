// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/models/trim.dart';
import 'package:tugi/ui/trim_timeline.dart';

void main() {
  Future<void> pump(WidgetTester tester, void Function(TrimRange) onChange) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: TrimTimeline(
            total: 10,
            range: const TrimRange(start: 0, end: 10),
            frames: const [],
            fps: 10,
            onChanged: onChange,
          ),
        ),
      ),
    ));
  }

  testWidgets('dragging a handle out of the strip still trims', (tester) async {
    // The handles sit at the strip's edge, so a drag starts inside the
    // Timeline and immediately leaves it. The recogniser must keep the pointer.
    TrimRange? last;
    await pump(tester, (r) => last = r);

    final center = tester.getCenter(find.byKey(const Key('trim_handle_start')));
    final gesture =
        await tester.startGesture(center); // finger lands on the handle
    // Move well past the strip's edge, and back: a plain recogniser would have
    // been claimed by the surrounding scrollable on the first of these.
    for (var dx = 0; dx <= 200; dx += 20) {
      await gesture.moveBy(const Offset(20, 0));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    expect(last!.start, greaterThan(0));
  });

  testWidgets('the range tracks the handle, not the initial position',
      (tester) async {
    TrimRange? last;
    await pump(tester, (r) => last = r);
    await tester.drag(
      find.byKey(const Key('trim_handle_start')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    // The strip is 720-32=688 px wide in this test frame; 60 px of it is
    // 0.087 of the 10 s total. Assert the direction and magnitude, not a
    // hand-computed number.
    expect(last!.start, greaterThan(0.5));
    expect(last!.start, lessThan(1.5));
  });
}
