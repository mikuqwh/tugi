// SPDX-License-Identifier: GPL-3.0-or-later

/// A crop rectangle in NORMALISED coordinates: 0..1 of the source frame.
///
/// Fractions rather than pixels because the same crop must survive a change of
/// output width, and because the preview image shown to the user is never the
/// full resolution. Pixel conversion (and ffmpeg's even-size requirement)
/// happens once, in [toPixels].
library crop_rect;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

@immutable
class CropRect {
  const CropRect({
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
  });

  /// A frame that is not cropped at all.
  static const whole = CropRect();

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0, 1).toDouble();
  double get height => (bottom - top).clamp(0, 1).toDouble();

  /// True when the rect covers the frame (no crop needed).
  bool get isWhole =>
      left <= 0.0005 && top <= 0.0005 && right >= 0.9995 && bottom >= 0.9995;

  bool get isValid => width > 0.01 && height > 0.01;

  CropRect copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) =>
      CropRect(
        left: left ?? this.left,
        top: top ?? this.top,
        right: right ?? this.right,
        bottom: bottom ?? this.bottom,
      );

  /// Pixel geometry for ffmpeg: `crop=w:h:x:y`.
  ///
  /// Both size and offset are rounded DOWN to even numbers, and the size never
  /// goes below 16 px: H.264 rejects odd dimensions, and an odd offset makes
  /// the encoder shift the chroma plane.
  ({int x, int y, int w, int h}) toPixels(int sourceWidth, int sourceHeight) {
    var w = (width * sourceWidth).round();
    var h = (height * sourceHeight).round();
    var x = (left * sourceWidth).round();
    var y = (top * sourceHeight).round();

    if (w < 16) w = 16;
    if (h < 16) h = 16;
    if (w > sourceWidth) w = sourceWidth;
    if (h > sourceHeight) h = sourceHeight;
    if (x + w > sourceWidth) x = math.max(0, sourceWidth - w);
    if (y + h > sourceHeight) y = math.max(0, sourceHeight - h);

    return (x: x - x % 2, y: y - y % 2, w: w - w % 2, h: h - h % 2);
  }

  /// The filter string, or an empty string when nothing is cropped.
  String toFilter(int sourceWidth, int sourceHeight) {
    if (isWhole) return '';
    final p = toPixels(sourceWidth, sourceHeight);
    return 'crop=${p.w}:${p.h}:${p.x}:${p.y}';
  }

  /// Fit the largest centred rect of [aspect] (width / height) inside [frame].
  static CropRect centredAspect(double aspect, {double frameAspect = 16 / 9}) {
    if (aspect <= 0) return whole;
    if (aspect >= frameAspect) {
      // Wider than the frame: full width, letterboxed height.
      final h = frameAspect / aspect;
      return CropRect(top: (1 - h) / 2, bottom: (1 + h) / 2);
    }
    final w = aspect / frameAspect;
    return CropRect(left: (1 - w) / 2, right: (1 + w) / 2);
  }

  /// Re-shape the current rect to [aspect], keeping its centre.
  CropRect withAspect(double aspect, {double frameAspect = 16 / 9}) {
    if (aspect <= 0) return this;
    final cx = (left + right) / 2;
    final cy = (top + bottom) / 2;
    // Largest box of the wanted shape that fits inside the frame...
    var w = width;
    var h = w / (aspect * frameAspect);
    if (h > height) {
      h = height;
      w = h * aspect * frameAspect;
    }
    // ...clamped so it does not leave the frame.
    w = w.clamp(0.02, 1.0).toDouble();
    h = h.clamp(0.02, 1.0).toDouble();
    var l = cx - w / 2;
    var t = cy - h / 2;
    l = l.clamp(0.0, 1.0 - w).toDouble();
    t = t.clamp(0.0, 1.0 - h).toDouble();
    return CropRect(left: l, top: t, right: l + w, bottom: t + h);
  }

  Map<String, Object?> toJson() =>
      {'left': left, 'top': top, 'right': right, 'bottom': bottom};

  static CropRect? fromJson(Map<String, Object?> raw) {
    final l = raw['left'];
    final t = raw['top'];
    final r = raw['right'];
    final b = raw['bottom'];
    if (l is! num || t is! num || r is! num || b is! num) return null;
    final rect = CropRect(
      left: l.toDouble().clamp(0.0, 1.0),
      top: t.toDouble().clamp(0.0, 1.0),
      right: r.toDouble().clamp(0.0, 1.0),
      bottom: b.toDouble().clamp(0.0, 1.0),
    );
    return rect.isValid ? rect : null;
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'CropRect(${left.toStringAsFixed(3)},${top.toStringAsFixed(3)}..'
      '${right.toStringAsFixed(3)},${bottom.toStringAsFixed(3)})';
}

/// Portrait/landscape shape presets offered by the crop screen.
enum CropAspect {
  free('自由', 0),
  square('1:1', 1),
  fourThree('4:3', 4 / 3),
  sixteenNine('16:9', 16 / 9);

  const CropAspect(this.label, this.ratio);
  final String label;

  /// width / height, or 0 for "no constraint".
  final double ratio;
}
