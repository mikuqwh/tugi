import 'package:format_core/format_core.dart';
import 'package:test/test.dart';

void main() {
  const fullBuild = {
    'libwebp',
    'libaom-av1',
    'libx264',
    'libx265',
    'libvpx-vp9',
    'libmp3lame',
    'libopus',
    'libvorbis',
    'apng',
    'avif',
    'mp4',
    'webm',
  };

  test('formats without a probe token are always available', () {
    for (final id in ['png', 'bmp', 'tiff', 'gif', 'ico', 'qoi']) {
      expect(isFormatAvailable(formatById(id)!, const {}), isTrue, reason: id);
    }
  });

  test('a missing encoder removes the format', () {
    final noWebp = fullBuild.difference({'libwebp'});
    expect(isFormatAvailable(formatById('webp')!, noWebp), isFalse);
    expect(isFormatAvailable(formatById('avif')!, noWebp), isTrue);
  });

  test('a missing muxer removes the format even when the encoder exists', () {
    // APNG has no separate encoder; it is an image2-family muxer. Without the
    // muxer the format silently degrades to a single frame, so it must be
    // reported unavailable rather than offered.
    final noApng = fullBuild.difference({'apng'});
    expect(isFormatAvailable(formatById('apng')!, noApng), isFalse);
    expect(isFormatAvailable(formatById('apng')!, fullBuild), isTrue);
  });

  test('availabilityFor keeps unavailable entries so the UI can explain', () {
    final rows = availabilityFor(const {'mp4'}, MediaKind.video);
    expect(rows, isNotEmpty);
    final mp4 = rows.firstWhere((r) => r.$1.id == 'mp4_h264');
    // x264 is absent from this fake build: still listed, flagged unavailable.
    expect(mp4.$2, isFalse);
  });

  test('availableFormats narrows to the source kind', () {
    final ids = availableFormats(fullBuild, kind: MediaKind.audio)
        .map((f) => f.id)
        .toList();
    expect(ids, containsAll(['mp3', 'flac', 'wav']));
    expect(ids, isNot(contains('mp4_h264')));
  });
}
