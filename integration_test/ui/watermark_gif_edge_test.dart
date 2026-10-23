// SPDX-License-Identifier: GPL-3.0-or-later

/// Device-only: a GIF watermark must reach the frame edge.
///
/// The host test (`test/ui/watermark_clamp_test.dart`) pins the arithmetic; this
/// one proves the measured box the screen feeds into it is real, which needs a
/// decoder and therefore a device.
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tugi/screens/add_watermark_screen.dart';
import 'package:tugi/ui/app_background.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('gif watermark reaches the edge', (tester) async {
    final dir = (await getTemporaryDirectory()).path;
    final source = '$dir/clamp_src.jpg';
    final gif = '$dir/clamp_wm.gif';
    await FFmpegKit.executeWithArguments([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=640x480',
      '-frames:v',
      '1',
      source,
    ]);
    await FFmpegKit.executeWithArguments([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=96x96:rate=8:duration=1',
      '-f',
      'gif',
      gif,
    ]);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: AppBackground(child: child!),
      ),
      home: AddWatermarkScreen(
        initialSourcePath: source,
        initialGifWatermarkPath: gif,
      ),
    ));
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final state =
        tester.state<AddWatermarkScreenState>(find.byType(AddWatermarkScreen));
    // ignore: avoid_print
    print('WM before sizes=${state.debugLayerSizes} '
        'frame=${state.debugPreviewSize} places=${state.debugPlacements}');

    // Drag hard to the top-left corner, several times, so any remaining clamp
    // shows up as a stop short of the edge.
    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(const Key('wm_stage'))));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(-40, -40));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('WM after sizes=${state.debugLayerSizes} '
        'frame=${state.debugPreviewSize} places=${state.debugPlacements}');
    // The centre stops exactly half a box from the corner, i.e. the box's own
    // edge sits on the frame edge.
    final sizes = state.debugLayerSizes.single.split('x');
    final halfW = double.parse(sizes[0]) / 2 / state.debugPreviewSize.width;
    final halfH = double.parse(sizes[1]) / 2 / state.debugPreviewSize.height;
    final places = state.debugPlacements.single.split(',');
    expect(double.parse(places[0]), closeTo(halfW, 0.01));
    expect(double.parse(places[1]), closeTo(halfH, 0.01));
  });
}
