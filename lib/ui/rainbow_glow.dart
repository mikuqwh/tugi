/// The animated rainbow edge that marks a primary action.
///
/// Brand spec (§9.3): only two places may carry it -- the main CTA of a screen
/// and a key container's border -- and only ONE per screen. Everywhere else it
/// would read as decoration, and a page full of moving borders looks cheap.
///
/// Implementation notes worth keeping:
///
///  * The animation drives a single `AnimationController` and repaints a
///    `CustomPainter`; it does NOT rebuild the child. A `RepaintBoundary`
///    keeps the button's own paint out of the loop.
///  * `MediaQuery.disableAnimations` (battery saver, "remove animations"
///    accessibility setting) turns it into a STATIC gradient instead of
///    freezing it mid-sweep.
///  * The glow is a stroked round-rect with a small blur, painted three times
///    at decreasing alpha. A real bloom would need a saveLayer per frame; this
///    stays cheap enough to sit on a button.
// SPDX-License-Identifier: GPL-3.0-or-later

library rainbow_glow;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme_settings.dart';

/// The spectrum, in the order it travels around the border.
const List<Color> rainbowColors = [
  Color(0xFF4285F4), // blue
  Color(0xFF12B5A6), // teal
  Color(0xFF34A853), // green
  Color(0xFFFBBC05), // yellow
  Color(0xFFEA4335), // red
  Color(0xFFAF52DE), // violet
  Color(0xFF4285F4), // back to blue, so the sweep has no seam
];

class RainbowGlow extends StatefulWidget {
  const RainbowGlow({
    super.key,
    required this.child,
    this.radius = 16,
    this.stroke = 2,
    this.glow = 0.55,
    this.period = const Duration(milliseconds: 3600),
  });

  final Widget child;
  final double radius;
  final double stroke;

  /// How far the blur spreads; 0 disables the glow (border only).
  final double glow;

  final Duration period;

  @override
  State<RainbowGlow> createState() => _RainbowGlowState();
}

class _RainbowGlowState extends State<RainbowGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  bool _animating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion OR the user's 动效 switch: show the gradient, do not
    // move it.
    final reduce = (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
        !ThemeSettingsController.instance.value.motion;
    if (reduce && _animating) {
      _controller.stop();
      _animating = false;
    } else if (!reduce && !_animating) {
      _controller.repeat();
      _animating = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gap = widget.stroke + widget.glow;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        // The builder runs once per frame but only the painter's parameter
        // changes; the child widget is passed through untouched.
        builder: (context, child) => CustomPaint(
          painter: _RainbowPainter(
            t: _animating ? _controller.value : 0,
            radius: widget.radius,
            stroke: widget.stroke,
            glow: widget.glow,
          ),
          child: child,
        ),
        child: Padding(
          padding: EdgeInsets.all(gap),
          child: widget.child,
        ),
      ),
    );
  }
}

class _RainbowPainter extends CustomPainter {
  _RainbowPainter({
    required this.t,
    required this.radius,
    required this.stroke,
    required this.glow,
  });

  final double t;
  final double radius;
  final double stroke;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(stroke / 2),
      Radius.circular(radius),
    );

    // The sweep starts at the top and rotates once per period.
    final matrix = GradientRotation(t * 2 * math.pi);
    final gradient = SweepGradient(
      colors: rainbowColors,
      transform: matrix,
    ).createShader(rect);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..shader = gradient;

    if (glow > 0) {
      for (var i = 0; i < 3; i++) {
        final spread = glow * (i + 1) / 3;
        // A shader overrides `color`, so the halo needs its OWN translucent
        // gradient rather than an alpha on the same one.
        final halo = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke + spread * 2
          ..shader = SweepGradient(
            colors: [
              for (final c in rainbowColors) c.withValues(alpha: 0.30),
            ],
            transform: matrix,
          ).createShader(rect)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, spread);
        canvas.drawRRect(rrect, halo);
      }
    }
    canvas.drawRRect(rrect, border);
  }

  @override
  bool shouldRepaint(_RainbowPainter old) =>
      old.t != t ||
      old.radius != radius ||
      old.stroke != stroke ||
      old.glow != glow;
}
