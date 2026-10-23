// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/models/crop_rect.dart';
import 'package:tugi/ui/crop_overlay.dart';

void main() {
  group('CropRect', () {
    test('whole is a no-op', () {
      expect(CropRect.whole.isWhole, isTrue);
      expect(CropRect.whole.toFilter(1920, 1080), isEmpty);
    });

    test('pixels are even and inside the frame', () {
      const rect = CropRect(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8);
      final p = rect.toPixels(1921, 1081);
      expect(p.w.isEven, isTrue);
      expect(p.h.isEven, isTrue);
      expect(p.x.isEven, isTrue);
      expect(p.y.isEven, isTrue);
      expect(p.x + p.w, lessThanOrEqualTo(1921));
      expect(p.y + p.h, lessThanOrEqualTo(1081));
    });

    test('a sliver still yields a usable size', () {
      const sliver = CropRect(left: 0.0, top: 0.0, right: 0.001, bottom: 0.001);
      final p = sliver.toPixels(1920, 1080);
      expect(p.w, greaterThanOrEqualTo(16));
      expect(p.h, greaterThanOrEqualTo(16));
    });

    test('toFilter prints crop=w:h:x:y', () {
      const rect = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75);
      expect(rect.toFilter(1000, 800), 'crop=500:400:250:200');
    });

    test('centredAspect fits inside the frame', () {
      final square = CropRect.centredAspect(1, frameAspect: 16 / 9);
      expect(square.width, closeTo(9 / 16, 0.01));
      // Full height: the square is limited by the frame's height.
      expect(square.top, 0);
      expect(square.bottom, 1);
      final wide = CropRect.centredAspect(32 / 9, frameAspect: 16 / 9);
      expect(wide.left, 0);
      expect(wide.right, 1);
    });

    test('withAspect keeps the centre and stays inside', () {
      const rect = CropRect(left: 0.2, top: 0.2, right: 0.8, bottom: 0.8);
      final squared = rect.withAspect(1, frameAspect: 16 / 9);
      expect((squared.left + squared.right) / 2, closeTo(0.5, 0.001));
      expect(squared.width, greaterThan(0));
      expect(squared.right, lessThanOrEqualTo(1));
    });

    test('json round-trips and rejects nonsense', () {
      const rect = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9);
      expect(CropRect.fromJson(rect.toJson()), rect);
      expect(
        CropRect.fromJson({'left': 0.9, 'top': 0, 'right': 0.1, 'bottom': 1}),
        isNull,
      );
      expect(CropRect.fromJson({'left': 'x'}), isNull);
    });
  });

  group('CropOverlay', () {
    Future<void> pump(WidgetTester tester, void Function(CropRect) onChange) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: CropOverlay(
                rect: CropRect.whole,
                accent: Colors.pink,
                onChanged: onChange,
              ),
            ),
          ),
        ),
      ));
    }

    testWidgets('exposes four corners and four edges', (tester) async {
      await pump(tester, (_) {});
      for (final name in ['topLeft', 'topRight', 'bottomLeft', 'bottomRight']) {
        expect(find.byKey(Key('crop_$name')), findsOneWidget);
      }
      for (final name in ['top', 'bottom', 'left', 'right']) {
        expect(find.byKey(Key('crop_edge_$name')), findsOneWidget);
      }
    });

    testWidgets('dragging a corner shrinks the rect', (tester) async {
      CropRect? last;
      await pump(tester, (r) => last = r);
      await tester.drag(
        find.byKey(const Key('crop_topLeft')),
        const Offset(40, 20),
      );
      await tester.pumpAndSettle();
      expect(last, isNotNull);
      expect(last!.left, greaterThan(0.02));
      expect(last!.top, greaterThan(0.01));
      expect(last!.right, 1);
    });

    testWidgets('dragging an edge only moves that edge', (tester) async {
      CropRect? last;
      await pump(tester, (r) => last = r);
      await tester.drag(
        find.byKey(const Key('crop_edge_right')),
        const Offset(-50, 0),
      );
      await tester.pumpAndSettle();
      expect(last, isNotNull);
      expect(last!.right, lessThan(1));
      expect(last!.left, 0);
      expect(last!.top, 0);
    });

    testWidgets('a locked aspect keeps the box square-ish', (tester) async {
      CropRect? last;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 320,
              child: CropOverlay(
                rect: CropRect.whole,
                aspect: 1,
                accent: Colors.pink,
                onChanged: (r) => last = r,
              ),
            ),
          ),
        ),
      ));
      await tester.drag(
        find.byKey(const Key('crop_topLeft')),
        const Offset(40, 10),
      );
      await tester.pumpAndSettle();
      expect(last, isNotNull);
      expect(last!.width, closeTo(last!.height, 0.02));
    });
  });
}
