/// Output-format handling in the two GIF features that gained a picker.
///
/// Both builders default to the historical output when no format is given, so
/// these tests also pin that the old behaviour is untouched.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/ffmpeg/commands.dart';

String filterOf(List<String> args, String flag) => args[args.indexOf(flag) + 1];

void main() {
  group('gifToVideo', () {
    test('no format keeps the original H.264 MP4 output', () {
      final args = gifToVideo(inputPath: 'in.gif', outputPath: 'out.mp4');
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args, isNot(contains('-crf')));
    });

    test('H.265 carries its tag and crf', () {
      final args = gifToVideo(
        inputPath: 'in.gif',
        outputPath: 'out.mp4',
        format: formatById('mp4_h265'),
      );
      expect(args, containsAllInOrder(['-c:v', 'libx265']));
      expect(args, containsAllInOrder(['-tag:v', 'hvc1']));
      expect(args, contains('-crf'));
    });

    test('WebM writes VP9 and no mp4 faststart', () {
      final args = gifToVideo(
        inputPath: 'in.gif',
        outputPath: 'out.webm',
        format: formatById('webm_vp9'),
      );
      expect(args, containsAllInOrder(['-c:v', 'libvpx-vp9']));
      expect(args.join(' '), isNot(contains('+faststart')));
    });

    test('MOV keeps faststart, MKV does not', () {
      final mov = gifToVideo(
        inputPath: 'in.gif',
        outputPath: 'out.mov',
        format: formatById('mov_h264'),
      );
      final mkv = gifToVideo(
        inputPath: 'in.gif',
        outputPath: 'out.mkv',
        format: formatById('mkv_h264'),
      );
      expect(mov.join(' '), contains('+faststart'));
      expect(mkv.join(' '), isNot(contains('+faststart')));
    });
  });

  group('gifToImages', () {
    test('no encoder args keeps the PNG default', () {
      final args = gifToImages(
        inputPath: 'in.gif',
        outputPattern: 'frames/f_%06d.png',
      );
      expect(args.last, 'frames/f_%06d.png');
      expect(args, isNot(contains('-q:v')));
    });

    test('JPEG gets an explicit quality and the matching extension', () {
      final args = gifToImages(
        inputPath: 'in.gif',
        outputPattern: 'frames/f_%06d.jpg',
        encoderArgs: const ['-c:v', 'mjpeg'],
        qualityArgs: qualityArgs(QualityPolicy.jpegQ, 90),
      );
      expect(args.last, 'frames/f_%06d.jpg');
      expect(args, containsAllInOrder(['-c:v', 'mjpeg']));
      expect(args, contains('-q:v'));
    });

    test('filters still come before the encoder args', () {
      final args = gifToImages(
        inputPath: 'in.gif',
        outputPattern: 'frames/f_%06d.webp',
        framestep: 2,
        encoderArgs: const ['-c:v', 'libwebp'],
      );
      final filterAt = args.indexOf('-filter_complex');
      final encoderAt = args.indexOf('-c:v');
      expect(filterAt, greaterThan(0));
      expect(encoderAt, greaterThan(filterAt));
    });
  });
}
