/// The capability probe's caching and shape, with a canned ffmpeg listing.
///
/// Real parsing lives in `packages/format_core` and is tested with `dart test`
/// there; here we only check that the app-side wrapper asks once, caches, and
/// turns the answer into the availability rows the format grid needs.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/convert/capability_probe.dart';

const String _encoders = '''
Encoders:
 V..... = Video
 ------
 V....D libwebp              libwebp WebP image (codec webp)
 V....D libx264              libx264 H.264 (codec h264)
 A....D libmp3lame           libmp3lame MP3 (codec mp3)
''';

const String _muxers = '''
Muxers:
  E apng             Animated Portable Network Graphics
  E mp4              MP4 (MPEG-4 Part 14)
''';

void main() {
  test('asks ffmpeg once per listing and caches the answer', () async {
    var calls = 0;
    final probe = CapabilityProbe(runner: (args) async {
      calls++;
      if (args.contains('-encoders')) return _encoders;
      if (args.contains('-muxers')) return _muxers;
      return '';
    });

    await probe.encoders();
    await probe.encoders();
    await probe.muxers();
    expect(calls, 2);
  });

  test('availability rows flag what this build can write', () async {
    final probe = CapabilityProbe(runner: (args) async {
      if (args.contains('-encoders')) return _encoders;
      return _muxers;
    });

    final rows = await probe.availability(MediaKind.image);
    Map<String, bool> byId = {for (final r in rows) r.$1.id: r.$2};

    // libwebp is present, so WebP is offered; APNG needs its muxer, present.
    expect(byId['webp'], isTrue);
    expect(byId['apng'], isTrue);
    // png/bmp/tiff need no probe token.
    expect(byId['png'], isTrue);
    // avif needs libaom-av1, which this fake build does not have.
    expect(byId['avif'], isFalse);
  });

  test('a video build without x264 has no mp4 to offer', () async {
    final probe = CapabilityProbe(runner: (args) async {
      if (args.contains('-encoders'))
        return 'Encoders:\n A....D libmp3lame  mp3\n';
      return 'Muxers:\n  E mp4  MP4\n';
    });
    final rows = await probe.availability(MediaKind.video);
    final mp4 = rows.firstWhere((r) => r.$1.id == 'mp4_h264');
    expect(mp4.$2, isFalse);
    // Audio extraction still works: it only needs the audio encoder.
    final mp3 = rows.firstWhere((r) => r.$1.id == 'mp3');
    expect(mp3.$2, isTrue);
  });
}
