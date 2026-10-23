// SPDX-License-Identifier: GPL-3.0-or-later

/// The selected segment of a media file, in seconds.
///
/// Kept as plain Dart so the trimming rules (clamping, minimum length,
/// snapping, labels) can be unit-tested without a widget or ffmpeg.
library trim_range;

import 'package:flutter/foundation.dart';

@immutable
class TrimRange {
  const TrimRange({required this.start, required this.end});

  /// A range covering the whole file.
  factory TrimRange.whole(double total) =>
      TrimRange(start: 0, end: total <= 0 ? 0 : total);

  final double start;
  final double end;

  double get duration => (end - start).clamp(0, double.infinity).toDouble();

  bool get isWhole => start <= 0.0005;

  TrimRange copyWith({double? start, double? end}) =>
      TrimRange(start: start ?? this.start, end: end ?? this.end);

  Map<String, Object?> toJson() => {'start': start, 'end': end};

  static TrimRange? fromJson(Map<String, Object?> raw) {
    final start = raw['start'];
    final end = raw['end'];
    if (start is! num || end is! num) return null;
    return TrimRange(start: start.toDouble(), end: end.toDouble());
  }

  @override
  bool operator ==(Object other) =>
      other is TrimRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TrimRange($start..$end)';
}

/// Smallest segment the UI allows. A GIF frame is typically 20–100 ms; 100 ms
/// leaves at least one frame for the 10 fps default while still letting the
/// user cut a blink.
const double kMinTrimSeconds = 0.1;

/// Move the START handle, keeping the minimum length.
///
/// [total] clamps the value to the file; [min] is the minimum segment length.
TrimRange dragStart(TrimRange range, double value, double total,
    {double min = kMinTrimSeconds}) {
  final upper = (range.end - min).clamp(0.0, total);
  final start = value.clamp(0.0, upper);
  return TrimRange(start: start, end: range.end);
}

/// Move the END handle, keeping the minimum length.
TrimRange dragEnd(TrimRange range, double value, double total,
    {double min = kMinTrimSeconds}) {
  final lower = (range.start + min).clamp(0.0, total);
  final end = value.clamp(lower, total);
  return TrimRange(start: range.start, end: end);
}

/// Snap a time to the nearest frame boundary.
///
/// Trimming to a time between two frames would silently round somewhere
/// ffmpeg chooses; snapping makes the label honest ("this is frame N").
double snapToFrame(double seconds, double fps, double total) {
  if (fps <= 0) return seconds.clamp(0.0, total);
  final frame = (seconds * fps).round();
  return (frame / fps).clamp(0.0, total);
}

/// `0:03.4` — the format a scrub bar shows.
String formatSeconds(double seconds) {
  final safe = seconds < 0 ? 0.0 : seconds;
  // Work in tenths so 59.96 rolls over into 1:00.0 instead of printing
  // "60.0s" (the carry used to stop at the seconds field).
  final tenths = (safe * 10).round();
  final minutes = tenths ~/ 600;
  final rest = tenths % 600;
  final s = rest ~/ 10;
  final t = rest % 10;
  if (minutes == 0) return '$s.${t}s';
  return '$minutes:${s.toString().padLeft(2, '0')}.$t';
}
