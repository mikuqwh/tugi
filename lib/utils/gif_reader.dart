// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

// GIF metadata needed after a conversion: real frame count and real playback
// length.
//
// Both must come from walking the block chain. Scanning the whole byte array
// for `0x21 0xF9` marker pairs counts false positives inside the LZW payload
// -- a real 60-frame / 5.0 s GIF comes out as 129 frames / 5298.3 s that way.

class GifInfo {
  const GifInfo({
    required this.frames,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.loops,
    required this.delaysMs,
  });

  /// Frame count, taken from image descriptors (0x2C).
  final int frames;

  /// Sum of every frame's Graphic Control Extension delay, in milliseconds.
  final int durationMs;

  final int width;
  final int height;

  /// NETSCAPE2.0 loop count, or -1 when the file carries no loop block.
  final int loops;

  /// Per-frame delays in milliseconds, in playback order.
  final List<int> delaysMs;

  double get seconds => durationMs / 1000;

  /// True when the header yielded a usable frame count and duration, i.e. the
  /// numbers can be shown without guessing.
  bool get isValidFrames => frames > 0 && durationMs > 0;
}

class GifParseException implements Exception {
  GifParseException(this.message);
  final String message;
  @override
  String toString() => 'GifParseException: $message';
}

class GifReader {
  GifReader(this.bytes);

  final Uint8List bytes;
  int _pos = 0;
  int _width = 0;
  int _height = 0;

  static GifInfo parse(List<int> bytes) => GifReader(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      )._run();

  GifInfo _run() {
    _readHeader();
    return _readBlocks();
  }

  int _u8() {
    if (_pos >= bytes.length) {
      throw GifParseException('unexpected end of data at $_pos');
    }
    return bytes[_pos++];
  }

  int _u16() {
    final lo = _u8();
    return lo | (_u8() << 8);
  }

  void _skip(int n) {
    if (_pos + n > bytes.length) {
      throw GifParseException('unexpected end of data at $_pos (+$n)');
    }
    _pos += n;
  }

  /// Consume a chain of length-prefixed data sub-blocks, 0x00 terminated.
  void _skipSubBlocks() {
    while (true) {
      final n = _u8();
      if (n == 0) return;
      _skip(n);
    }
  }

  void _readHeader() {
    if (bytes.length < 13) {
      throw GifParseException('file too small: ${bytes.length} bytes');
    }
    final sig = String.fromCharCodes(bytes.sublist(0, 6));
    if (sig != 'GIF87a' && sig != 'GIF89a') {
      throw GifParseException('not a GIF (signature "$sig")');
    }
    _pos = 6;
    _width = _u16();
    _height = _u16();
    final packed = _u8();
    _u8(); // background colour index
    _u8(); // pixel aspect ratio
    if (packed & 0x80 != 0) {
      // Global colour table: 3 * 2^(N+1) bytes.
      _skip(3 * (1 << ((packed & 0x07) + 1)));
    }
  }

  GifInfo _readBlocks() {
    var frames = 0;
    final delays = <int>[];

    while (_pos < bytes.length) {
      final marker = _u8();
      if (marker == 0x3B) break; // trailer -- end of the block chain.
      if (marker == 0x00) continue; // stray padding between blocks.

      if (marker == 0x21) {
        _readExtension();
        continue;
      }

      if (marker == 0x2C) {
        // Image descriptor -- this, not the extension before it, is a frame.
        _skip(8); // left, top, width, height
        final packed = _u8();
        if (packed & 0x80 != 0) {
          _skip(3 * (1 << ((packed & 0x07) + 1))); // local colour table
        }
        _u8(); // LZW minimum code size
        _skipSubBlocks(); // LZW data sub-blocks
        frames++;
        delays.add(_lastGceDelayMs);
        _lastGceDelayMs = 0;
        continue;
      }

      throw GifParseException(
          'unknown block marker 0x${marker.toRadixString(16)} at ${_pos - 1}');
    }

    return GifInfo(
      frames: frames == 0 ? 1 : frames,
      durationMs: delays.fold<int>(0, (a, b) => a + b),
      width: _width,
      height: _height,
      loops: _loops,
      delaysMs: delays,
    );
  }

  /// Reads one extension block (the 0x21 introducer is already consumed),
  /// recording the GCE delay and the NETSCAPE2.0 loop count as it goes.
  void _readExtension() {
    final label = _u8();
    switch (label) {
      case 0xF9: // Graphic Control Extension
        final size = _u8();
        if (size != 4) {
          throw GifParseException('GCE size $size at ${_pos - 1}, expected 4');
        }
        _u8(); // packed: disposal method + transparency flag
        final delayCs = _u16();
        _u8(); // transparent colour index
        if (_u8() != 0) {
          throw GifParseException('GCE not block-terminated at ${_pos - 1}');
        }
        _lastGceDelayMs = delayCs * 10;
      case 0xFF: // Application Extension (NETSCAPE2.0 looping)
        final size = _u8();
        if (size != 11) {
          throw GifParseException(
              'AppExt size $size at ${_pos - 1}, expected 11');
        }
        final id = String.fromCharCodes(bytes.sublist(_pos, _pos + 11));
        _skip(11);
        final sub = <int>[];
        while (true) {
          final n = _u8();
          if (n == 0) break;
          sub.addAll(bytes.sublist(_pos, _pos + n));
          _skip(n);
        }
        if (id.startsWith('NETSCAPE') && sub.length >= 3 && sub[0] == 1) {
          _loops = sub[1] | (sub[2] << 8);
        }
      default:
        // Comment (0xFE), Plain Text (0x01), XMP (0xF5), anything the spec adds
        // later: all plain sub-block chains.
        _skipSubBlocks();
    }
  }

  /// Delay in ms of the most recent Graphic Control Extension, attached to the
  /// next image descriptor.
  int _lastGceDelayMs = 0;

  /// NETSCAPE2.0 loop count, or -1 when the file carries no loop block.
  int _loops = -1;
}
