// SPDX-License-Identifier: GPL-3.0-or-later

/// The rainbow edge: present, animated, and graceful when animations are off.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ui/rainbow_glow.dart';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
          ),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

void main() {
  testWidgets('paints around its child and keeps the child interactive',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(
      RainbowGlow(
        child: ElevatedButton(
          onPressed: () => taps++,
          child: const Text('Go'),
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(RainbowGlow), findsOneWidget);
    expect(find.text('Go'), findsOneWidget);

    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('animates continuously while enabled', (tester) async {
    await tester.pumpWidget(_host(
      RainbowGlow(
          child: ElevatedButton(onPressed: () {}, child: const Text('Go'))),
    ));
    // A repeating animation schedules a frame forever: pumpAndSettle cannot
    // finish, which is exactly how "it is animating" is observable.
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('reduced motion freezes the gradient instead of hiding it',
      (tester) async {
    await tester.pumpWidget(_host(
      RainbowGlow(
          child: ElevatedButton(onPressed: () {}, child: const Text('Go'))),
      disableAnimations: true,
    ));
    // No pending animation means pumpAndSettle returns.
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    // The border is still painted (the CustomPaint is present).
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('the child is not rebuilt every frame', (tester) async {
    var builds = 0;
    await tester.pumpWidget(_host(
      RainbowGlow(
        child: Builder(builder: (_) {
          builds++;
          return const SizedBox(width: 80, height: 40);
        }),
      ),
    ));
    final first = builds;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // The AnimatedBuilder passes its child through; only the painter runs.
    expect(builds, first);
  });
}
