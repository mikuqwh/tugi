// SPDX-License-Identifier: GPL-3.0-or-later

/// A scale detector that claims the pointer immediately, like
/// [EagerPanDetector] but able to report two-finger scale as well.
///
/// The watermark stage needs both gestures on one surface: one finger drags
/// the watermark, two fingers zoom the preview. A PanGestureRecognizer cannot
/// report scale, and a plain GestureDetector loses to the pager's swipe, hence
/// this recogniser.
// SPDX-License-Identifier: GPL-3.0-or-later

library eager_scale;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class EagerScaleDetector extends StatelessWidget {
  const EagerScaleDetector({
    super.key,
    required this.child,
    this.onStart,
    this.onUpdate,
    this.onEnd,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final GestureScaleStartCallback? onStart;
  final GestureScaleUpdateCallback? onUpdate;
  final GestureScaleEndCallback? onEnd;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: behavior,
      gestures: {
        _EagerScaleRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerScaleRecognizer>(
          () => _EagerScaleRecognizer(),
          (recognizer) {
            recognizer
              ..onStart = onStart
              ..onUpdate = onUpdate
              ..onEnd = onEnd;
          },
        ),
      },
      child: child,
    );
  }
}

class _EagerScaleRecognizer extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
