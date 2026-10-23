// SPDX-License-Identifier: GPL-3.0-or-later

/// Images to Video with a container choice.
///
/// The pipeline renders one segment per image and then joins them with a
/// stream copy, so the format has to be decided BEFORE the first segment is
/// written: VP9 segments must live in WebM, and an H.265 mp4 needs its `hvc1`
/// tag on every segment to survive the join. These tests pin both halves.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/ffmpeg/commands.dart';

void main() {
  const canvas = (320, 240);

  group('imagesToVideoSegment', () {
    test('defaults to H.264 with the even-height pix_fmt', () {
      final args = imagesToVideoSegment(
        inputPath: 'a.png',
        outputPath: 's1.mp4',
        canvas: canvas,
        seconds: 1,
        fps: 12,
      );
      expect(
          args, containsAllInOrder(['-c:v', 'libx264', '-pix_fmt', 'yuv420p']));
    });

    test('takes the encoder from the chosen format', () {
      final args = imagesToVideoSegment(
        inputPath: 'a.png',
        outputPath: 's1.webm',
        canvas: canvas,
        seconds: 1,
        fps: 12,
        encoderArgs: formatById('webm_vp9')!.encoderArgs,
      );
      expect(args, containsAllInOrder(['-c:v', 'libvpx-vp9']));
      expect(args.join(' '), isNot(contains('libx264')));
    });

    test('H.265 keeps its hvc1 tag on every segment', () {
      final args = imagesToVideoSegment(
        inputPath: 'a.png',
        outputPath: 's1.mp4',
        canvas: canvas,
        seconds: 1,
        fps: 12,
        encoderArgs: formatById('mp4_h265')!.encoderArgs,
      );
      expect(args, containsAllInOrder(['-c:v', 'libx265', '-tag:v', 'hvc1']));
    });
  });

  group('imagesToVideoSegments', () {
    test('mp4 join keeps faststart and adds no muxer', () {
      final args = imagesToVideoSegments(
        concatListPath: 'list.txt',
        outputPath: 'out.mp4',
      );
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      // Only the concat DEMUXER's `-f` is present; no output muxer is forced.
      expect(args.where((a) => a == '-f').length, 1);
    });

    test('webm join names the muxer and drops faststart', () {
      final args = imagesToVideoSegments(
        concatListPath: 'list.txt',
        outputPath: 'out.webm',
        muxer: 'webm',
      );
      expect(args, containsAllInOrder(['-f', 'webm']));
      expect(args.join(' '), isNot(contains('+faststart')));
    });

    test('mkv join uses the matroska muxer', () {
      final args = imagesToVideoSegments(
        concatListPath: 'list.txt',
        outputPath: 'out.mkv',
        muxer: 'matroska',
      );
      expect(args, containsAllInOrder(['-f', 'matroska']));
    });

    test('the join is always a stream copy', () {
      for (final muxer in [null, 'webm', 'matroska']) {
        final args = imagesToVideoSegments(
          concatListPath: 'list.txt',
          outputPath: 'out',
          muxer: muxer,
        );
        expect(args, containsAllInOrder(['-c', 'copy']), reason: '$muxer');
      }
    });
  });
}
