// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/models/trim.dart';
import 'package:tugi/ui/trim_timeline.dart';

void main() {
  group('TrimRange', () {
    test('whole() covers the file and rejects a negative total', () {
      expect(TrimRange.whole(5.5), const TrimRange(start: 0, end: 5.5));
      expect(TrimRange.whole(-1), const TrimRange(start: 0, end: 0));
    });

    test('duration never goes negative', () {
      expect(const TrimRange(start: 3, end: 1).duration, 0);
      expect(const TrimRange(start: 1, end: 3).duration, 2);
    });

    test('json round-trips', () {
      const range = TrimRange(start: 1.25, end: 4.5);
      expect(TrimRange.fromJson(range.toJson()), range);
      expect(TrimRange.fromJson({'start': 'x'}), isNull);
    });
  });

  group('dragging', () {
    const range = TrimRange(start: 1, end: 4);

    test('the start handle stops one minimum before the end', () {
      final moved = dragStart(range, 10, 6);
      expect(moved.start, closeTo(4 - kMinTrimSeconds, 1e-9));
      expect(moved.end, 4);
    });

    test('the end handle stops one minimum after the start', () {
      final moved = dragEnd(range, 0, 6);
      expect(moved.end, closeTo(1 + kMinTrimSeconds, 1e-9));
    });

    test('handles are clamped to the file', () {
      expect(dragStart(range, -5, 6).start, 0);
      expect(dragEnd(range, 99, 6).end, 6);
    });
  });

  test('snapToFrame lands on a frame boundary', () {
    expect(snapToFrame(0.41, 10, 5), closeTo(0.4, 1e-9));
    expect(snapToFrame(0.46, 10, 5), closeTo(0.5, 1e-9));
    // Never past the end of the file.
    expect(snapToFrame(9, 10, 2), 2);
    // A zero rate is a no-op rather than a divide by zero.
    expect(snapToFrame(1.23, 0, 5), 1.23);
  });

  test('formatSeconds is stable around carries', () {
    expect(formatSeconds(0), '0.0s');
    expect(formatSeconds(3.4), '3.4s');
    expect(formatSeconds(59.96), '1:00.0');
    expect(formatSeconds(62.5), '1:02.5');
    expect(formatSeconds(-2), '0.0s');
  });

  group('TrimTimeline', () {
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

    testWidgets('shows the handles and the retained length', (tester) async {
      await pump(tester, (_) {});
      expect(find.byKey(const Key('trim_handle_start')), findsOneWidget);
      expect(find.byKey(const Key('trim_handle_end')), findsOneWidget);
      expect(find.text('保留 10.0s'), findsOneWidget);
    });

    testWidgets('dragging the start handle reports a later start',
        (tester) async {
      TrimRange? last;
      await pump(tester, (r) => last = r);
      await tester.drag(
        find.byKey(const Key('trim_handle_start')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect(last, isNotNull);
      expect(last!.start, greaterThan(0));
      expect(last!.end, 10);
    });
  });
}
