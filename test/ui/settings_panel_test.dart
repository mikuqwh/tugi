// SPDX-License-Identifier: GPL-3.0-or-later

/// The settings panel and the gesture zones that open it.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/feature_pager_screen.dart';
import 'package:tugi/screens/home_screen.dart';
import 'package:tugi/services/color_presets.dart';
import 'package:tugi/ui/theme_settings.dart';
import 'package:tugi/services/home_prefs.dart';
import 'package:tugi/ui/app_palette.dart';
import 'package:tugi/ui/feature_catalog.dart';
import 'package:tugi/ui/settings_panel.dart';
import 'package:tugi/ui/theme_settings.dart';

Widget _app(Widget home, {bool disableAnimations = true}) => MaterialApp(
      builder: (context, child) => SettingsHost(
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
      ),
      home: home,
    );

void main() {
  // The preview runs the flowing background; motion off keeps the test
  // animation-free (the flow itself is exercised by its own widget). The
  // background is the plain colour, not the app icon: an AssetImage needs a
  // real asset bundle, which the host test binding does not have.
  setUp(() => ThemeSettingsController.instance.update(
      const ThemeSettings(motion: false, background: BackgroundStyle.plain)));
  tearDown(
      () => ThemeSettingsController.instance.update(const ThemeSettings()));

  testWidgets('the gear opens the panel and the scrim closes it',
      (tester) async {
    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_panel')), findsNothing);

    await tester.tap(find.byKey(const Key('home_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings_panel')), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings_panel')), findsNothing);
  });

  testWidgets('a right-swipe in the TOP zone opens settings', (tester) async {
    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();

    // Start inside the header area (well above the cards).
    await tester.dragFrom(const Offset(120, 70), const Offset(180, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_panel')), findsOneWidget);
  });

  testWidgets('pulling the first page right opens settings', (tester) async {
    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();

    // Nothing is before 转换, so the overscroll means "settings".
    await tester.dragFrom(const Offset(120, 400), const Offset(220, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_panel')), findsOneWidget);
  });

  testWidgets('pulling a later page right just goes back, no settings',
      (tester) async {
    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_tab_1')));
    await tester.pumpAndSettle();

    await tester.dragFrom(const Offset(120, 400), const Offset(220, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_panel')), findsNothing);
  });

  testWidgets('background and accent choices update the controller',
      (tester) async {
    final original = ThemeSettingsController.instance.value;
    addTearDown(() => ThemeSettingsController.instance.update(original));

    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_settings')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings_bg_plain')));
    await tester.pumpAndSettle();
    expect(ThemeSettingsController.instance.value.background,
        BackgroundStyle.plain);

    await tester.ensureVisible(find.byKey(const Key('settings_accent_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_accent_2')));
    await tester.pumpAndSettle();
    expect(ThemeSettingsController.instance.value.accentValue,
        accentPresets[2].color.toARGB32());
  });

  testWidgets('the bottom strip of a feature page switches features',
      (tester) async {
    final entries = featuresIn(FeatureCategory.gif);
    await tester.pumpWidget(_app(
      FeaturePagerScreen(entries: entries, initialIndex: 0),
      disableAnimations: true,
    ));
    await tester.pumpAndSettle();

    // Page 0 is Video to GIF.
    expect(find.text('Video to GIF'), findsWidgets);

    await tester.tap(find.byKey(const Key('feature_next')));
    await tester.pumpAndSettle();
    expect(find.text('Images to GIF'), findsWidgets);

    // A leftward drag on the strip also advances.
    await tester.drag(
      find.byKey(const Key('feature_zone_strip')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit GIF'), findsWidgets);
  });

  testWidgets('dragging the strip right on the FIRST feature opens settings',
      (tester) async {
    final entries = featuresIn(FeatureCategory.gif);
    await tester.pumpWidget(_app(
      FeaturePagerScreen(entries: entries, initialIndex: 0),
      disableAnimations: true,
    ));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('feature_zone_strip')),
      const Offset(220, 0),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_panel')), findsOneWidget);
  });

  testWidgets('the custom-image tile stays tappable once an image is set',
      (tester) async {
    // Regression: the tile was a Container whose decoration IS the image, and
    // a decorated container does not hit test on its own, so replacing the
    // background looked dead after the first pick.
    final original = ThemeSettingsController.instance.value;
    // Not awaited: persisting goes through path_provider, whose channel never
    // answers inside a widget test, so awaiting it would hang. The in-memory
    // value is set synchronously.
    addTearDown(() {
      ThemeSettingsController.instance.update(original);
    });
    ThemeSettingsController.instance.update(const ThemeSettings(
      background: BackgroundStyle.image,
      customImagePath: '/tmp/does-not-matter.png',
    ));

    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_settings')));
    await tester.pumpAndSettle();

    final tile = tester.widget<GestureDetector>(
      find.byKey(const Key('settings_bg_import')),
    );
    expect(tile.behavior, HitTestBehavior.opaque);
    expect(tile.onTap, isNotNull);
  });

  testWidgets(
      'a right-drag while a text field is focused does not open settings',
      (tester) async {
    // The selection handle is a horizontal drag too; the top-zone recogniser
    // used to steal it and open the panel mid-selection.
    final controller = TextEditingController(text: 'watermark');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(Scaffold(
      body: Padding(
        padding: const EdgeInsets.only(top: 20),
        child: TextField(
          key: const Key('probe_field'),
          controller: controller,
          autofocus: true,
        ),
      ),
    )));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNotNull);

    await tester.dragFrom(const Offset(120, 40), const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings_panel')), findsNothing);
  });

  testWidgets('saved colours come with a delete hint', (tester) async {
    await tester.pumpWidget(_app(HomeScreen(prefs: MemoryHomePrefs())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_settings')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('settings_accent_custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_accent_custom')));
    await tester.pumpAndSettle();

    // Fire and forget for the same reason as above (persist is file I/O).
    ColorPresetStore.instance.add(const Color(0xFF123456));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings_saved_hint')),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings_saved_hint')), findsOneWidget);
    expect(find.text('长按已保存的颜色可以删除'), findsOneWidget);
  });

  test('the presets are deep enough to read as colours', () {
    expect(accentPresets.length, greaterThanOrEqualTo(4));
    for (final preset in accentPresets) {
      // A preset must not be a near-white tint: that was the complaint.
      expect(preset.color.computeLuminance(), lessThan(0.45),
          reason: preset.label);
      final on = accentFromColor(preset.color).on;
      final a = preset.color.computeLuminance();
      final b = on.computeLuminance();
      final hi = a > b ? a : b;
      final lo = a > b ? b : a;
      expect((hi + 0.05) / (lo + 0.05), greaterThan(3.0), reason: preset.label);
    }
  });

  test('settings migrate the old accentIndex and gradient name', () {
    final migrated = ThemeSettings.fromJson(const {
      'background': 'gradient',
      'accentIndex': 1,
    });
    expect(migrated.background, BackgroundStyle.flow);
    expect(migrated.accentValue, 0xFFE6005C);
  });
}
