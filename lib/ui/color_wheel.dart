/// A draggable colour wheel: hue ring outside, saturation/value square inside.
///
/// The HSV sliders it replaces were precise but unintuitive -- nobody thinks
/// "hue 189°, saturation 100%". Dragging on a wheel is the interaction people
/// already know from every drawing app.
///
/// One CustomPainter draws both parts, so a drag only repaints the wheel. The
/// square is drawn with two gradients (white -> hue horizontally, transparent
/// -> black vertically), which is exactly the HSV square and needs no shader.
// SPDX-License-Identifier: GPL-3.0-or-later

library color_wheel;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'eager_pan.dart';

class ColorWheel extends StatefulWidget {
  const ColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 220,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final double size;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);

  /// 'hue' while dragging the ring, 'sv' while dragging the square.
  String? _mode;

  @override
  void didUpdateWidget(ColorWheel old) {
    super.didUpdateWidget(old);
    // Follow an externally-set colour (preset tap), but never fight the drag.
    if (_mode == null && widget.color.toARGB32() != _hsv.toColor().toARGB32()) {
      _hsv = HSVColor.fromColor(widget.color);
    }
  }

  void _emit(HSVColor hsv) {
    setState(() => _hsv = hsv);
    widget.onChanged(hsv.toColor());
  }

  Geometry _geometry() {
    final r = widget.size / 2;
    final ringOuter = r;
    final ringInner = r - 26;
    final squareSide = ringInner * math.sqrt(2) * 0.94;
    return Geometry(
      center: Offset(r, r),
      ringOuter: ringOuter,
      ringInner: ringInner,
      square: Rect.fromCenter(
        center: Offset(r, r),
        width: squareSide,
        height: squareSide,
      ),
    );
  }

  /// [start] locks the control under the finger; afterwards the mode never
  /// changes, so a drag that wanders off the ring still tracks the ring
  /// (the old version dropped the gesture as soon as the finger left it,
  /// which felt like the wheel "letting go").
  void _handle(Offset local, {required bool start}) {
    final g = _geometry();
    final d = local - g.center;
    final dist = d.distance;

    if (start) {
      if (g.square.contains(local)) {
        _mode = 'sv';
      } else if (dist >= g.ringInner - 14) {
        _mode = 'hue';
      } else {
        _mode = null;
        return;
      }
    }
    if (_mode == 'hue') {
      // Clamp instead of ignoring: dragging past the ring keeps turning.
      final degrees = (math.atan2(d.dy, d.dx) * 180 / math.pi + 360) % 360;
      _emit(_hsv.withHue(degrees));
      return;
    }
    if (_mode == 'sv') {
      final s = ((local.dx - g.square.left) / g.square.width).clamp(0.0, 1.0);
      final v =
          1 - ((local.dy - g.square.top) / g.square.height).clamp(0.0, 1.0);
      _emit(_hsv.withSaturation(s).withValue(v));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Eager: wins the gesture arena on pointer-down, so the settings list
    // cannot steal the drag halfway and the wheel tracks every frame.
    return EagerPanDetector(
      key: const Key('color_wheel'),
      onDown: (d) => _handle(d.localPosition, start: true),
      onUpdate: (d) => _handle(d.localPosition, start: false),
      onEnd: (_) => _mode = null,
      onCancel: () => _mode = null,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _WheelPainter(hsv: _hsv),
        ),
      ),
    );
  }
}

class Geometry {
  const Geometry({
    required this.center,
    required this.ringOuter,
    required this.ringInner,
    required this.square,
  });

  final Offset center;
  final double ringOuter;
  final double ringInner;
  final Rect square;
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.hsv});

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);
    final ringInner = r - 26;
    final squareSide = ringInner * math.sqrt(2) * 0.94;
    final square = Rect.fromCenter(
      center: center,
      width: squareSide,
      height: squareSide,
    );

    // Hue ring.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 24
      ..shader = const SweepGradient(
        colors: [
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r - 13, ring);

    // Saturation/value square: white -> hue, then black on top.
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    final horizontal = Paint()
      ..shader = LinearGradient(
        colors: [Colors.white, hueColor],
      ).createShader(square);
    canvas.drawRect(square, horizontal);
    final vertical = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
      ).createShader(square);
    canvas.drawRect(square, vertical);

    // Square border so it reads as a control on light backgrounds.
    canvas.drawRect(
      square,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x33000000),
    );

    // Thumbs.
    final hueRad = hsv.hue * math.pi / 180;
    final huePos =
        center + Offset(math.cos(hueRad), math.sin(hueRad)) * (r - 13);
    canvas.drawCircle(huePos, 9, Paint()..color = Colors.white);
    canvas.drawCircle(huePos, 6.5, Paint()..color = hsv.toColor());

    final svPos = Offset(
      square.left + square.width * hsv.saturation,
      square.top + square.height * (1 - hsv.value),
    );
    canvas.drawCircle(svPos, 8, Paint()..color = Colors.white);
    canvas.drawCircle(svPos, 5.5, Paint()..color = hsv.toColor());
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.hsv.hue != hsv.hue ||
      old.hsv.saturation != hsv.saturation ||
      old.hsv.value != hsv.value;
}

/// Hex label for a colour, e.g. `#00A6C2`.
String hexLabel(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// A row of saved colours plus a "save current" button.
class SavedColorRow extends StatelessWidget {
  const SavedColorRow({
    super.key,
    required this.colors,
    required this.onPick,
    this.onRemove,
    this.current,
  });

  final List<Color> colors;
  final ValueChanged<Color> onPick;
  final ValueChanged<Color>? onRemove;
  final Color? current;

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) {
      return const Text(
        '还没有保存的颜色：调好之后点「保存当前颜色」',
        style: TextStyle(fontSize: 11.5, color: Neutrals.inkSoft),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final color in colors)
          GestureDetector(
            key: Key('saved_color_${color.toARGB32()}'),
            onTap: () => onPick(color),
            onLongPress: onRemove == null ? null : () => onRemove!(color),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: current?.toARGB32() == color.toARGB32()
                      ? Neutrals.ink
                      : Neutrals.line,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
