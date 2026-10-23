// SPDX-License-Identifier: GPL-3.0-or-later

/// Device/integration test: Video to GIF full pipeline, driven through
/// ffmpeg-kit on a real Android device or emulator.
///
/// NOT part of `dart run test test/ffmpeg/` on purpose: it imports
/// `ffmpeg_kit_flutter_new`, a Flutter plugin, so it cannot be compiled by the
/// host Dart VM (same reason the command builders live in the pure-Dart
/// `lib/ffmpeg/commands.dart`). Running it needs a device with the clone
/// installed:
///
///   flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
///   flutter test test/device/video_to_gif_device_test.dart   # needs `flutter test`
///
/// The host-runnable coverage for the same pipeline lives in
/// `test/ffmpeg/video_to_gif_command_test.dart`.
/// Regression baseline: Video to GIF complete pipeline.
/// Uses acq/verify outputs as ground truth.
/// ASSUMPTION: 6/6 steps PASS.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'package:test/test.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

void main() {
  // Device-only paths: adjust these to wherever your fixtures live.
  const workDir = '/sdcard/Download';
  const outputDir = '/sdcard/Download/tugi_output';

  setUpAll(() {
    Directory(outputDir).createSync(recursive: true);
  });

  test('Step 1: Create source video (5s @ 30fps)', () async {
    // Source already exists from acq/verify
    final src = File('$workDir/e2e_source.mp4');
    expect(src.existsSync(), isTrue,
        reason: 'Source video must exist at $workDir/e2e_source.mp4');
    expect(src.lengthSync(), greaterThan(0));
  });

  test('Step 2: Probe source video', () async {
    final session =
        await FFmpegKit.execute('-i "$workDir/e2e_source.mp4" 2>&1');
    final output = await session.getOutput();
    expect(output, contains('Duration:'));
    expect(output, contains('Video:'));
  });

  test('Step 3: Video �?GIF (core palette pipeline)', () async {
    final cmd = '-y -i "$workDir/e2e_source.mp4" '
        '-filter_complex "[0:v]fps=15,split[s1][s2];'
        '[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1" '
        '-gifflags -offsetting -loop 0 -r 15 -f gif "$outputDir/step3.gif"';
    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();
    expect(returnCode?.isValueSuccess() ?? false, isTrue,
        reason: 'FFmpeg step 3 failed: ${await session.getOutput()}');
    final gif = File('$outputDir/step3.gif');
    expect(gif.existsSync(), isTrue);
    expect(gif.lengthSync(), greaterThan(100000));
  });

  test('Step 4: GIF + mpdecimate dedup', () async {
    // `fps` before `mpdecimate`, and no `setpts`: see videoToGif() for why the
    // order matters and what setpts costs (it halves the reported duration).
    final cmd = '-y -i "$outputDir/step3.gif" '
        '-filter_complex "[0:v]fps=15,mpdecimate,'
        'split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1" '
        '-gifflags -offsetting -loop 0 -f gif "$outputDir/step4.gif"';
    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();
    expect(returnCode?.isValueSuccess() ?? false, isTrue,
        reason: 'FFmpeg step 4 failed: ${await session.getOutput()}');
    final gif = File('$outputDir/step4.gif');
    expect(gif.existsSync(), isTrue);
  });

  test('Step 5: Scale 50% + re-palette', () async {
    final cmd = '-y -i "$outputDir/step4.gif" '
        '-filter_complex "[0:v]scale=320:-1,split[s1][s2];'
        '[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1" '
        '-gifflags -offsetting -loop 0 -r 15 -f gif "$outputDir/step5.gif"';
    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();
    expect(returnCode?.isValueSuccess() ?? false, isTrue,
        reason: 'FFmpeg step 5 failed: ${await session.getOutput()}');
    final gif = File('$outputDir/step5.gif');
    expect(gif.existsSync(), isTrue);
    expect(gif.lengthSync(), lessThan(1000000)); // scaled = smaller
  });

  test('Step 6: Add watermark + re-palette (FINAL)', () async {
    final cmd = '-y -i "$outputDir/step5.gif" '
        '-filter_complex "[0:v]drawtext=fontcolor=white:fontsize=16:'
        "text='Tugi':x=main_w/2-text_w/2:y=main_h/2-text_h/2,"
        'split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1" '
        '-gifflags -offsetting -loop 0 -r 15 -f gif "$outputDir/final.gif"';
    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();
    expect(returnCode?.isValueSuccess() ?? false, isTrue,
        reason: 'FFmpeg step 6 failed: ${await session.getOutput()}');
    final gif = File('$outputDir/final.gif');
    expect(gif.existsSync(), isTrue);
    expect(gif.lengthSync(), greaterThan(100000));
  });

  test('Final GIF parameters match baseline', () async {
    final finalGif = File('$outputDir/final.gif');
    final baselineGif = File('$workDir/e2e_final.gif');

    expect(finalGif.existsSync(), isTrue);
    expect(baselineGif.existsSync(), isTrue);

    // Both should be GIF format
    final finalBytes = finalGif.readAsBytesSync();

    // GIF signature: 47 49 46 38 (GIF8)
    expect(finalBytes[0], equals(0x47)); // G
    expect(finalBytes[1], equals(0x49)); // I
    expect(finalBytes[2], equals(0x46)); // F
    expect(finalBytes[3], equals(0x38)); // 8

    // Size should be in same ballpark (within 2x)
    final ratio = finalGif.lengthSync() / baselineGif.lengthSync();
    expect(ratio, greaterThan(0.5));
    expect(ratio, lessThan(2.0));
  });
}
