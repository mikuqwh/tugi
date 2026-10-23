// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/models/encode_preset.dart';
import 'package:tugi/ui/encode_preset_picker.dart';

void main() {
  group('EncodePreset', () {
    test('fast trades colours and dithering for speed', () {
      final fast = EncodePreset.fast.gifPaletteTail;
      expect(fast, contains('max_colors=128'));
      expect(fast, contains('dither=bayer:bayer_scale=5'));
      expect(fast, contains('stats_mode=single'));
    });

    test('balanced keeps the established chain', () {
      final balanced = EncodePreset.balanced.gifPaletteTail;
      expect(balanced, contains('max_colors=256'));
      expect(balanced, contains('dither=sierra2_4a'));
      expect(balanced, contains('stats_mode=single'));
      expect(balanced, startsWith('split[s1][s2];'));
    });

    test('high searches the whole segment for the palette', () {
      final high = EncodePreset.high.gifPaletteTail;
      expect(high, contains('stats_mode=full'));
      expect(high, contains('dither=sierra2_4a'));
    });

    test('the transparency chain keeps its default stats mode when balanced',
        () {
      // This path shipped without an explicit stats_mode; changing it would
      // silently alter every Edit GIF output.
      expect(EncodePreset.balanced.gifTransparentTail,
          isNot(contains('stats_mode')));
      expect(
          EncodePreset.fast.gifTransparentTail, contains('stats_mode=single'));
      expect(EncodePreset.high.gifTransparentTail, contains('stats_mode=full'));
      expect(EncodePreset.balanced.gifTransparentTail,
          contains('reserve_transparent=on'));
    });

    test('video presets get slower and better', () {
      expect(EncodePreset.fast.videoPreset, 'ultrafast');
      expect(EncodePreset.high.videoPreset, 'medium');
      expect(EncodePreset.high.videoCrf, lessThan(EncodePreset.fast.videoCrf));
    });
  });

  group('EncodePresetPicker', () {
    testWidgets('renders three choices and reports taps', (tester) async {
      EncodePreset? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EncodePresetPicker(
            value: EncodePreset.balanced,
            accent: Colors.pink,
            onChanged: (p) => picked = p,
          ),
        ),
      ));
      for (final preset in EncodePreset.values) {
        expect(find.byKey(Key('encode_${preset.name}')), findsOneWidget);
      }
      expect(find.text('快速'), findsOneWidget);
      expect(find.text('均衡'), findsOneWidget);
      expect(find.text('高质量'), findsOneWidget);

      await tester.tap(find.byKey(const Key('encode_high')));
      expect(picked, EncodePreset.high);
    });

    testWidgets('disabled does not report taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EncodePresetPicker(
            value: EncodePreset.balanced,
            accent: Colors.pink,
            enabled: false,
            onChanged: (_) => taps++,
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('encode_fast')));
      expect(taps, 0);
    });
  });
}
