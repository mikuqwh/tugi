/// Conversion command shapes (Tugi S3).
///
/// The alpha flatten is the one worth pinning: getting it wrong does not fail,
/// it just writes transparent pixels as whatever RGB they carried (usually
/// black) and nobody notices until the file is opened elsewhere.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/ffmpeg/convert_commands.dart';

FormatSpec _spec(String id) => formatById(id)!;

void main() {
  group('convertImage', () {
    test('a plain still conversion is input + codec + quality + output', () {
      final args = convertImage(
        inputPath: 'in.png',
        outputPath: 'out.jpg',
        format: _spec('jpg'),
        quality: 85,
      );
      expect(args,
          ['-y', '-i', 'in.png', '-c:v', 'mjpeg', '-q:v', '6', 'out.jpg']);
    });

    test('an alpha-capable target never flattens', () {
      final args = convertImage(
        inputPath: 'in.png',
        outputPath: 'out.webp',
        format: _spec('webp'),
        quality: 85,
      );
      expect(args.join(' '), isNot(contains('color=c=')));
      expect(args, containsAllInOrder(['-c:v', 'libwebp']));
    });

    test('flattening puts the colour UNDER the image, then forces rgb24', () {
      final args = convertImage(
        inputPath: 'in.png',
        outputPath: 'out.jpg',
        format: _spec('jpg'),
        quality: 85,
        backgroundArgb: 0xFFFFFF,
        width: 800,
        height: 600,
      );
      final graph = args[args.indexOf('-filter_complex') + 1];
      // The colour layer is input 1 and the image input 0, so the image is on
      // top; then the 8-bit conversion that drops the alpha channel.
      expect(graph, contains('[1:v][0:v]overlay=format=auto'));
      expect(graph, endsWith('format=rgb24'));
      expect(
          args,
          containsAllInOrder(
              ['-f', 'lavfi', '-i', 'color=c=0xffffff:s=800x600']));
    });

    test('scaling is a single vf expression', () {
      final args = convertImage(
        inputPath: 'in.png',
        outputPath: 'out.png',
        format: _spec('png'),
        width: 640,
      );
      expect(args[args.indexOf('-vf') + 1], 'scale=640:-2');
    });

    test('dropping animation emits one frame', () {
      final args = convertImage(
        inputPath: 'in.gif',
        outputPath: 'out.png',
        format: _spec('png'),
        dropAnimation: true,
      );
      expect(args, containsAllInOrder(['-frames:v', '1']));
    });

    test('apng forces its muxer, because .apng alone is not enough', () {
      final args = convertImage(
        inputPath: 'in.gif',
        outputPath: 'out.apng',
        format: _spec('apng'),
      );
      expect(args, containsAllInOrder(['-f', 'apng', 'out.apng']));
    });
  });

  group('convertVideo', () {
    test('h264 gets crf, aac audio and faststart', () {
      final args = convertVideo(
        inputPath: 'in.mov',
        outputPath: 'out.mp4',
        format: _spec('mp4_h264'),
        quality: 75,
      );
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-crf']));
      expect(args, containsAllInOrder(['-c:a', 'aac']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
    });

    test('webm takes opus, not aac', () {
      final args = convertVideo(
        inputPath: 'in.mp4',
        outputPath: 'out.webm',
        format: _spec('webm_vp9'),
      );
      expect(args, containsAllInOrder(['-c:a', 'libopus']));
      expect(args.join(' '), isNot(contains('-c:a aac')));
    });

    test('dropping audio emits -an', () {
      final args = convertVideo(
        inputPath: 'in.mp4',
        outputPath: 'out.mp4',
        format: _spec('mp4_h264'),
        dropAudio: true,
      );
      expect(args, contains('-an'));
      expect(args.join(' '), isNot(contains('-c:a')));
    });

    test('hardware switches the encoder and swaps crf for a bitrate', () {
      final args = convertVideo(
        inputPath: 'in.mov',
        outputPath: 'out.mp4',
        format: _spec('mp4_h264'),
        quality: 75,
        hardware: true,
      );
      expect(args, containsAllInOrder(['-c:v', 'h264_mediacodec']));
      expect(args, contains('-b:v'));
      // MediaCodec does not take crf; sending it would be silently ignored.
      expect(args, isNot(contains('-crf')));
    });

    test('hardware is ignored for codecs the device cannot hard-encode', () {
      final args = convertVideo(
        inputPath: 'in.mp4',
        outputPath: 'out.webm',
        format: _spec('webm_vp9'),
        hardware: true,
      );
      expect(args, containsAllInOrder(['-c:v', 'libvpx-vp9']));
    });

    test('scale and fps share one filter chain', () {
      final args = convertVideo(
        inputPath: 'in.mp4',
        outputPath: 'out.mp4',
        format: _spec('mp4_h264'),
        width: 720,
        fps: 24,
      );
      expect(args[args.indexOf('-vf') + 1], 'scale=720:-2,fps=24.000');
    });
  });

  group('convertAudio', () {
    test('a copy is just -c:a copy', () {
      final args = convertAudio(
        inputPath: 'in.m4a',
        outputPath: 'out.m4a',
        format: _spec('m4a'),
        copy: true,
      );
      expect(args, containsAllInOrder(['-c:a', 'copy']));
      expect(args, isNot(contains('-b:a')));
    });

    test('a re-encode carries bitrate', () {
      final args = convertAudio(
        inputPath: 'in.m4a',
        outputPath: 'out.mp3',
        format: _spec('mp3'),
        quality: 192,
      );
      expect(args, containsAllInOrder(['-c:a', 'libmp3lame']));
      expect(args, containsAllInOrder(['-b:a', '192k']));
    });

    test('raw aac needs its adts muxer', () {
      final args = convertAudio(
        inputPath: 'in.m4a',
        outputPath: 'out.aac',
        format: _spec('aac'),
        quality: 128,
        copy: true,
      );
      expect(args, containsAllInOrder(['-f', 'adts']));
    });
  });
}
