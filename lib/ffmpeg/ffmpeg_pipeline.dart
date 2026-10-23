/// Tugi - FFmpeg execution.
///
/// Split from the command builders (commands.dart) so those stay testable
/// without a Flutter engine. Re-exported here to keep one import site.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'commands.dart';

export 'commands.dart';

/// Execute an FFmpeg command and return the output path.
Future<String> executeFFmpeg(List<String> args) async {
  final session = await FFmpegKit.executeWithArguments(args);
  final returnCode = await session.getReturnCode();

  if (returnCode?.isValueSuccess() ?? false) {
    return args.last; // output path is typically the last argument
  } else {
    throw FFmpegException(
      'FFmpeg failed with code ${returnCode?.getValue()}',
      await session.getOutput(),
    );
  }
}
