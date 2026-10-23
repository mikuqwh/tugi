// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

/// MP4 metadata for the GIF to Video result card.
///
/// Reads the `moov` box tree directly: `mvhd` carries timescale + duration,
/// `tkhd` carries width/height as 16.16 fixed point. That is enough to display
/// "320×180 · 5.1 秒" without adding an ffprobe binding (which this project
/// does not depend on).
///
/// Returns zeros for anything unexpected rather than throwing: this only feeds
/// a display string, so a missing number must never fail a good conversion.
class Mp4Info {
  const Mp4Info({
    required this.width,
    required this.height,
    required this.seconds,
  });

  final int width;
  final int height;
  final double seconds;

  bool get isValid => width > 0 && height > 0;

  static Mp4Info probe(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return const Mp4Info(width: 0, height: 0, seconds: 0);
    }
    return parse(file.readAsBytesSync());
  }

  static Mp4Info parse(Uint8List bytes) {
    var width = 0;
    var height = 0;
    var timescale = 0;
    var duration = 0;
    var sawMvhd = false;
    var sawTkhd = false;

    // mvhd/tkhd live inside moov/trak, so the walk has to descend -- a flat
    // scan of the top-level boxes (ftyp, moov, free, mdat) finds nothing.
    void walk(int start, int end) {
      var i = start;
      while (i + 8 <= end) {
        final size = _u32(bytes, i);
        if (size < 8) return; // lost sync; stop instead of scanning payload
        if (i + size > end) return; // box claims more than the parent holds

        final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
        if (_containers.contains(type)) {
          walk(i + 8, i + size);
        } else if (type == 'mvhd' && !sawMvhd) {
          // Full-box header (version 1 byte + flags 3 bytes) plus creation and
          // modification times, whose width depends on the version. Offsets are
          // from the box start; verified against ffmpeg output (v0, timescale
          // 1000, duration 5134 -> 5.134 s, matching ffprobe):
          //   v0: +4 header, +8 creation, +12 modification -> ts at 20, dur at 24
          //   v1: +4 header, +8 creation, +16 modification -> ts at 28, dur at 32
          final v = bytes[i + 8];
          final timescaleAt = i + (v == 1 ? 28 : 20);
          final durationAt = timescaleAt + 4;
          timescale = _u32(bytes, timescaleAt);
          duration = v == 1 ? _u64(bytes, durationAt) : _u32(bytes, durationAt);
          sawMvhd = true;
        } else if (type == 'tkhd' && !sawTkhd) {
          // width/height are the final 8 bytes of the box, 16.16 fixed point.
          final dimAt = i + size - 8;
          width = _u32(bytes, dimAt) >> 16;
          height = _u32(bytes, dimAt + 4) >> 16;
          sawTkhd = true;
        }
        i += size;
      }
    }

    walk(0, bytes.length);

    return Mp4Info(
      width: width,
      height: height,
      seconds: timescale > 0 ? duration / timescale : 0,
    );
  }

  /// Boxes whose payload is a list of child boxes.
  static const Set<String> _containers = {
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'edts',
    'udta',
    'dinf',
  };

  static int _u32(Uint8List b, int at) {
    if (at < 0 || at + 4 > b.length) return 0;
    return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
  }

  static int _u64(Uint8List b, int at) {
    final hi = _u32(b, at);
    final lo = _u32(b, at + 4);
    return hi * 0x100000000 + lo;
  }
}
