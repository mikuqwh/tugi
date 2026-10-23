// SPDX-License-Identifier: GPL-3.0-or-later

/// A scrub bar with two handles: pick the segment to keep.
///
/// The strip is the filmstrip itself (thumbnails of the source), dimmed
/// outside the selection. Handles snap to frames, and the labels always read
/// the truth: the times you will actually get.
library trim_timeline;

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/trim.dart';
import 'eager_pan.dart';
import 'app_palette.dart';

class TrimTimeline extends StatefulWidget {
  const TrimTimeline({
    super.key,
    required this.total,
    required this.range,
    required this.onChanged,
    this.frames = const [],
    this.fps,
    this.accent = FeatureColors.editGif,
    this.onColor = FeatureColors.editGifOn,
    this.height = 64,
  });

  /// Source length in seconds.
  final double total;

  final TrimRange range;
  final ValueChanged<TrimRange> onChanged;

  /// Thumbnail file paths, left to right.
  final List<String> frames;

  /// When set, handles snap to whole frames at this rate.
  final double? fps;

  final Color accent;
  final Color onColor;
  final double height;

  @override
  State<TrimTimeline> createState() => _TrimTimelineState();
}

class _TrimTimelineState extends State<TrimTimeline> {
  /// Which handle the current drag belongs to.
  bool _draggingStart = false;

  double _timeFor(double dx, double width) {
    if (width <= 0 || widget.total <= 0) return 0;
    final t = (dx / width).clamp(0.0, 1.0) * widget.total;
    final fps = widget.fps;
    return fps == null ? t : snapToFrame(t, fps, widget.total);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final range = widget.range;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final startX = total <= 0 ? 0.0 : (range.start / total) * width;
            final endX = total <= 0 ? 0.0 : (range.end / total) * width;
            final selected = (endX - startX).clamp(0.0, width);

            return SizedBox(
              height: widget.height,
              child: Stack(
                children: [
                  // Filmstrip, clipped to the strip's rounded corners.
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _Strip(
                        frames: widget.frames,
                        accent: widget.accent,
                        height: widget.height,
                      ),
                    ),
                  ),
                  // Everything outside the selection is dimmed, not hidden:
                  // you still need to see what you are cutting away.
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: startX,
                    child: const _Dim(),
                  ),
                  Positioned(
                    left: endX,
                    top: 0,
                    bottom: 0,
                    width: (width - endX).clamp(0.0, width),
                    child: const _Dim(),
                  ),
                  // The selection frame.
                  Positioned(
                    left: startX,
                    top: 0,
                    bottom: 0,
                    width: selected,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.symmetric(
                            horizontal:
                                BorderSide(color: widget.accent, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Handles.
                  _Handle(
                    key: const Key('trim_handle_start'),
                    left: startX - 11,
                    color: widget.accent,
                    icon: Icons.chevron_left,
                    onColor: widget.onColor,
                    onDrag: (dx) {
                      if (!_draggingStart) {
                        _draggingStart = true;
                      }
                      final t = _timeFor(dx, width);
                      widget.onChanged(dragStart(range, t, total));
                    },
                    onDragEnd: () => setState(() => _draggingStart = false),
                  ),
                  _Handle(
                    key: const Key('trim_handle_end'),
                    left: endX - 11,
                    color: widget.accent,
                    icon: Icons.chevron_right,
                    onColor: widget.onColor,
                    onDrag: (dx) {
                      final t = _timeFor(dx, width);
                      widget.onChanged(dragEnd(range, t, total));
                    },
                    onDragEnd: () => setState(() => _draggingStart = false),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Row(
          key: const Key('trim_range_label'),
          children: [
            _Chip(text: formatSeconds(range.start)),
            const SizedBox(width: 6),
            const Text('→',
                style: TextStyle(color: Neutrals.inkSoft, fontSize: 12)),
            const SizedBox(width: 6),
            _Chip(text: formatSeconds(range.end)),
            const Spacer(),
            Text(
              '保留 ${formatSeconds(range.duration)}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: widget.accent,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip(
      {required this.frames, required this.accent, required this.height});

  final List<String> frames;
  final Color accent;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (frames.isEmpty) {
      return Container(
        color: accent.withValues(alpha: 0.12),
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, color: accent, size: 20),
      );
    }
    return Row(
      children: [
        for (final f in frames)
          Expanded(
            child: Image.file(
              File(f),
              height: height,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // A missing thumbnail must not blow up the whole row.
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: accent.withValues(alpha: 0.12)),
            ),
          ),
      ],
    );
  }
}

class _Dim extends StatelessWidget {
  const _Dim();

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Colors.black.withValues(alpha: 0.55));
}

class _Handle extends StatefulWidget {
  const _Handle({
    super.key,
    required this.left,
    required this.color,
    required this.icon,
    required this.onColor,
    required this.onDrag,
    required this.onDragEnd,
  });

  final double left;
  final Color color;
  final IconData icon;
  final Color onColor;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  @override
  State<_Handle> createState() => _HandleState();
}

class _HandleState extends State<_Handle> {
  double _x = 0;

  @override
  void initState() {
    super.initState();
    _x = widget.left;
  }

  @override
  void didUpdateWidget(covariant _Handle old) {
    super.didUpdateWidget(old);
    // When the range changes from outside (e.g. snapping), follow it.
    if (!_dragging) _x = widget.left;
  }

  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    // The visual bar is 22 px, but the touch target is 44: the handles sit on
    // the strip's edges, and a 22 px grab area was genuinely hard to hit.
    const hitWidth = 44.0;
    return Positioned(
      left: (_x - (hitWidth - 22) / 2).clamp(-hitWidth / 2, double.infinity),
      top: 0,
      bottom: 0,
      width: hitWidth,
      child: EagerPanDetector(
        behavior: HitTestBehavior.opaque,
        onStart: (_) {
          _dragging = true;
          _x = widget.left;
        },
        onUpdate: (details) {
          setState(() {
            _x += details.delta.dx;
            // Report the handle's centre (11 px into the 22 px bar) as a
            // position the parent can turn into a time.
            widget.onDrag(_x + 11);
          });
        },
        onEnd: (_) {
          _dragging = false;
          widget.onDragEnd();
        },
        child: Center(
          child: Container(
            width: 22,
            height: double.infinity,
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 4,
                ),
              ],
            ),
            child: Icon(widget.icon, size: 16, color: widget.onColor),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Neutrals.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Neutrals.line),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: Neutrals.ink,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
