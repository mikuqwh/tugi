// SPDX-License-Identifier: GPL-3.0-or-later

/// Where a free watermark may sit, so its box never leaves the frame.
///
/// Pulled out of the screen because the interesting part is arithmetic, and
/// the arithmetic used to be unreachable without an image decoder: a widget
/// test cannot decode a GIF, so the old test could not tell a working clamp
/// from a skipped one.
library watermark_placement;

import 'dart:ui' show Offset, Size;

/// Clamp the watermark's CENTRE (as 0..1 fractions of the frame) so the box
/// stays inside. A null [layer] size means "not measured yet" and is left
/// alone: the next layout retries, and guessing a size here would make the
/// mark jump on the first drag.
Offset clampWatermarkCenter(
  double fx,
  double fy,
  Size? layer,
  Size frame,
) {
  var x = fx.clamp(0.0, 1.0);
  var y = fy.clamp(0.0, 1.0);
  if (layer == null || frame.width <= 0 || frame.height <= 0) {
    return Offset(x, y);
  }
  final halfW = (layer.width / 2) / frame.width;
  final halfH = (layer.height / 2) / frame.height;
  // A mark wider than the frame has no room to move: pin it to the centre
  // instead of letting `clamp` throw on crossed bounds.
  if (halfW < 0.5) {
    x = x.clamp(halfW, 1 - halfW);
  } else {
    x = 0.5;
  }
  if (halfH < 0.5) {
    y = y.clamp(halfH, 1 - halfH);
  } else {
    y = 0.5;
  }
  return Offset(x, y);
}
