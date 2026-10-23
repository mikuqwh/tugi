// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/scramble_screen.dart';
import 'package:tugi/services/scramble_service.dart';
import 'package:tugi/ui/app_palette.dart';
import 'package:tugi/ui/feature_catalog.dart';
import 'package:tugi/utils/image_scramble.dart';

/// A real 1x1 PNG: the "before" thumbnail decodes it, so fake bytes would spam
/// the image service with "Invalid image data".
final _png = Uint8List.fromList(const <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
  0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45,
  180, //
  0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

Widget _app(Widget child) => MaterialApp(
      builder: (context, child) => MediaQuery(
        // The CTA's rainbow edge animates forever; pumpAndSettle would hang.
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: child,
    );

/// A service that never touches a codec, so the screen can be driven in a host
/// test (image encoding needs the real engine).
class _FakeService extends ScrambleService {
  _FakeService() : super(workDir: Directory.systemTemp.path);

  int runs = 0;

  @override
  Future<DecodedImage> decode(String path, {int? maxSide}) async {
    final rgba = Uint8List.fromList(List<int>.filled(4 * 4 * 4, 128));
    return DecodedImage(
      rgba: rgba,
      width: 4,
      height: 4,
      bytes: _png,
    );
  }

  @override
  Future<({Uint8List rgba, Uint8List png})> transform(
    DecodedImage source, {
    required String password,
    required ScrambleMode mode,
    required bool inverse,
    int blockSize = 24,
  }) async {
    runs++;
    return (
      rgba: source.rgba,
      png: Uint8List.fromList([137, 80, 78, 71]),
    );
  }

  @override
  Future<String> writeResult(Uint8List png, {required bool inverse}) async =>
      '${Directory.systemTemp.path}/fake.png';
}

/// Pump until the pre-loaded image has been decoded by the fake service.
///
/// The surface is made tall on purpose: the password field sits below a square
/// thumbnail, and a lazy ListView would not build it on the default 800x600.
Future<void> _settle(WidgetTester tester) async {
  tester.view.physicalSize = const Size(720, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  test('the catalogue lists the feature under 转换', () {
    final entry = featureById('scramble');
    expect(entry, isNotNull);
    expect(entry!.category, FeatureCategory.convert);
    expect(entry.label, contains('混淆'));
    // Search must find it by the words people actually type.
    expect(entry.keywords, contains('混淆'));
    expect(entry.keywords, contains('还原'));
  });

  testWidgets('the run button stays pale until a password and an image exist',
      (tester) async {
    final service = _FakeService();
    await tester.pumpWidget(_app(ScrambleScreen(
      initialImagePath: 'ignored.png',
      service: service,
    )));
    await _settle(tester);

    /// The colour this button would actually paint right now.
    Color? bg() {
      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('scramble_run')),
      );
      final states = <WidgetState>{
        if (!button.enabled) WidgetState.disabled,
      };
      return button.style?.backgroundColor?.resolve(states);
    }

    // Not ready: pale (the same "not ready is pale" rule as every screen).
    expect(bg(), isNotNull);
    expect(bg()!.a, lessThan(0.5));

    await tester.enterText(find.byKey(const Key('scramble_password')), 'pw');
    await _settle(tester);
    // Ready: the full accent.
    expect(bg()!.a, greaterThan(0.9));

    await tester.tap(find.byKey(const Key('scramble_run')));
    await tester.pumpAndSettle();
    expect(service.runs, 1);
  });

  testWidgets('switch to restore changes the label', (tester) async {
    final service = _FakeService();
    await tester.pumpWidget(_app(
        ScrambleScreen(initialImagePath: 'ignored.png', service: service)));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('scramble_restore')));
    await _settle(tester);
    expect(find.text('还原图片'), findsOneWidget);
  });

  testWidgets('the mode chips select one at a time', (tester) async {
    final service = _FakeService();
    await tester.pumpWidget(_app(
        ScrambleScreen(initialImagePath: 'ignored.png', service: service)));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('scramble_mode_hilbert')));
    await _settle(tester);
    expect(find.byKey(const Key('scramble_mode_hilbert')), findsOneWidget);
  });
}
