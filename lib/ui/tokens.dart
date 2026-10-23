// SPDX-License-Identifier: GPL-3.0-or-later

/// The spacing, corner and motion scale every surface shares.
///
/// Before this file the screens mixed 12/14/16 radii, 8/12/16 gaps and
/// 150/160/180 ms animations, which is why the app read as "assembled" rather
/// than designed. Everything new should come from here.
library tokens;

import 'package:flutter/material.dart';

class Insets {
  const Insets._();

  /// 4-step scale. Anything not on it is a smell.
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page padding: one value for every screen.
  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: lg);
}

class Radii {
  const Radii._();

  static const double chip = 10;
  static const double control = 14;
  static const double card = 16;
  static const double sheet = 24;
  static const double pill = 999;

  static const BorderRadius chipAll = BorderRadius.all(Radius.circular(chip));
  static const BorderRadius controlAll =
      BorderRadius.all(Radius.circular(control));
  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));
}

class Motion {
  const Motion._();

  /// Taps and hovers: fast enough to feel instant.
  static const Duration press = Duration(milliseconds: 110);

  /// State changes inside a screen (chips, cards appearing).
  static const Duration quick = Duration(milliseconds: 180);

  /// Layout changes (a panel opening, a result card arriving).
  static const Duration medium = Duration(milliseconds: 260);

  /// Page transitions.
  static const Duration page = Duration(milliseconds: 320);

  /// Entrances that play once, per item, staggered by [stagger].
  static const Duration entrance = Duration(milliseconds: 520);
  static const Duration stagger = Duration(milliseconds: 60);

  /// A page arriving after a tab switch or a swipe.
  static const Duration pageReveal = Duration(milliseconds: 420);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve standard = Curves.easeOut;
}

/// A tap target that shrinks slightly while pressed.
///
/// Material's ink splash is easy to miss on a pale background; a 3% scale is
/// felt rather than seen, and it is what makes the grid feel alive.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final BorderRadius? borderRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Motion.press,
        curve: Motion.standard,
        child: widget.child,
      ),
    );
  }
}

/// Fades and lifts its child in once, used for list entrances.
class EnterOnce extends StatelessWidget {
  const EnterOnce({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 12,
  });

  final Widget child;
  final Duration delay;
  final double offset;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.entrance,
      curve: Interval(
        // The delay is expressed as part of the same tween so a rebuild does
        // not restart the animation.
        (delay.inMilliseconds / (Motion.entrance.inMilliseconds + 1))
            .clamp(0.0, 0.6),
        1,
        curve: Motion.enter,
      ),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * offset),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Replays a fade-and-lift every time [active] turns true.
///
/// The home pager keeps its pages alive, so a PageView switch would otherwise
/// change content with no transition at all -- the "functions just pop out"
/// report. Each page owns its controller, so the replay is local.
class PageReveal extends StatefulWidget {
  const PageReveal({
    super.key,
    required this.active,
    required this.child,
    this.duration = Motion.pageReveal,
    this.offset = 18,
  });

  final bool active;
  final Widget child;
  final Duration duration;

  /// How far the content rises as it fades in.
  final double offset;

  @override
  State<PageReveal> createState() => _PageRevealState();
}

class _PageRevealState extends State<PageReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.active ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutQuart,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.forward();
  }

  @override
  void didUpdateWidget(covariant PageReveal old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _controller.forward(from: 0);
    if (widget.duration != old.duration) _controller.duration = widget.duration;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, widget.offset / 400),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
      ),
    );
  }
}
