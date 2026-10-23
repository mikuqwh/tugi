// SPDX-License-Identifier: GPL-3.0-or-later

/// Build the audio-extraction command (video -> audio).
///
/// This is the "视频转音频" path. Two shapes matter:
///
///  * **stream copy** (`-c:a copy`): the audio is remuxed, never decoded. A
///    2 s test file extracted in well under a second on the device, and the
///    audio bytes are identical to the source. Only valid when the target
///    container accepts the source codec -- see `canStreamCopyAudio`.
///  * **re-encode**: mp3/flac/wav/... when it does not.
///
/// `-map 0:a:0` picks the first audio stream explicitly. `-vn` alone would
/// still let the default stream selection drag along subtitles or data
/// streams, and a file with several audio tracks would produce an output the
/// user did not ask for.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

/// Command arguments for extracting audio.
///
/// [audioArgs] is the codec choice (`['-c:a', 'libmp3lame']` or
/// `['-c:a', 'copy']`); [qualityArgs] the bitrate/quality pair when the codec
/// takes one (an empty list for a stream copy). [muxer] forces `-f` for the
/// containers whose extension is not enough (raw `aac`).
List<String> extractAudio({
  required String inputPath,
  required String outputPath,
  required List<String> audioArgs,
  List<String> qualityArgs = const [],
  String? muxer,
}) {
  return [
    '-y',
    '-i',
    inputPath,
    '-vn',
    '-map',
    '0:a:0',
    ...audioArgs,
    ...qualityArgs,
    if (muxer != null) ...['-f', muxer],
    outputPath,
  ];
}
