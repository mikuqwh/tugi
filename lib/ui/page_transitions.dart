/// Route transitions.
///
/// One transition for every drill-down, so opening a feature feels the same
/// everywhere: the incoming screen fades in while scaling up from 92%, the
/// outgoing one fades out (Material's "fade through", which `animations`
/// packages as [FadeThroughTransition]). It is shorter and calmer than the
/// default Android slide, and it does not fight the home's horizontal pager:
/// a left/right slide would read as another page swipe.
// SPDX-License-Identifier: GPL-3.0-or-later

library page_transitions;

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

/// Push [builder] with the app's standard transition.
Route<T> tugiRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      ),
    );

/// [FadeThroughTransition] for the pager itself: tab changes cross-fade
/// instead of sliding, which keeps the "one category at a time" feel.
class FadeThrough extends StatelessWidget {
  const FadeThrough({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: child,
      );
}
