import 'package:format_core/format_core.dart';
import 'package:test/test.dart';

void main() {
  group('registry invariants', () {
    test('ids are unique', () {
      final ids = formatRegistry.map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every audio format uses an audio encoder or none', () {
      for (final f in formatRegistry.where((f) => f.kind == MediaKind.audio)) {
        final hasAudioCodec = f.encoderArgs.contains('-c:a');
        expect(hasAudioCodec, isTrue, reason: f.id);
      }
    });

    test('image encoders never claim a video codec', () {
      for (final f in formatRegistry.where((f) => f.kind == MediaKind.image)) {
        expect(f.encoderArgs.contains('-c:a'), isFalse, reason: f.id);
      }
    });

    test('only animated formats claim animation', () {
      for (final f in formatRegistry) {
        if (f.supportsAnimation) {
          expect(f.kind, MediaKind.animated, reason: f.id);
        }
      }
    });

    test('apng carries an explicit muxer', () {
      // Writing `.png` without `-f apng` goes through image2 and silently
      // drops every frame but the first -- measured on device.
      final apng = formatById('apng')!;
      expect(apng.muxer, 'apng');
      expect(apng.extension, 'apng');
    });

    test('h265 carries the hvc1 tag so players recognise it', () {
      final h265 = formatById('mp4_h265')!;
      expect(h265.encoderArgs, containsAllInOrder(['-tag:v', 'hvc1']));
    });

    test('lossy image formats expose a quality knob, lossless ones do not', () {
      expect(formatById('jpg')!.quality, QualityPolicy.jpegQ);
      expect(formatById('webp')!.quality, QualityPolicy.webpQ);
      expect(formatById('avif')!.quality, QualityPolicy.crf);
      for (final id in ['png', 'bmp', 'tiff', 'qoi', 'gif', 'apng', 'ico']) {
        expect(formatById(id)!.quality, QualityPolicy.none, reason: id);
      }
    });

    test('the format id matches its encoder where a token is declared', () {
      // Guards copy-paste mistakes: a spec that says it needs libwebp must
      // actually ask for libwebp.
      final byToken = {
        'libwebp': 'webp',
        'libaom-av1': 'avif',
        'libmp3lame': 'mp3',
        'libopus': 'opus',
        'libvorbis': 'ogg',
        'libx264': 'mp4_h264',
        'libx265': 'mp4_h265',
        'libvpx-vp9': 'webm_vp9',
      };
      byToken.forEach((token, id) {
        expect(formatById(id)!.probeToken, token, reason: id);
      });
    });
  });

  group('formatsFor', () {
    test('an image offers images and animations, never audio', () {
      final kinds = formatsFor(MediaKind.image).map((f) => f.kind).toSet();
      expect(kinds, {MediaKind.image, MediaKind.animated});
    });

    test('a video offers video containers and audio extraction', () {
      final ids = formatsFor(MediaKind.video).map((f) => f.id);
      expect(ids, containsAll(['mp4_h264', 'webm_vp9', 'mp3', 'flac']));
      expect(ids, isNot(contains('png')));
    });

    test('audio only offers audio', () {
      for (final f in formatsFor(MediaKind.audio)) {
        expect(f.kind, MediaKind.audio, reason: f.id);
      }
    });

    test('an animated source can become a still image', () {
      final ids = formatsFor(MediaKind.animated).map((f) => f.id);
      expect(ids, containsAll(['png', 'jpg', 'gif', 'apng']));
    });
  });
}
