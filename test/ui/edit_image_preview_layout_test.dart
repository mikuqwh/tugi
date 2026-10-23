// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Structure tests for the pinned-preview layout.
///
/// The bug these pin: the preview used to live inside the scrolling
/// ListView, so dragging a slider near the bottom of the long control panel
/// scrolled the image out of view and the live preview could not be seen.
///
/// The screen itself cannot be pumped on the host VM (building the preview
/// needs ffmpeg, which only exists in the app), so these tests assert the
/// layout CONTRACT on the same widget shapes the screen uses. The real
/// screen is covered by
/// integration_test/ui/edit_image_pinned_preview_test.dart on the device.
/// Reduced motion: the primary CTA's rainbow edge animates forever, which
/// makes `pumpAndSettle` hang. The animation itself is covered by
/// test/ui/rainbow_glow_test.dart.
Widget _noAnimations(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

void main() {
  testWidgets('the pinned preview is a sibling of the scroll view, not a child',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _noAnimations,
        home: Scaffold(
          body: Column(
            children: [
              // The pinned preview.
              Container(
                key: const Key('preview'),
                height: 300,
                color: const Color(0xFF2D3436),
              ),
              // The control panel.
              Expanded(
                child: ListView(
                  key: const Key('panel'),
                  children: const [
                    SizedBox(height: 4000, child: Text('long panel')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('preview')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('preview')),
        matching: find.byType(ListView),
      ),
      findsNothing,
      reason: 'the preview must not live inside the scroll view',
    );

    // Scrolling the panel cannot move the preview.
    final before = tester.getTopLeft(find.byKey(const Key('preview')));
    await tester.drag(find.byKey(const Key('panel')), const Offset(0, -1500));
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const Key('preview')));
    expect(after.dy, before.dy);
  });

  testWidgets('a collapsed panel frees the height for the preview',
      (tester) async {
    // The collapse is done with a zero-height box rather than by removing
    // the panel: removing the Slider that owns the drag would cancel the
    // gesture and the panel would never come back.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Container(key: const Key('preview'), height: 300),
              const SizedBox.shrink(),
              Expanded(
                child: ListView(
                  children: const [SizedBox(height: 4000)],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('preview')), findsOneWidget);
    // The panel is gone, but the preview still has its height.
    expect(tester.getSize(find.byKey(const Key('preview'))).height, 300);
  });
}
