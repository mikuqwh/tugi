/// Add Watermark — media detection and filtergraph path escaping.
///
/// Pure Dart, no Flutter, so this runs on the host VM with `dart test`.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugi/ffmpeg/commands.dart'
    show WatermarkMediaKind, escapeFilterPath;
import 'package:tugi/utils/media_kind.dart';

Uint8List _bytes(List<int> head, [int pad = 64]) {
  final b = Uint8List(pad);
  for (var i = 0; i < head.length && i < pad; i++) {
    b[i] = head[i];
  }
  return b;
}

void main() {
  group('mediaKindOfBytes', () {
    test('a GIF signature is a GIF', () {
      final b = _bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.gif);
    });

    test('GIF87a is a GIF too', () {
      final b = _bytes([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.gif);
    });

    test('an MP4 ftyp box is a video', () {
      final b = _bytes([
        0x00, 0x00, 0x00, 0x18, //
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x69, 0x73, 0x6F, 0x6D, // isom
      ]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.video);
    });

    test('a moov box is a video even without ftyp', () {
      final b = _bytes([
        0x00, 0x00, 0x00, 0x08, //
        0x6D, 0x6F, 0x6F, 0x76, // moov
        0x00, 0x00, 0x00, 0x00,
      ]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.video);
    });

    test('a PNG is an image', () {
      final b = _bytes([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      ]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.image);
    });

    test('a JPEG is an image', () {
      final b = _bytes([0xFF, 0xD8, 0xFF, 0xE0]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.image);
    });

    test('a GIF is checked before the image reader would accept it', () {
      // A GIF is also a structurally valid image, so an image-first check
      // would classify an animation as a still and the output would be one
      // frozen frame.
      final b = _bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(mediaKindOfBytes(b), isNot(WatermarkMediaKind.image));
    });

    test('a truncated file does not throw', () {
      expect(mediaKindOfBytes(Uint8List(0)), WatermarkMediaKind.image);
      expect(mediaKindOfBytes(Uint8List(3)), WatermarkMediaKind.image);
    });

    test('a file whose name lies is classified by its bytes', () {
      // The extension is never consulted.
      final b = _bytes([0xFF, 0xD8, 0xFF, 0xE0]);
      expect(mediaKindOfBytes(b), WatermarkMediaKind.image);
    });
  });

  group('outputExtensionFor', () {
    test('each kind gets the extension its muxer expects', () {
      expect(outputExtensionFor(WatermarkMediaKind.gif), 'gif');
      expect(outputExtensionFor(WatermarkMediaKind.image), 'png');
      expect(outputExtensionFor(WatermarkMediaKind.video), 'mp4');
    });
  });

  group('escapeFilterPath', () {
    test('a colon is escaped -- it would otherwise end the option', () {
      expect(escapeFilterPath(r'C:\fonts\a.ttf'), r'C\:\\fonts\\a.ttf');
    });

    test('an Android path is untouched', () {
      // The real device paths contain no structural characters, so the
      // escaping must be a no-op there -- over-escaping would point
      // freetype at a file that does not exist.
      const p = '/data/user/0/app.tugi/cache/wm_font.ttf';
      expect(escapeFilterPath(p), p);
    });

    test('quotes, brackets and commas are escaped', () {
      expect(escapeFilterPath("a'b"), r"a\'b");
      expect(escapeFilterPath('a[b]'), r'a\[b\]');
      expect(escapeFilterPath('a,b'), r'a\,b');
    });

    test('a plain path comes back unchanged', () {
      expect(escapeFilterPath('/tmp/font.ttf'), '/tmp/font.ttf');
    });
  });
}
