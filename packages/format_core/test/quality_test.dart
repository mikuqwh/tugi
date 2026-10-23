import 'package:format_core/format_core.dart';
import 'package:test/test.dart';

void main() {
  group('qualityArgs', () {
    test('lossless formats emit nothing', () {
      for (final q in [1, 50, 100]) {
        expect(qualityArgs(QualityPolicy.none, q), isEmpty);
      }
    });

    test('jpeg inverts the UI scale (100 is best, -q:v 1)', () {
      expect(qualityArgs(QualityPolicy.jpegQ, 100), ['-q:v', '1']);
      expect(qualityArgs(QualityPolicy.jpegQ, 10), ['-q:v', '28']);
      // Never 31: that is the unusable end of mjpeg's scale.
      for (var q = 10; q <= 100; q++) {
        final v = int.parse(qualityArgs(QualityPolicy.jpegQ, q).last);
        expect(v, inInclusiveRange(1, 28), reason: 'ui=$q');
      }
    });

    test('jpeg quality is monotonic: better UI value means lower -q:v', () {
      var last = 99;
      for (var q = 10; q <= 100; q += 10) {
        final v = int.parse(qualityArgs(QualityPolicy.jpegQ, q).last);
        expect(v, lessThanOrEqualTo(last), reason: 'ui=$q');
        last = v;
      }
    });

    test('webp passes the UI value straight through', () {
      expect(qualityArgs(QualityPolicy.webpQ, 85), ['-quality', '85']);
    });

    test('crf policies invert like jpeg', () {
      expect(qualityArgs(QualityPolicy.crf, 100), ['-crf', '0']);
      expect(qualityArgs(QualityPolicy.x264Crf, 100), ['-crf', '0']);
      // UI 10 is the worst the UI offers, and it maps to the WORST end of
      // each crf range (63 for AV1, 51 for x264): the full range is used, so
      // a user who asks for the smallest file gets it.
      expect(qualityArgs(QualityPolicy.crf, 10), ['-crf', '63']);
      expect(qualityArgs(QualityPolicy.x264Crf, 10), ['-crf', '51']);
    });

    test('audio takes kbps, clamped to something encoders accept', () {
      expect(qualityArgs(QualityPolicy.audioBitrate, 192), ['-b:a', '192k']);
      expect(qualityArgs(QualityPolicy.audioBitrate, 8), ['-b:a', '32k']);
      expect(qualityArgs(QualityPolicy.audioBitrate, 999), ['-b:a', '320k']);
    });
  });

  group('quality ranges', () {
    test('defaults sit inside their own range', () {
      for (final policy in QualityPolicy.values) {
        expect(defaultQualityFor(policy),
            inInclusiveRange(minQualityFor(policy), maxQualityFor(policy)),
            reason: policy.name);
      }
    });

    test('the image policies advertise a 1..100 UI scale', () {
      for (final p in [QualityPolicy.jpegQ, QualityPolicy.webpQ]) {
        expect(minQualityFor(p), 10);
        expect(maxQualityFor(p), 100);
      }
    });
  });
}
