// SPDX-License-Identifier: GPL-3.0-or-later

/// Unit tests for the MP4 box reader used by the GIF to Video result card.
///
/// The mvhd offset in here was wrong twice before (once by scanning only the
/// top-level boxes, once by miscounting the full-box header), and both times
/// ffmpeg produced a perfectly good file that the UI described as 0 seconds.
/// These cases pin the offsets against values cross-checked with ffprobe.
///
/// Uses `package:test` so it runs on the host: `dart run test`.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:tugi/ffmpeg/commands.dart';
import 'package:tugi/utils/mp4_reader.dart';
import 'package:test/test.dart';

void main() {
  group('gifToVideo command', () {
    test('keeps the source resolution when no width is given', () {
      // keep_resolution / enter_resolution. An earlier version defaulted to
      // `scale=iw*0.5:-1`, which silently halved every GIF.
      final args = gifToVideo(inputPath: '/in.gif', outputPath: '/out.mp4');
      expect(_vf(args), 'fps=12');
    });

    test('scales to an even height because yuv420p needs it', () {
      // Odd heights make libx264 fail outright, so -2 (not -1) is required.
      final args = gifToVideo(
          inputPath: '/in.gif', outputPath: '/out.mp4', outputWidth: 240);
      expect(_vf(args), 'fps=12,scale=240:-2:flags=lanczos');
    });

    test('emits h264 + yuv420p + faststart and ends with the output path', () {
      final args =
          gifToVideo(inputPath: '/in.gif', outputPath: '/out.mp4', fps: 24);
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(_vf(args), 'fps=24');
      expect(args.last, '/out.mp4');
    });
  });

  group('Mp4Info', () {
    test('reads size and duration from an mvhd/tkhd pair', () {
      final i = Mp4Info.parse(buildMp4(
        width: 320,
        height: 180,
        timescale: 1000,
        duration: 5134,
      ));
      expect(i.width, 320);
      expect(i.height, 180);
      expect(i.seconds, closeTo(5.134, 0.0001));
      expect(i.isValid, isTrue);
    });

    test('finds boxes nested inside moov/trak', () {
      // A flat scan of the top level sees only ftyp/moov/free/mdat and reports
      // 0x0 -- mvhd and tkhd are children.
      final i = Mp4Info.parse(buildMp4(
        width: 240,
        height: 136,
        timescale: 600,
        duration: 600,
      ));
      expect(i.width, 240);
      expect(i.height, 136);
      expect(i.seconds, closeTo(1.0, 0.0001));
    });

    test('handles 64-bit durations (version 1 mvhd)', () {
      final i = Mp4Info.parse(buildMp4(
        width: 1920,
        height: 1080,
        timescale: 90000,
        duration: 90000 * 3600,
        version: 1,
      ));
      expect(i.width, 1920);
      expect(i.height, 1080);
      expect(i.seconds, closeTo(3600.0, 0.001));
    });

    test('degrades to zeros instead of throwing on junk', () {
      final i = Mp4Info.parse(Uint8List.fromList(List.filled(512, 0x41)));
      expect(i.isValid, isFalse);
      expect(i.seconds, 0);
    });

    test('stops when a box claims more than the file holds', () {
      final bytes =
          buildMp4(width: 320, height: 180, timescale: 1000, duration: 5134);
      expect(() => Mp4Info.parse(bytes.sublist(0, 200)), returnsNormally);
    });
  });
}

String _vf(List<String> args) => args[args.indexOf('-vf') + 1];

/// Builds `ftyp` + `moov`{ `mvhd`, `trak`{ `tkhd` } } + `mdat`.
Uint8List buildMp4({
  required int width,
  required int height,
  required int timescale,
  required int duration,
  int version = 0,
}) {
  final b = <int>[];

  void u8(int v) => b.add(v & 0xFF);
  void u16(int v) {
    u8(v);
    u8(v >> 8);
  }

  void u32(int v) {
    u8(v >> 24);
    u8(v >> 16);
    u8(v >> 8);
    u8(v);
  }

  void u64(int v) {
    u32((v / 0x100000000).floor());
    u32(v & 0xFFFFFFFF);
  }

  void fourcc(String s) => b.addAll(s.codeUnits);

  /// Writes a box header with a placeholder size and returns its start offset.
  int openBox(String type) {
    final start = b.length;
    u32(0);
    fourcc(type);
    return start;
  }

  void closeBox(int start) {
    final size = b.length - start;
    b[start] = (size >> 24) & 0xFF;
    b[start + 1] = (size >> 16) & 0xFF;
    b[start + 2] = (size >> 8) & 0xFF;
    b[start + 3] = size & 0xFF;
  }

  final ftyp = openBox('ftyp');
  fourcc('isom');
  u32(512);
  fourcc('isomiso2mp41');
  closeBox(ftyp);

  final moov = openBox('moov');

  final mvhd = openBox('mvhd');
  u8(version);
  u8(0);
  u16(0); // flags
  if (version == 1) {
    u64(0); // creation
    u64(0); // modification
    u32(timescale);
    u64(duration);
  } else {
    u32(0); // creation
    u32(0); // modification
    u32(timescale);
    u32(duration);
  }
  while (b.length - mvhd < 100) {
    u32(0); // rate, volume, reserved, matrix -- values do not matter here
  }
  closeBox(mvhd);

  final trak = openBox('trak');

  final tkhd = openBox('tkhd');
  u8(0);
  u8(0);
  u16(7); // flags: enabled | in movie | in preview
  u32(0); // creation
  u32(0); // modification
  u32(1); // track id
  u32(0); // reserved
  u32(0); // duration
  for (var i = 0; i < 8; i++) {
    u32(0); // reserved
  }
  u16(0); // layer
  u16(0); // alternate group
  u16(0); // volume
  u16(0); // reserved
  for (var i = 0; i < 9; i++) {
    u32(0x00010000); // identity matrix
  }
  u32(width << 16);
  u32(height << 16);
  closeBox(tkhd);

  closeBox(trak);
  closeBox(moov);

  final mdat = openBox('mdat');
  for (var i = 0; i < 8; i++) {
    u8(0);
  }
  closeBox(mdat);

  return Uint8List.fromList(b);
}
