/// The app-wide background, painted once behind the Navigator.
///
/// Before this existed the background only lived on the home screen, so
/// opening a feature dropped you onto flat white. The root now owns it and
/// every Scaffold is transparent, which also means the colour keeps flowing
/// while a feature is open instead of restarting.
// SPDX-License-Identifier: GPL-3.0-or-later

library app_background;

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'flow_background.dart';
import 'theme_settings.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeSettingsController.instance,
      builder: (context, _) {
        final settings = ThemeSettingsController.instance.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            switch (settings.background) {
              // The chosen colour IS the background: that is what "theme
              // colour" means to the user, not a tint on white.
              BackgroundStyle.plain => DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      settings.accentColor.withValues(
                        alpha: settings.backgroundOpacity,
                      ),
                      Neutrals.bg,
                    ),
                  ),
                ),
              BackgroundStyle.flow => FlowBackground(
                  color: settings.accentColor,
                  opacity: settings.backgroundOpacity,
                  animate: settings.motion,
                ),
              BackgroundStyle.image => Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Neutrals.bg),
                    if (settings.backgroundImage != null)
                      Opacity(
                        opacity: settings.imageOpacity,
                        child: Image(
                          image: settings.backgroundImage!,
                          fit: BoxFit.cover,
                        ),
                      ),
                  ],
                ),
            },
            child,
          ],
        );
      },
    );
  }
}
