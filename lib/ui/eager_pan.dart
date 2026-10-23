/// A pan detector that wins the gesture arena as soon as a finger lands.
///
/// The watermark canvas needs this: a plain [GestureDetector] with `onPan*`
/// loses to the surrounding PageView's horizontal drag recognizer, so dragging
/// the watermark would flip to the next feature instead of moving the mark.
/// Accepting on pointer-down takes the gesture away from the scrollable
/// immediately, and the canvas is an explicit drag surface, so stealing it
/// there is correct.
// SPDX-License-Identifier: GPL-3.0-or-later

library eager_pan;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class EagerPanDetector extends StatelessWidget {
  const EagerPanDetector({
    super.key,
    required this.child,
    this.onDown,
    this.onStart,
    this.onUpdate,
    this.onEnd,
    this.onCancel,
    this.behavior = HitTestBehavior.translucent,
  });

  final Widget child;
  final GestureDragDownCallback? onDown;
  final GestureDragStartCallback? onStart;
  final GestureDragUpdateCallback? onUpdate;
  final GestureDragEndCallback? onEnd;
  final GestureDragCancelCallback? onCancel;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: behavior,
      gestures: {
        _EagerPanRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
          () => _EagerPanRecognizer(),
          (recognizer) {
            recognizer
              ..onDown = onDown
              ..onStart = onStart
              ..onUpdate = onUpdate
              ..onEnd = onEnd
              ..onCancel = onCancel;
          },
        ),
      },
      child: child,
    );
  }
}

class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    // Claim the gesture before the enclosing PageView can.
    resolve(GestureDisposition.accepted);
  }
}
