import 'package:format_core/format_core.dart';
import 'package:test/test.dart';

/// A slice of real `ffmpeg -encoders` output (8.1.2, the device build).
const String _encoders = r'''
Encoders:
 V..... = Video
 A..... = Audio
 S..... = Subtitle
 .F.... = Frame-level multithreading
 ..S... = Slice-level multithreading
 ...X.. = Codec is experimental
 ....B. = Supports draw_horiz_band
 .....D = Supports direct rendering method 1
 ------
 V....D libaom-av1           libaom AV1 (codec av1)
 V....D libwebp              libwebp WebP image (codec webp)
 V....D libwebp_anim         libwebp WebP image (codec webp)
 V....D libx264              libx264 H.264 (codec h264)
 V....D libx265              libx265 H.265 (codec hevc)
 V....D libvpx-vp9           libvpx VP9 (codec vp9)
 V....D mjpeg                MJPEG (Motion JPEG) (codec mjpeg)
 A....D aac                  AAC (Advanced Audio Coding)
 A....D libmp3lame           libmp3lame MP3 (codec mp3)
 A....D libopus              libopus Opus (codec opus)
 A....D libvorbis            libvorbis (codec vorbis)
 A....D flac                 FLAC (Free Lossless Audio Codec)
 V....D png                  PNG (Portable Network Graphics) (codec png)
''';

/// A slice of real `ffmpeg -muxers` output: 2-column flags on this build.
const String _muxers = r'''
Muxers:
  E avif             AVIF muxer
  E apng             Animated Portable Network Graphics
  E gif              CompuServe Graphics Interchange Format (GIF)
  E ico              ICO (Windows Icon)
  E image2           image2 sequence
  E ipod             iPod H.264 MP4 (MPEG-4 Part 14)
  E matroska         Matroska
  E mov              QuickTime / MOV
  E mp3              MP3 (MPEG audio layer 3)
  E mp4              MP4 (MPEG-4 Part 14)
  D mp4              MP4 (MPEG-4 Part 14)
  E webm             WebM
''';

void main() {
  group('parseCodecNames on encoders', () {
    test('finds the codecs we depend on', () {
      final names = parseCodecNames(_encoders);
      expect(
          names, containsAll(['libaom-av1', 'libwebp', 'libx264', 'libx265']));
      expect(names, containsAll(['libmp3lame', 'libopus', 'libvorbis', 'aac']));
      expect(names, contains('png'));
    });

    test('does not mistake the flag legend for a codec', () {
      final names = parseCodecNames(_encoders);
      expect(names.any((n) => n.contains('=')), isFalse);
      expect(names, isNot(contains('Encoders')));
      expect(names, isNot(contains('V....D')));
      expect(names, isNot(contains('------')));
    });

    test('libjxl is absent from the current build', () {
      // This is the whole reason the JXL step exists: the shipped package has
      // no libjxl, so the probe must report it missing rather than let the UI
      // offer it.
      expect(parseCodecNames(_encoders), isNot(contains('libjxl')));
    });
  });

  group('parseCodecNames on muxers', () {
    test('reads two-column muxer flags', () {
      final names = parseCodecNames(_muxers);
      expect(names,
          containsAll(['avif', 'apng', 'gif', 'mp4', 'webm', 'matroska']));
    });

    test('deduplicates a name that appears as both muxer and demuxer', () {
      final names = parseCodecNames(_muxers);
      expect(names.where((n) => n == 'mp4').length, 1);
    });
  });

  group('capability decisions', () {
    test('a format without a probe token is always available', () {
      // png/bmp/tiff are compiled into ffmpeg itself; the probe has nothing
      // to look for.
      final png = formatById('png')!;
      expect(png.probeToken, isNull);
    });

    test('a format whose token is missing is reported unavailable', () {
      final names = parseCodecNames(_encoders);
      final avif = formatById('avif')!;
      expect(names.contains(avif.probeToken), isTrue);

      final fakeBuild = names.difference({'libaom-av1'});
      expect(fakeBuild.contains(avif.probeToken), isFalse);
    });
  });

  test('malformed input never throws and never invents multi-word names', () {
    expect(parseCodecNames(''), isEmpty);
    // The parser is only ever fed ffmpeg output; what matters is that a
    // truncated or garbage listing degrades to "some identifier-shaped
    // tokens" instead of an exception or a name with a space in it.
    final names = parseCodecNames('not an ffmpeg listing at all');
    for (final n in names) {
      expect(n, isNot(contains(' ')));
      expect(n, matches(r'^[a-z0-9][a-zA-Z0-9_\-]*$'));
    }
  });
}
