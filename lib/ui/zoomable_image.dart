// SPDX-License-Identifier: GPL-3.0-or-later

/// A pinch-zoom / pan viewer that treats its box as the frame.
///
/// Why not [InteractiveViewer]:
///
///  * its gesture recogniser loses the arena to the feature pager's horizontal
///    drag, so dragging a zoomed photo flipped to the next feature;
///  * it does not clamp panning, so the photo could be dragged off its frame.
///
/// Here the child is fitted into a fixed frame, zooming is clamped so the
/// content always covers the frame, and the scale recogniser accepts on
/// pointer-down (like [EagerPanDetector]) so the pager cannot steal it.
// SPDX-License-Identifier: GPL-3.0-or-later

library zoomable_image;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.child,
    this.minScale = 1.0,
    this.maxScale = 6.0,
    this.onScaleChanged,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  final Widget child;
  final double minScale;
  final double maxScale;

  /// Reports the current scale, e.g. so a screen can show a zoom badge.
  final ValueChanged<double>? onScaleChanged;

  /// Long-press is detected here too: the eager scale recogniser claims every
  /// pointer, so a GestureDetector's long-press would never fire (that is how
  /// "hold to see the previous implementation" broke silently).
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  double _scale = 1;
  Offset _offset = Offset.zero;

  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  Size _size = Size.zero;

  // Double-tap is detected from raw pointers: the eager scale recogniser
  // claims every pointer, so a DoubleTapGestureRecognizer would never win.
  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  Timer? _longPressTimer;
  bool _longPressActive = false;
  Offset? _downPos;

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (_longPressActive) {
      _longPressActive = false;
      widget.onLongPressEnd?.call();
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _downPos = event.localPosition;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _longPressActive = true;
      widget.onLongPressStart?.call();
    });
    final now = DateTime.now();
    final last = _lastTapAt;
    final pos = _lastTapPos;
    if (last != null &&
        pos != null &&
        now.difference(last) < const Duration(milliseconds: 320) &&
        (event.localPosition - pos).distance < 40) {
      _lastTapAt = null;
      _reset();
      return;
    }
    _lastTapAt = now;
    _lastTapPos = event.localPosition;
  }

  void _reset() {
    setState(() {
      _scale = widget.minScale;
      _offset = Offset.zero;
    });
    widget.onScaleChanged?.call(_scale);
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  Offset _clampOffset(Offset offset, double scale, Size size) {
    // The content is the frame; when scaled it is larger, and the offset may
    // only move within the excess so no empty edge can be revealed.
    final maxX = (size.width * scale - size.width) / 2;
    final maxY = (size.height * scale - size.height) / 2;
    return Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
  }

  void _onStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = details.focalPoint;
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final nextScale =
        (_startScale * details.scale).clamp(widget.minScale, widget.maxScale);
    final ratio = nextScale / _startScale;
    final center = _size.center(Offset.zero);
    // Keep the point under the fingers fixed while scaling, then add the pan.
    final delta = details.focalPoint - _startFocal;
    final focus = _startFocal - center - _startOffset;
    final next = _startOffset + delta - focus * (ratio - 1);
    setState(() {
      _scale = nextScale;
      _offset = _clampOffset(next, nextScale, _size);
    });
    widget.onScaleChanged?.call(_scale);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: (e) {
            final down = _downPos;
            if (down != null && (e.localPosition - down).distance > 12) {
              _cancelLongPress();
            }
          },
          onPointerUp: (_) {
            _cancelLongPress();
          },
          onPointerCancel: (_) {
            _cancelLongPress();
          },
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _EagerScaleRecognizer:
                  GestureRecognizerFactoryWithHandlers<_EagerScaleRecognizer>(
                () => _EagerScaleRecognizer(),
                (recognizer) {
                  recognizer
                    ..onStart = _onStart
                    ..onUpdate = _onUpdate;
                },
              ),
            },
            child: ClipRect(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                  ..scaleByDouble(_scale, _scale, 1, 1),
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A scale recogniser that claims the pointer immediately, so an enclosing
/// PageView cannot take the drag.
class _EagerScaleRecognizer extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
