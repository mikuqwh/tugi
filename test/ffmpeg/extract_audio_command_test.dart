// SPDX-License-Identifier: GPL-3.0-or-later

/// The audio-extraction command shape.
///
/// The copy path is the one worth pinning: a wrong `-c:a copy` produces a file
/// that opens but has no audio, and the mistake is invisible until the user
/// plays it.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ffmpeg/audio_commands.dart';

void main() {
  test('a stream copy maps only the first audio stream and never re-encodes',
      () {
    final args = extractAudio(
      inputPath: 'in.mp4',
      outputPath: 'out.m4a',
      audioArgs: const ['-c:a', 'copy'],
    );
    expect(args, [
      '-y',
      '-i',
      'in.mp4',
      '-vn',
      '-map',
      '0:a:0',
      '-c:a',
      'copy',
      'out.m4a',
    ]);
    // No quality arguments on the copy path: there is nothing to encode, and
    // `-b:a` alongside `copy` makes ffmpeg abort.
    expect(args, isNot(contains('-b:a')));
  });

  test('a re-encode carries the codec and the bitrate', () {
    final args = extractAudio(
      inputPath: 'in.mov',
      outputPath: 'out.mp3',
      audioArgs: const ['-c:a', 'libmp3lame'],
      qualityArgs: const ['-b:a', '192k'],
    );
    expect(args, containsAllInOrder(['-c:a', 'libmp3lame']));
    expect(args, containsAllInOrder(['-b:a', '192k']));
    expect(args.last, 'out.mp3');
  });

  test('an explicit muxer is emitted before the output path', () {
    // Raw AAC needs `-f adts`; without it ffmpeg guesses from the extension
    // and fails on `.aac`.
    final args = extractAudio(
      inputPath: 'in.mp4',
      outputPath: 'out.aac',
      audioArgs: const ['-c:a', 'copy'],
      muxer: 'adts',
    );
    expect(args, containsAllInOrder(['-f', 'adts', 'out.aac']));
  });
}
