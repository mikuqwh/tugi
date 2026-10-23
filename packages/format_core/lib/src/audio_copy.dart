/// When an audio stream can be COPYED into a container instead of re-encoded.
///
/// This is the difference between "extract in 50 ms with zero loss" and
/// "re-encode for 30 seconds". It is a pure function of (target format, source
/// codec) so the UI can decide BEFORE running anything whether to promise the
/// user "无损提取".
///
/// The pairs below are the ones ffmpeg actually accepts; everything else is
/// safer re-encoded. Deliberately conservative: a wrong "yes" produces a broken
/// file, a wrong "no" only costs a re-encode.
bool canStreamCopyAudio(String formatId, String sourceCodec) {
  final codec = sourceCodec.toLowerCase();
  switch (formatId) {
    case 'm4a':
    case 'aac':
      return codec == 'aac';
    case 'mp3':
      return codec == 'mp3';
    case 'flac':
      return codec == 'flac';
    case 'ogg':
      // The Ogg container carries both Vorbis and Opus.
      return codec == 'vorbis' || codec == 'opus';
    case 'opus':
      return codec == 'opus';
    case 'wav':
      return codec.startsWith('pcm_');
    default:
      return false;
  }
}

/// The codec name a container is expected to hold, for messages like
/// "源音轨是 aac，可以直接复制".
String expectedAudioCodec(String formatId) => switch (formatId) {
      'm4a' || 'aac' => 'aac',
      'mp3' => 'mp3',
      'flac' => 'flac',
      'ogg' => 'vorbis',
      'opus' => 'opus',
      'wav' => 'pcm',
      _ => '',
    };
