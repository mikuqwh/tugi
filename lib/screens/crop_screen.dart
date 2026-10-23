// SPDX-License-Identifier: GPL-3.0-or-later

/// Full-screen crop editor: a poster of the source, a draggable frame, shape
/// presets, and a live pixel readout.
///
/// A separate route rather than an inline panel because the frame needs the
/// whole screen to be draggable, and because the calling screens scroll — a
/// nested drag gesture inside a ListView is exactly the conflict the rest of
/// this codebase keeps working around.
library crop_screen;

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/crop_rect.dart';
import '../ui/app_palette.dart';
import '../ui/crop_overlay.dart';

class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.imagePath,
    required this.sourceWidth,
    required this.sourceHeight,
    this.initial = CropRect.whole,
    this.accent = FeatureColors.videoToGif,
    this.onColor = FeatureColors.videoToGifOn,
  });

  final String imagePath;
  final int sourceWidth;
  final int sourceHeight;
  final CropRect initial;
  final Color accent;
  final Color onColor;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late CropRect _rect = widget.initial;
  CropAspect _aspect = CropAspect.free;

  double get _frameAspect => widget.sourceWidth <= 0
      ? 16 / 9
      : widget.sourceWidth / widget.sourceHeight;

  void _pickAspect(CropAspect aspect) {
    setState(() {
      _aspect = aspect;
      if (aspect == CropAspect.free) return;
      // Snap the current box to the shape rather than discarding it.
      _rect = _rect.isWhole
          ? CropRect.centredAspect(aspect.ratio, frameAspect: _frameAspect)
          : _rect.withAspect(aspect.ratio, frameAspect: _frameAspect);
    });
  }

  @override
  Widget build(BuildContext context) {
    final px = _rect.toPixels(widget.sourceWidth, widget.sourceHeight);

    return Theme(
      data: buildFeatureTheme(Accents.rose),
      child: Scaffold(
        backgroundColor: const Color(0xFF10131A),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          title: const Text('裁剪画面'),
          actions: [
            TextButton(
              key: const Key('crop_reset'),
              onPressed: () => setState(() {
                _rect = CropRect.whole;
                _aspect = CropAspect.free;
              }),
              child: const Text('重置', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AspectRatio(
                    aspectRatio: _frameAspect,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(widget.imagePath),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) => const ColoredBox(
                              color: Color(0xFF1A1F29),
                              child: Icon(Icons.image_not_supported,
                                  color: Colors.white38),
                            ),
                          ),
                          CropOverlay(
                            key: const Key('crop_overlay'),
                            rect: _rect,
                            accent: widget.accent,
                            aspect: _aspect.ratio,
                            frameAspect: _frameAspect,
                            onChanged: (r) => setState(() => _rect = r),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              color: const Color(0xFF1A1F29),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${px.w} × ${px.h} · 起点 ${px.x},${px.y}',
                    key: const Key('crop_readout'),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final aspect in CropAspect.values) ...[
                        _AspectChip(
                          key: Key('crop_aspect_${aspect.name}'),
                          label: aspect.label,
                          selected: aspect == _aspect,
                          accent: widget.accent,
                          onTap: () => _pickAspect(aspect),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          key: const Key('crop_apply'),
                          // Applying the whole frame is a real answer ("no
                          // crop"); only Cancel returns null.
                          onPressed: () => Navigator.pop(context, _rect),
                          icon: const Icon(Icons.check),
                          label: Text(
                            _rect.isWhole ? '不裁剪' : '应用裁剪',
                            style: TextStyle(color: widget.onColor),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: widget.accent,
                            foregroundColor: widget.onColor,
                            disabledBackgroundColor:
                                widget.accent.withValues(alpha: 0.16),
                            disabledForegroundColor:
                                widget.accent.withValues(alpha: 0.55),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AspectChip extends StatelessWidget {
  const _AspectChip({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? accent : Colors.white10,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? accent : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }
}
