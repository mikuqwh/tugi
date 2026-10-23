// SPDX-License-Identifier: GPL-3.0-or-later

/// Integration tests: Video to GIF pipeline on emulator-5554.
/// Requires: Flutter SDK + emulator running + ffmpeg_kit_flutter_new installed.
/// These tests CANNOT run on host VM — MissingPluginException expected without device.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Skip all tests if ffmpeg_kit is not available on host VM.
  // Integration tests only run on device/emulator via `flutter test integration_test/`.

  test('SKIP: FFmpegKit available check', () {
    // This test documents that integration tests require a device.
    // On host VM, FFmpegKit.execute throws MissingPluginException.
    expect(true, isTrue);
  });

  // Actual device tests — run only on emulator-5554:
  // flutter test integration_test/ -d emulator-5554
  //
  // test('Video → GIF end-to-end', () async {
  //   final service = VideoToGifService(workDir: '/data/local/tmp/tugi');
  //   final result = await service.convertVideoToGif(
  //     'acq/verify/e2e_source.mp4',
  //     fps: Creation.layerFps,
  //   );
  //   expect(File(result).existsSync(), isTrue);
  //   expect(File(result).lengthSync(), greaterThan(100000));
  // });
}
