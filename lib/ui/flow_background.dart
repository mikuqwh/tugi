/// The flowing colour background ("颜色流动").
///
/// This is a small mesh-gradient: a pale tint of the chosen colour, with six
/// large, heavily feathered blobs drifting on different Lissajous paths.
/// Reference implementations of the same idea:
///   * https://github.com/renancaraujo/omesh (vector animated mesh gradients)
///   * https://github.com/ben-fornefeld/mesh-gradient (fluid-like blobs)
///
/// Why not depend on one of those packages: the background is one widget with
/// no interaction, and a painter keeps it dependency-free and cheap (one
/// `CustomPaint`, no blur filter -- each blob is a radial gradient that
/// already fades to alpha 0).
///
/// The colours are GENERATED from the accent, not hand-picked: the accent
/// plus hue rotations of +34/-34/+68/-68 degrees and its complement. That is
/// what makes any chosen colour produce a palette that looks composed rather
/// than a single wash -- the old version only shifted lightness, which is why
/// it read as a flat colour.
// SPDX-License-Identifier: GPL-3.0-or-later

library flow_background;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';

/// The pale ground a flow background is painted on.
///
/// Shared with the theme so [ThemeSettings.onBackground] can decide between
/// white and ink from the colour that is actually behind the text.
Color flowGround(Color accent, double opacity) {
  // A 0.32 wash over white: pale enough that the blobs read as colour on top
  // of it, saturated enough that the page is clearly tinted.
  final pale = Color.alphaBlend(accent.withValues(alpha: 0.32), Colors.white);
  return Color.alphaBlend(
    pale.withValues(alpha: opacity.clamp(0.2, 1.0)),
    Neutrals.bg,
  );
}

class FlowBackground extends StatefulWidget {
  const FlowBackground({
    super.key,
    required this.color,
    this.opacity = 1.0,
    this.animate = true,
    this.period = const Duration(seconds: 26),
  });

  final Color color;

  /// 0.2..1.0: how strongly the whole field covers the neutral base.
  final double opacity;

  final bool animate;
  final Duration period;

  @override
  State<FlowBackground> createState() => _FlowBackgroundState();
}

class _FlowBackgroundState extends State<FlowBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.period);

  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(FlowBackground old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldRun = widget.animate && !reduce;
    if (shouldRun && !_running) {
      _controller.repeat();
      _running = true;
    } else if (!shouldRun && _running) {
      _controller.stop();
      _running = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Seconds since the animation started, never wrapping.
  ///
  /// `AnimationController.repeat()` resets `value` to 0 every period; that
  /// reset is a visible hiccup even when the shape maths match at the
  /// boundary. `lastElapsedDuration` is cumulative, and the sin/cos terms are
  /// periodic anyway, so the background never restarts at all.
  double get _seconds {
    final elapsed = _controller.lastElapsedDuration;
    if (elapsed == null) return 0;
    return elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          // The blobs are soft; half-resolution costs a quarter of the fill
          // rate and is indistinguishable after scaling back up.
          isComplex: true,
          willChange: true,
          painter: _FlowPainter(
            seconds: _seconds,
            base: widget.color,
            opacity: widget.opacity.clamp(0.2, 1.0),
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Where blob [i] sits at progress [t] (0..1 of one loop), in pixels.
///
/// Every frequency is an INTEGER multiple of 2π per loop. A half-integer
/// frequency lands the blob somewhere else at t = 1 than at t = 0, so the
/// `repeat()` jumps back to an unrelated frame -- that discontinuity is the
/// "flash" the animation used to have.
///
/// Integer frequencies still do not move in lockstep: the pairs below share no
/// common period smaller than the loop itself, and two summed harmonics keep
/// the path from reading as a plain ellipse.
@visibleForTesting
Offset flowBlobCenter(int i, double t, Size size) {
  const fx = <int>[1, 2, 2, 3, 1, 3];
  const fy = <int>[2, 1, 3, 1, 3, 2];
  // Phase offsets are radians: a constant shift never breaks the loop.
  final phase = i * 1.7;
  final second = i * 0.9;
  final angle = t * 2 * math.pi;

  final cx = 0.5 +
      0.30 * math.sin(angle * fx[i % fx.length] + phase) +
      0.10 * math.sin(angle * (fx[i % fx.length] + 2) + second);
  final cy = 0.5 +
      0.26 * math.cos(angle * fy[i % fy.length] + phase * 1.3) +
      0.10 * math.cos(angle * (fy[i % fy.length] + 2) + second * 1.4);
  return Offset(cx * size.width, cy * size.height);
}

/// Hue/alpha/lightness table for one accent. Recomputing HSL every frame is
/// pure waste at 60 fps.
class FlowPalette {
  FlowPalette(Color base) {
    final hsl = HSLColor.fromColor(base);
    final hues = <double>[
      hsl.hue,
      hsl.hue + 34,
      hsl.hue - 34,
      hsl.hue + 68,
      hsl.hue - 68,
      hsl.hue + 180,
    ];
    final alphas = <double>[0.62, 0.55, 0.52, 0.46, 0.44, 0.30];
    final light = <double>[0.60, 0.66, 0.55, 0.70, 0.50, 0.74];
    for (var i = 0; i < hues.length; i++) {
      colors.add(HSLColor.fromAHSL(
        1,
        (hues[i] % 360 + 360) % 360,
        0.72 + (i.isEven ? 0.10 : 0.0),
        light[i],
      ).toColor());
      weights.add(alphas[i]);
    }
    radii.addAll(const <double>[0.46, 0.56, 0.46, 0.56, 0.46, 0.56]);
  }

  final List<Color> colors = <Color>[];
  final List<double> weights = <double>[];
  final List<double> radii = <double>[];

  /// A handful of accents exist per app run, so a tiny map is enough.
  static final Map<int, FlowPalette> _cache = {};

  static FlowPalette of(Color base) =>
      _cache.putIfAbsent(base.toARGB32(), () => FlowPalette(base));
}

class _FlowPainter extends CustomPainter {
  _FlowPainter({
    required this.seconds,
    required this.base,
    required this.opacity,
  });

  /// Monotonic seconds; the sin/cos terms wrap, the clock does not.
  final double seconds;
  final Color base;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Pale tint of the accent as the ground. Kept light so the blobs carry
    // the colour: a saturated ground is what made the old version look like a
    // flat fill. With a low opacity the neutral base shows through instead.
    canvas.drawRect(rect, Paint()..color = flowGround(base, opacity));

    final palette = FlowPalette.of(base);
    final short = size.shortestSide;

    for (var i = 0; i < palette.colors.length; i++) {
      final color = palette.colors[i];
      final radius = short * palette.radii[i];
      final center = flowBlobCenter(i, seconds / 26, size);
      final alpha = palette.weights[i] * opacity;

      final shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha),
          color.withValues(alpha: alpha * 0.55),
          color.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, Paint()..shader = shader);
    }

    // A soft veil at the top keeps the header text readable whatever the
    // blobs do up there.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Neutrals.bg.withValues(alpha: 0.22),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_FlowPainter old) =>
      old.seconds != seconds || old.base != base || old.opacity != opacity;
}
