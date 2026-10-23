// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/format_convert_screen.dart';
import 'package:tugi/screens/images_to_gif_screen.dart';
import 'package:tugi/ui/feature_catalog.dart';

/// "Not ready" must be a pale button, not a dark one that looks clickable.
///
/// The bug was that these screens left `onPressed` non-null with no input, so
/// the accent colour painted at full strength and the button only did nothing
/// when tapped.
void main() {
  Widget app(Widget child) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: child,
      );

  testWidgets('Images to GIF is pale with no images', (tester) async {
    await tester.pumpWidget(app(const ImagesToGifScreen()));
    await tester.pumpAndSettle();

    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('转换为 GIF'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull, reason: 'no images yet');

    final colour = button.style?.backgroundColor?.resolve({
      WidgetState.disabled,
    });
    expect(colour, isNotNull);
    expect(colour!.a, lessThan(0.5), reason: 'disabled must be pale');
  });

  testWidgets('Format Convert shows no run button until a file is picked',
      (tester) async {
    // This screen's run button is inside the "file loaded" section, so the
    // honest assertion is that it is not there yet -- not that it is pale.
    await tester.pumpWidget(app(const FormatConvertScreen()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('convert_run')), findsNothing);
  });
}
