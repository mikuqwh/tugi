// SPDX-License-Identifier: GPL-3.0-or-later

/// Runs the scramble algorithms on real image bytes.
///
/// Kept out of the screen so the pixel plumbing (decode → transform → encode)
/// has one home. The transform itself is pure and lives in
/// `utils/image_scramble.dart`; the heavy loop is pushed to an isolate for
/// photos, because a 12 MP image is 48 MB of bytes and would jank the UI.
library scramble_service;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../utils/image_scramble.dart';

/// Everything the isolate needs; a record would work too, but a class is
/// clearer at the call site.
class ScrambleRequest {
  const ScrambleRequest({
    required this.rgba,
    required this.width,
    required this.height,
    required this.password,
    required this.mode,
    required this.inverse,
    required this.blockSize,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final String password;
  final ScrambleMode mode;
  final bool inverse;
  final int blockSize;
}

Uint8List _scrambleInIsolate(ScrambleRequest request) => scrambleBytes(
      request.rgba,
      width: request.width,
      height: request.height,
      password: request.password,
      mode: request.mode,
      inverse: request.inverse,
      blockSize: request.blockSize,
    );

/// A decoded picture, ready to be scrambled or shown.
class DecodedImage {
  const DecodedImage({
    required this.rgba,
    required this.width,
    required this.height,
    required this.bytes,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// The original file bytes, for the "before" preview.
  final Uint8List bytes;

  int get pixels => width * height;
}

class ScrambleService {
  ScrambleService({String? workDir})
      : workDir = workDir ?? Directory.systemTemp.path;

  final String workDir;

  /// Above this many pixels the transform goes to an isolate. Below it the
  /// isolate hand-off costs more than the loop.
  static const int isolateThreshold = 400000;

  /// Decode [path], optionally downscaled so a preview is cheap.
  Future<DecodedImage> decode(String path, {int? maxSide}) async {
    final bytes = File(path).readAsBytesSync();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: maxSide,
      targetHeight: maxSide,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('无法读取图片像素');
    }
    final decoded = DecodedImage(
      rgba: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
      bytes: bytes,
    );
    image.dispose();
    codec.dispose();
    return decoded;
  }

  /// Scramble (or restore) [source]; returns both the pixels and the PNG.
  ///
  /// The pixels matter to the caller: after scrambling, "restore" can run on
  /// the scrambled buffer instead of re-reading the file, which is what makes
  /// the round trip check instant.
  Future<({Uint8List rgba, Uint8List png})> transform(
    DecodedImage source, {
    required String password,
    required ScrambleMode mode,
    required bool inverse,
    int blockSize = 24,
  }) async {
    final request = ScrambleRequest(
      rgba: source.rgba,
      width: source.width,
      height: source.height,
      password: password,
      mode: mode,
      inverse: inverse,
      blockSize: blockSize,
    );
    final result = source.pixels > isolateThreshold
        ? await compute(_scrambleInIsolate, request)
        : _scrambleInIsolate(request);
    final png = await _encodePng(result, source.width, source.height);
    return (rgba: result, png: png);
  }

  /// Write the result next to the app's temp files and return its path.
  Future<String> writeResult(Uint8List png, {required bool inverse}) async {
    await Directory(workDir).create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final name = inverse ? 'unscrambled_$stamp.png' : 'scrambled_$stamp.png';
    final file = File('$workDir/$name')..writeAsBytesSync(png);
    return file.path;
  }

  Future<Uint8List> _encodePng(Uint8List rgba, int width, int height) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('无法编码 PNG');
    return data.buffer.asUint8List();
  }
}
