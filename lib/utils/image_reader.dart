// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// Image metadata needed by the Edit Image editor: real pixel dimensions,
/// container format and whether the file carries an alpha channel.
///
/// Same philosophy as [GifReader]: every number the UI shows must come from
/// the actual file header, not from assumptions, and anything unparseable is
/// rejected instead of answered with partial data.
///
/// PNG: 8-byte signature, then chunks; IHDR carries width/height (big-endian
/// u32 each) and the colour type (0 grayscale, 2 truecolour, 3 palette,
/// 4 grayscale+alpha, 6 truecolour+alpha). Types 4 and 6 have an alpha
/// channel; a palette entry with tRNS transparency is rare in photo content
/// and reported as opaque.
///
/// JPEG: FF D8, then a marker stream. SOFn markers (C0-CF except C4 DHT,
/// C8 JPG, CC DAC) carry precision + height + width. Frames appear before
/// SOS in every real file (including progressive, SOF2). JPEG has no alpha.
class ImageInfo {
  const ImageInfo({
    required this.width,
    required this.height,
    required this.format,
    required this.hasAlpha,
  });

  final int width;
  final int height;

  /// `'png'` or `'jpeg'` -- also the natural output extension.
  final String format;

  final bool hasAlpha;

  bool get isValid => width > 0 && height > 0;
}

class ImageParseException implements Exception {
  ImageParseException(this.message);
  final String message;
  @override
  String toString() => 'ImageParseException: $message';
}

class ImageReader {
  static const _pngSignature = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  /// 0xC0..0xCF minus 0xC4 (DHT), 0xC8 (JPG), 0xCC (DAC).
  static const _sofMarkers = <int>{
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF,
  };

  static bool _isPng(Uint8List b) {
    if (b.length < 8) return false;
    for (var i = 0; i < 8; i++) {
      if (b[i] != _pngSignature[i]) return false;
    }
    return true;
  }

  static ImageInfo parse(Uint8List bytes) {
    if (_isPng(bytes)) return _parsePng(bytes);
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return _parseJpeg(bytes);
    }
    throw ImageParseException(
        'Not a PNG or JPEG stream (${bytes.length} bytes)');
  }

  static ImageInfo _parsePng(Uint8List b) {
    // Signature (8) + IHDR chunk header (8) + width/height (8) + the two
    // fields read below.
    if (b.length < 26) {
      throw ImageParseException('Truncated PNG (${b.length} bytes)');
    }
    final type = String.fromCharCodes(b.sublist(12, 16));
    if (type != 'IHDR') {
      throw ImageParseException('PNG does not start with IHDR (got $type)');
    }
    final bd = ByteData.sublistView(b);
    final width = bd.getUint32(16);
    final height = bd.getUint32(20);
    final colorType = b[25];
    return ImageInfo(
      width: width,
      height: height,
      format: 'png',
      hasAlpha: colorType == 4 || colorType == 6,
    );
  }

  static ImageInfo _parseJpeg(Uint8List b) {
    var pos = 2;
    while (pos + 4 <= b.length) {
      if (b[pos] != 0xFF) {
        throw ImageParseException('Corrupt JPEG marker stream at $pos');
      }
      // Marker padding: fill bytes (0xFF) may repeat before the real marker.
      while (pos < b.length && b[pos] == 0xFF) {
        pos++;
      }
      if (pos >= b.length) break;
      final marker = b[pos];
      pos++;
      if (_sofMarkers.contains(marker)) {
        // SOF segment: length(2) precision(1) height(2) width(2), with pos
        // already past the two marker bytes.
        if (pos + 6 >= b.length) {
          throw ImageParseException('Truncated JPEG SOF segment');
        }
        final height = bd0(b, pos + 3);
        final width = bd0(b, pos + 5);
        return ImageInfo(
            width: width, height: height, format: 'jpeg', hasAlpha: false);
      }
      if (marker == 0xD9 || marker == 0xDA) {
        // EOI or scan start reached without a frame header.
        throw ImageParseException(
            'JPEG has no SOF before ${_markerName(marker)}');
      }
      // Every other marker is followed by a 2-byte length (itself included).
      if (pos + 2 > b.length) {
        throw ImageParseException('Truncated JPEG segment at $pos');
      }
      final segmentLength = bd0(b, pos);
      if (segmentLength < 2) {
        // A zero/one length would move pos backwards and loop forever.
        throw ImageParseException('Corrupt JPEG segment length at $pos');
      }
      pos += segmentLength;
    }
    throw ImageParseException('Truncated JPEG (${b.length} bytes)');
  }

  static int bd0(Uint8List b, int off) => (b[off] << 8) | b[off + 1];

  static String _markerName(int m) => '0x${m.toRadixString(16)}';
}
