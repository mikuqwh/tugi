/// E2E test: Video to GIF conversion on emulator-5554.
/// Runs the actual VideoToGifService.convertVideoToGif() against /sdcard/e2e_source.mp4.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugi/models/creation.dart';
import 'package:tugi/services/video_to_gif_service.dart';

void main() {
  test('Video → GIF end-to-end on emulator', () async {
    final testVideo = '/sdcard/e2e_source.mp4';
    expect(File(testVideo).existsSync(), isTrue,
        reason: 'Test video must be pushed to emulator');

    final service = VideoToGifService(workDir: '/data/local/tmp/tugi');
    final result = await service.convertVideoToGif(
      testVideo,
      fps: Creation.layerFps,
      loop: true,
      dedup: true,
    );

    expect(result, isNotEmpty);
    expect(File(result).existsSync(), isTrue,
        reason: 'GIF output file should exist at $result');
    expect(File(result).lengthSync(), greaterThan(100000),
        reason: 'GIF should be larger than 100KB');
  });
}
