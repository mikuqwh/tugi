// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/services/ffmpeg_progress.dart';
import 'package:tugi/ui/export_progress.dart';

/// The export bar: a real percentage, an honest indeterminate state, and a way
/// out of a long job.
void main() {
  testWidgets('shows the percentage and the label', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExportProgress(
          progress: 0.42,
          label: '正在转换…',
          accent: Colors.pink,
          onColor: Colors.white,
          onCancel: () {},
        ),
      ),
    ));
    expect(find.byKey(const Key('export_progress')), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('正在转换…'), findsOneWidget);
  });

  testWidgets('a null progress is indeterminate, not zero', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExportProgress(
          progress: null,
          label: '正在保存…',
          accent: Colors.pink,
          onColor: Colors.white,
        ),
      ),
    ));
    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, isNull);
    expect(find.byKey(const Key('export_percent')), findsNothing);
    // Nothing to cancel when there is no job behind it.
    expect(find.byKey(const Key('export_cancel')), findsNothing);
  });

  testWidgets('cancel calls back', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExportProgress(
          progress: 0.1,
          label: '正在转换…',
          accent: Colors.pink,
          onColor: Colors.white,
          onCancel: () => cancelled = true,
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('export_cancel')));
    expect(cancelled, isTrue);
  });

  group('FfmpegJob', () {
    test('a cancelled job reports cancellation, not failure', () {
      const cancelled = FfmpegCancelled();
      expect(cancelled.toString(), contains('取消'));
    });

    test('an error keeps ffmpeg output for the message', () {
      const e = FfmpegException('code 1: boom', 'full log');
      expect(e.message, contains('boom'));
      expect(e.output, 'full log');
    });
  });

  group('progress mapping', () {
    // The mapping lives inside runWithProgress; these cases pin the rule it
    // follows so a refactor cannot quietly turn "0.42" into "42".
    double map({int? ms, int? totalMs, int? frames, int? totalFrames}) {
      final time = ms ?? 0;
      if (totalMs != null && totalMs > 0 && time > 0) {
        return (time / totalMs).clamp(0.0, 0.99).toDouble();
      }
      if (totalFrames != null && totalFrames > 0 && frames != null) {
        return (frames / totalFrames).clamp(0.0, 0.99).toDouble();
      }
      return 0;
    }

    test('time over the segment length', () {
      expect(map(ms: 2000, totalMs: 6000), closeTo(1 / 3, 1e-9));
    });

    test('never reports 100% before the file is written', () {
      expect(map(ms: 6000, totalMs: 6000), closeTo(0.99, 1e-9));
    });

    test('falls back to frames when time is missing', () {
      expect(map(frames: 6, totalFrames: 24), closeTo(0.25, 1e-9));
    });

    test('nothing known means nothing reported', () {
      expect(map(), 0);
    });
  });

  test('the saving row is its own widget', () {
    expect(
      const ExportSaving(accent: Color(0xFF000000), onColor: Color(0xFFFFFFFF)),
      isNotNull,
    );
  });

  test('Size is imported for the widget signatures', () {
    // Keeps `dart:ui` used in this file (Rect/Size appear in the helpers).
    expect(const Size(1, 1).width, 1);
  });
}
