// SPDX-License-Identifier: GPL-3.0-or-later

/// The one empty state every screen uses.
///
/// Before this, three screens had three different empty layouts (a sentence, a
/// centred column, an icon with a hint), which made the app feel unfinished
/// exactly where users first land.
library empty_state;

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.accent,
    this.action,
    this.onColor,
  });

  final IconData icon;
  final String title;
  final String hint;
  final Color? accent;
  final Widget? action;

  /// Text colour; defaults to the neutral ink for light backgrounds.
  final Color? onColor;

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? Neutrals.inkSoft;
    final text = onColor ?? Neutrals.ink;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: tint),
            ),
            const SizedBox(height: Insets.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: text,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: text.withValues(alpha: 0.72),
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: Insets.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A result block that fades and lifts in when it appears.
///
/// Results arrive after a long job; without a transition the screen jumps and
/// the eye cannot tell whether anything happened.
class ResultReveal extends StatelessWidget {
  const ResultReveal({super.key, required this.child, this.visible = true});

  final Widget child;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.medium,
      switchInCurve: Motion.enter,
      switchOutCurve: Motion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: visible
          ? KeyedSubtree(key: const ValueKey('result'), child: child)
          : const SizedBox.shrink(key: ValueKey('empty')),
    );
  }
}
