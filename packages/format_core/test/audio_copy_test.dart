import 'package:format_core/format_core.dart';
import 'package:test/test.dart';

void main() {
  test('aac into m4a/aac can be copied', () {
    expect(canStreamCopyAudio('m4a', 'aac'), isTrue);
    expect(canStreamCopyAudio('aac', 'aac'), isTrue);
    expect(canStreamCopyAudio('m4a', 'AAC'), isTrue);
  });

  test('mismatched codec is re-encoded, not copied', () {
    expect(canStreamCopyAudio('m4a', 'mp3'), isFalse);
    expect(canStreamCopyAudio('mp3', 'aac'), isFalse);
    expect(canStreamCopyAudio('flac', 'aac'), isFalse);
  });

  test('ogg accepts both vorbis and opus', () {
    expect(canStreamCopyAudio('ogg', 'vorbis'), isTrue);
    expect(canStreamCopyAudio('ogg', 'opus'), isTrue);
    expect(canStreamCopyAudio('ogg', 'aac'), isFalse);
  });

  test('wav copies any pcm flavour', () {
    expect(canStreamCopyAudio('wav', 'pcm_s16le'), isTrue);
    expect(canStreamCopyAudio('wav', 'pcm_f32le'), isTrue);
    expect(canStreamCopyAudio('wav', 'aac'), isFalse);
  });

  test('an unknown target never claims copy', () {
    expect(canStreamCopyAudio('nope', 'aac'), isFalse);
  });

  test('expectedAudioCodec describes the container', () {
    expect(expectedAudioCodec('m4a'), 'aac');
    expect(expectedAudioCodec('mp3'), 'mp3');
    expect(expectedAudioCodec('ogg'), 'vorbis');
    expect(expectedAudioCodec('nope'), '');
  });
}
