/// Tugi — the app shell.
///
/// The home screen, the feature catalog and the routes live outside this file
/// (see lib/screens/home_screen.dart and lib/ui/feature_catalog.dart); this
/// file only owns the MaterialApp and the theme.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';
import 'ui/app_background.dart';
import 'ui/app_palette.dart';
import 'ui/settings_panel.dart';
import 'services/color_presets.dart';
import 'services/works_service.dart';
import 'ui/theme_settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Prefs are file-backed; the first frame should not wait for them.
  ThemeSettingsController.instance.load();
  ColorPresetStore.instance.load();
  WorksService.instance.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tugi',
      // Without these the selection toolbar ("Copy", "Select all") stays in
      // English no matter what the device locale is.
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      locale: const Locale('zh', 'CN'),
      // No scaffold colour override: the palette sets it transparent so the
      // app background shows through every screen.
      theme: buildFeatureTheme(Accents.cyan),
      // The settings panel must live above the Navigator so it can cover any
      // screen, and the top-zone swipe works everywhere.
      builder: (context, child) => AppBackground(
        child: SettingsHost(child: child!),
      ),
      home: const HomeScreen(),
    );
  }
}
