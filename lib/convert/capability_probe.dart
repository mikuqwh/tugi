// SPDX-License-Identifier: GPL-3.0-or-later

/// Device capability probe: what can THIS ffmpeg build actually encode?
///
/// The app ships a prebuilt ffmpeg-kit package, so the codec list is a property
/// of the package, not of our code. Today that build has libwebp but no
/// libjxl; after the custom build (roadmap S2) it flips. Asking the build once
/// at startup is what lets the UI grey a format out with a reason instead of
/// offering a button that fails.
///
/// The parsing lives in `packages/format_core` (pure Dart, `dart test`-able);
/// this file only owns the FFmpegKit call and the cache.
// SPDX-License-Identifier: GPL-3.0-or-later

library capability_probe;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:format_core/format_core.dart';

class CapabilityProbe {
  CapabilityProbe({Future<String> Function(String args)? runner})
      : _run = runner ?? _runFfmpeg;

  /// Injectable so a test can feed a canned listing.
  final Future<String> Function(String args) _run;

  Set<String>? _encoders;
  Set<String>? _muxers;

  static Future<String> _runFfmpeg(String args) async {
    final session = await FFmpegKit.execute('-hide_banner $args');
    return await session.getOutput() ?? '';
  }

  /// Codec names the build can encode with.
  Future<Set<String>> encoders() async {
    return _encoders ??= parseCodecNames(await _run('-encoders'));
  }

  /// Container/muxer names the build can write.
  Future<Set<String>> muxers() async {
    return _muxers ??= parseCodecNames(await _run('-muxers'));
  }

  /// Everything the build can write, as one set for [isFormatAvailable].
  Future<Set<String>> availableNames() async {
    return {...await encoders(), ...await muxers()};
  }

  /// [kind]'s formats, each flagged available or not, for the format grid.
  Future<List<(FormatSpec, bool)>> availability(MediaKind kind) async {
    return availabilityFor(await availableNames(), kind);
  }
}
