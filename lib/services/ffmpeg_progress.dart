// SPDX-License-Identifier: GPL-3.0-or-later

/// Running ffmpeg with progress.
///
/// `FFmpegKit.executeWithArguments` blocks until the process exits and reports
/// nothing in between, which is why a 30 s GIF export looked frozen. The async
/// form takes a statistics callback; this file turns that into a 0..1 value and
/// a cancellable handle.
library ffmpeg_progress;

import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

/// Thrown when the user cancels: screens treat it as "no result", not an error.
class FfmpegCancelled implements Exception {
  const FfmpegCancelled();
  @override
  String toString() => '已取消';
}

/// A running ffmpeg job.
class FfmpegJob {
  FfmpegJob(this._session, this._done);

  final FFmpegSession _session;

  /// Completed by ffmpeg's own completion callback.
  ///
  /// `session.getReturnCode()` alone came back null for an async run whose
  /// output was clearly complete, so the code is captured from the callback.
  final Future<ReturnCode?> _done;

  /// True once [cancel] has been called, so the caller can tell a cancelled run
  /// from a failing one.
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    _session.cancel();
  }

  /// Blocks until ffmpeg exits. Returns the raw output for error summaries.
  Future<String> wait() async {
    final code = await _done;
    final output = await _session.getOutput() ?? '';
    if (cancelled) throw const FfmpegCancelled();
    if (code?.isValueSuccess() != true) {
      throw FfmpegException(
        'code ${code?.getValue()}: ${_tail(output)}',
        output,
      );
    }
    return output;
  }

  /// The last few lines, where ffmpeg puts the actual reason.
  static String _tail(String output) {
    final lines = output.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.length <= 3
        ? output.trim()
        : lines.sublist(lines.length - 3).join(' | ');
  }
}

class FfmpegException implements Exception {
  const FfmpegException(this.message, this.output);
  final String message;
  final String output;
  @override
  String toString() => 'ffmpeg $message';
}

/// Start [args] and report progress from ffmpeg's own statistics.
///
/// [totalMs] is the DURATION of the work: the selected segment for a trim
/// (not the whole file), because ffmpeg's `time=` counts what it has encoded.
/// When it is unknown, [totalFrames] is used instead; when neither is known the
/// callback is simply never called and the UI stays indeterminate.
///
/// Returns as soon as the process is started, so the caller can keep the
/// session around for [FfmpegJob.cancel].
Future<FfmpegJob> runWithProgress(
  List<String> args, {
  int? totalMs,
  int? totalFrames,
  void Function(double progress)? onProgress,
}) async {
  void report(Statistics stats) {
    final cb = onProgress;
    if (cb == null) return;
    final ms = stats.getTime();
    double value;
    if (totalMs != null && totalMs > 0 && ms > 0) {
      value = ms / totalMs;
    } else if (totalFrames != null && totalFrames > 0) {
      final frames = stats.getVideoFrameNumber();
      if (frames <= 0) return;
      value = frames / totalFrames;
    } else {
      return;
    }
    // Never report 100% before the file is actually written.
    cb(value.clamp(0.0, 0.99));
  }

  final done = Completer<ReturnCode?>();
  final session = await FFmpegKit.executeWithArgumentsAsync(
    args,
    (s) async {
      if (!done.isCompleted) done.complete(await s.getReturnCode());
      return null;
    },
    null,
    report,
  );
  return FfmpegJob(session, done.future);
}

/// Convenience for the common case: run and wait.
Future<void> runAndWait(
  List<String> args, {
  int? totalMs,
  int? totalFrames,
  void Function(double progress)? onProgress,
}) async {
  final job = await runWithProgress(
    args,
    totalMs: totalMs,
    totalFrames: totalFrames,
    onProgress: onProgress,
  );
  await job.wait();
}

/// Kept for the callers that only need "did it succeed".
bool isSuccess(ReturnCode? code) => code?.isValueSuccess() == true;
