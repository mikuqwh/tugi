// SPDX-License-Identifier: GPL-3.0-or-later

/// The bar that replaces the primary button while ffmpeg runs.
///
/// A 30 s GIF takes a while; without this the app looked frozen. The bar is
/// driven by ffmpeg's own statistics, and it always offers a way out.
library export_progress;

import 'package:flutter/material.dart';

import 'app_palette.dart';

class ExportProgress extends StatelessWidget {
  const ExportProgress({
    super.key,
    required this.progress,
    required this.label,
    required this.accent,
    required this.onColor,
    this.onCancel,
  });

  /// 0..1, or null while the stage cannot report one (writing to the gallery).
  final double? progress;

  /// What is happening right now ("正在转换…").
  final String label;

  final Color accent;
  final Color onColor;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final value = progress;
    final percent = value == null ? null : '${(value * 100).round()}%';
    return Container(
      key: const Key('export_progress'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: onColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (percent != null)
                Text(
                  percent,
                  key: const Key('export_percent'),
                  style: TextStyle(
                    color: onColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              if (onCancel != null) ...[
                const SizedBox(width: 6),
                TextButton(
                  key: const Key('export_cancel'),
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: onColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              // Null keeps it moving, so "working but unknown" still reads as
              // working rather than stuck at zero.
              value: value,
              minHeight: 6,
              backgroundColor: Colors.white24,
              color: onColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dimmed row for the "saving to the gallery" phase, which has no progress.
class ExportSaving extends StatelessWidget {
  const ExportSaving({super.key, required this.accent, required this.onColor});

  final Color accent;
  final Color onColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('export_saving'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: onColor),
          ),
          const SizedBox(width: 10),
          Text('正在保存…', style: TextStyle(color: onColor, fontSize: 13)),
        ],
      ),
    );
  }
}

/// The colour used by a feature's progress bar, kept next to the widget so the
/// screens do not repeat it.
extension ProgressPalette on ThemeData {
  Color get exportAccent => Neutrals.ink;
}
