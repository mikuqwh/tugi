// SPDX-License-Identifier: GPL-3.0-or-later

/// The interactive crop frame: dim the outside, drag a corner, an edge or the
/// whole box.
///
/// The box lives in normalised coordinates ([CropRect]); this widget only maps
/// them to the preview box's pixels. Handles are deliberately fat (28 logical
/// px) because the preview is small on a phone.
library crop_overlay;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/crop_rect.dart';

class CropOverlay extends StatelessWidget {
  const CropOverlay({
    super.key,
    required this.rect,
    required this.onChanged,
    required this.accent,
    this.aspect, // width / height, or 0 for free
    this.frameAspect,
  });

  final CropRect rect;
  final ValueChanged<CropRect> onChanged;
  final Color accent;

  /// Locked shape (0 = free).
  final double? aspect;

  /// The preview's own width / height, needed to honour [aspect].
  final double? frameAspect;

  static const double _handle = 28;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w <= 0 || h <= 0) return const SizedBox.shrink();

        final r = _px(rect, w, h);
        // The preview keeps the source's aspect, so a pixel-space ratio IS the
        // normalised one: no frame conversion needed.
        final ratio = aspect ?? 0;

        Rect apply(Rect next) {
          var nn = next;
          if (ratio > 0) {
            // Resize around the box's centre to the locked shape, shrinking to
            // fit when the new shape would leave the preview.
            var nw = nn.width;
            var nh = nw / ratio;
            if (nh > nn.height) {
              nh = nn.height;
              nw = nh * ratio;
            }
            nn = Rect.fromCenter(
              center: nn.center,
              width: nw,
              height: nh,
            );
          }
          nn = _clamp(nn, w, h);
          return nn;
        }

        return Stack(
          children: [
            // The dimmed outside.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _MaskPainter(rect: r, accent: accent),
                ),
              ),
            ),
            // Move by dragging inside the box.
            Positioned.fromRect(
              rect: r,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (d) {
                  final next = r.translate(d.delta.dx, d.delta.dy);
                  onChanged(_norm(apply(next), w, h));
                },
              ),
            ),
            // Corners.
            for (final corner in _Corner.values)
              _HandleDot(
                key: Key('crop_${corner.name}'),
                position: _cornerPoint(r, corner),
                bounds: Size(w, h),
                color: accent,
                icon: _cornerIcon(corner),
                onDrag: (delta) {
                  final next = _applyCorner(r, corner, delta);
                  onChanged(_norm(apply(next), w, h));
                },
              ),
            // Edges.
            for (final edge in _Edge.values)
              _EdgeHandle(
                key: Key('crop_edge_${edge.name}'),
                rect: r,
                edge: edge,
                bounds: Size(w, h),
                color: accent,
                onDrag: (delta) {
                  final next = _applyEdge(r, edge, delta);
                  onChanged(_norm(apply(next), w, h));
                },
              ),
          ],
        );
      },
    );
  }

  Rect _px(CropRect n, double w, double h) => Rect.fromLTRB(
        n.left * w,
        n.top * h,
        n.right * w,
        n.bottom * h,
      );

  CropRect _norm(Rect r, double w, double h) => CropRect(
        left: (r.left / w).clamp(0.0, 1.0),
        top: (r.top / h).clamp(0.0, 1.0),
        right: (r.right / w).clamp(0.0, 1.0),
        bottom: (r.bottom / h).clamp(0.0, 1.0),
      );

  Rect _clamp(Rect r, double w, double h) {
    const min = 32.0; // smaller than this and the box is unhittable
    var left = r.left.clamp(0.0, w - min);
    var top = r.top.clamp(0.0, h - min);
    var right = r.right.clamp(left + min, w);
    var bottom = r.bottom.clamp(top + min, h);
    if (right - left < min) right = math.min(w, left + min);
    if (bottom - top < min) bottom = math.min(h, top + min);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Offset _cornerPoint(Rect r, _Corner c) => switch (c) {
        _Corner.topLeft => r.topLeft,
        _Corner.topRight => r.topRight,
        _Corner.bottomLeft => r.bottomLeft,
        _Corner.bottomRight => r.bottomRight,
      };

  Rect _applyCorner(Rect r, _Corner c, Offset d) => switch (c) {
        _Corner.topLeft =>
          Rect.fromLTRB(r.left + d.dx, r.top + d.dy, r.right, r.bottom),
        _Corner.topRight =>
          Rect.fromLTRB(r.left, r.top + d.dy, r.right + d.dx, r.bottom),
        _Corner.bottomLeft =>
          Rect.fromLTRB(r.left + d.dx, r.top, r.right, r.bottom + d.dy),
        _Corner.bottomRight =>
          Rect.fromLTRB(r.left, r.top, r.right + d.dx, r.bottom + d.dy),
      };

  Rect _applyEdge(Rect r, _Edge e, Offset d) => switch (e) {
        _Edge.top => Rect.fromLTRB(r.left, r.top + d.dy, r.right, r.bottom),
        _Edge.bottom => Rect.fromLTRB(r.left, r.top, r.right, r.bottom + d.dy),
        _Edge.left => Rect.fromLTRB(r.left + d.dx, r.top, r.right, r.bottom),
        _Edge.right => Rect.fromLTRB(r.left, r.top, r.right + d.dx, r.bottom),
      };

  static IconData _cornerIcon(_Corner c) => switch (c) {
        _Corner.topLeft => Icons.north_west,
        _Corner.topRight => Icons.north_east,
        _Corner.bottomLeft => Icons.south_west,
        _Corner.bottomRight => Icons.south_east,
      };
}

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

enum _Edge { top, bottom, left, right }

class _HandleDot extends StatelessWidget {
  const _HandleDot({
    super.key,
    required this.position,
    required this.bounds,
    required this.color,
    required this.icon,
    required this.onDrag,
  });

  final Offset position;
  final Size bounds;
  final Color color;
  final IconData icon;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    const size = CropOverlay._handle;
    // Clamped: a handle centred on the frame edge would be half outside the
    // Stack and could not receive the drag.
    final left = (position.dx - size / 2).clamp(0.0, bounds.width - size);
    final top = (position.dy - size / 2).clamp(0.0, bounds.height - size);
    return Positioned(
      left: left,
      top: top,
      width: size,
      height: size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onDrag(d.delta),
        child: Center(
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 3,
                ),
              ],
            ),
            child: Icon(icon, size: 13, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _EdgeHandle extends StatelessWidget {
  const _EdgeHandle({
    super.key,
    required this.rect,
    required this.edge,
    required this.bounds,
    required this.color,
    required this.onDrag,
  });

  final Rect rect;
  final _Edge edge;
  final Size bounds;
  final Color color;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    const thickness = 26.0;
    const length = 40.0;
    final vertical = edge == _Edge.left || edge == _Edge.right;
    final left = switch (edge) {
      _Edge.left => rect.left - thickness / 2,
      _Edge.right => rect.right - thickness / 2,
      _ => rect.center.dx - length / 2,
    };
    final top = switch (edge) {
      _Edge.top => rect.top - thickness / 2,
      _Edge.bottom => rect.bottom - thickness / 2,
      _ => rect.center.dy - length / 2,
    };
    final width = vertical ? thickness : length;
    final height = vertical ? length : thickness;
    return Positioned(
      left: left.clamp(0.0, bounds.width - width),
      top: top.clamp(0.0, bounds.height - height),
      width: vertical ? thickness : length,
      height: vertical ? length : thickness,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onDrag(d.delta),
        child: Center(
          child: Container(
            width: vertical ? 4 : 28,
            height: vertical ? 28 : 4,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _MaskPainter extends CustomPainter {
  const _MaskPainter({required this.rect, required this.accent});

  final Rect rect;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.62),
    );

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = accent;
    canvas.drawRect(rect, border);

    // Thirds, so a composition can be judged.
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = rect.left + rect.width * i / 3;
      final dy = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, dy), Offset(rect.right, dy), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _MaskPainter old) =>
      old.rect != rect || old.accent != accent;
}
