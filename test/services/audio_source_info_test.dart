// SPDX-License-Identifier: GPL-3.0-or-later

/// The source-audio summary the screen shows under the file name.
///
/// This exists because the first build printed "0 声道": ffprobe's channel
/// layout is a NAME (`stereo`), not a number, and reading it as an int gave a
/// zero that the label then printed literally.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tugi/services/audio_extract_service.dart';

SourceAudioInfo _info({
  int channels = 2,
  int sampleRate = 44100,
  String codec = 'aac',
}) =>
    SourceAudioInfo(
      duration: const Duration(seconds: 8),
      codec: codec,
      bitrateKbps: 128,
      sampleRate: sampleRate,
      channels: channels,
      audioTrackCount: 1,
    );

void main() {
  test('stereo and mono are named, not numbered', () {
    expect(_info(channels: 2).codecLabel, contains('立体声'));
    expect(_info(channels: 1).codecLabel, contains('单声道'));
    expect(_info(channels: 6).codecLabel, contains('6 声道'));
  });

  test('an unknown channel count is omitted instead of printed as zero', () {
    final label = _info(channels: 0).codecLabel;
    expect(label, isNot(contains('0 声道')));
    expect(label, isNot(contains('声道')));
    // The rest of the label survives.
    expect(label, contains('aac'));
    expect(label, contains('44.1 kHz'));
  });

  test('a source with no audio does not pretend to have a codec', () {
    expect(_info(codec: '').codecLabel, '未知');
  });

  test('an unknown sample rate drops the kHz part', () {
    expect(_info(sampleRate: 0).codecLabel, isNot(contains('kHz')));
  });
}
