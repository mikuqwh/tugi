/// How a format exposes "quality".
///
/// The encoders in the ffmpeg-kit build disagree about this in every possible
/// way, so it is modelled explicitly instead of passing a number through and
/// hoping:
///
///  * `jpegQ`  -- mjpeg's `-q:v`, 1 is best and 31 is worst (INVERTED relative
///    to the UI's 1..100 scale, where 100 is best).
///  * `webpQ`  -- libwebp's `-quality`, 0..100, 100 best.
///  * `crf`    -- AVIF/AV1's `-crf`, 0..63, 0 best.
///  * `x264Crf`-- x264/x265's `-crf`, 0..51, 0 best.
///  * `audioBitrate` -- audio encoders take a bitrate, not a quality.
///  * `none`   -- lossless or fixed (PNG, TIFF, BMP, QOI, GIF, ...).
///
/// The UI always speaks 1..100 (100 = best); [qualityArgs] is the only place
/// that translation happens.
enum QualityPolicy {
  none,
  jpegQ,
  webpQ,
  crf,
  x264Crf,
  audioBitrate,
}

/// Minimum and maximum UI quality worth offering per policy.
///
/// The lower bound is not 1 for the lossy image policies: `-q:v 31` is a
/// grey mess nobody asks for, and `webp -quality 1` is worse than quantised
/// GIF. The UI ranges below were picked so every value produces something a
/// person would accept.
int minQualityFor(QualityPolicy policy) => switch (policy) {
      QualityPolicy.none => 100,
      QualityPolicy.jpegQ => 10,
      QualityPolicy.webpQ => 10,
      QualityPolicy.crf => 10,
      QualityPolicy.x264Crf => 10,
      QualityPolicy.audioBitrate => 32,
    };

int maxQualityFor(QualityPolicy policy) => switch (policy) {
      QualityPolicy.none => 100,
      QualityPolicy.jpegQ => 100,
      QualityPolicy.webpQ => 100,
      QualityPolicy.crf => 63,
      QualityPolicy.x264Crf => 51,
      // Not a UI scale: kbps. 320 kbps is the practical ceiling for mp3/aac.
      QualityPolicy.audioBitrate => 320,
    };

/// The default UI value for a policy (what the slider starts at).
int defaultQualityFor(QualityPolicy policy) => switch (policy) {
      QualityPolicy.none => 100,
      QualityPolicy.jpegQ => 85,
      QualityPolicy.webpQ => 85,
      QualityPolicy.crf => 30,
      QualityPolicy.x264Crf => 23,
      QualityPolicy.audioBitrate => 192,
    };

/// The ffmpeg arguments for a UI quality value.
///
/// [quality] is interpreted per policy: the 1..100 best-is-high scale for the
/// image policies, and kbps for [QualityPolicy.audioBitrate].
List<String> qualityArgs(QualityPolicy policy, int quality) {
  switch (policy) {
    case QualityPolicy.none:
      return const [];
    case QualityPolicy.jpegQ:
      // UI 100 -> -q:v 1 (best), UI 10 -> -q:v 28. 31 is never emitted: it
      // is the "2x2 blocks" end of the scale and only wastes the user's time.
      final clamped = quality.clamp(1, 100);
      final q = 1 + ((100 - clamped) * 27 / 90).round();
      return ['-q:v', '$q'];
    case QualityPolicy.webpQ:
      return ['-quality', '${quality.clamp(0, 100)}'];
    case QualityPolicy.crf:
      // UI 100 -> crf 0 (best), UI 10 -> crf 57.
      final clamped = quality.clamp(1, 100);
      final crf = ((100 - clamped) * 63 / 90).round();
      return ['-crf', '$crf'];
    case QualityPolicy.x264Crf:
      final clamped = quality.clamp(1, 100);
      final crf = ((100 - clamped) * 51 / 90).round();
      return ['-crf', '$crf'];
    case QualityPolicy.audioBitrate:
      return ['-b:a', '${quality.clamp(32, 320)}k'];
  }
}
