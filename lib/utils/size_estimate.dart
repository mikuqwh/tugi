// SPDX-License-Identifier: GPL-3.0-or-later

/// Predicted output sizes, for the "what will I get?" line in the UI.
///
/// These are RANGES, not promises. A GIF's byte count depends on its content
/// (how much moves between frames, how many colours it uses), and the same
/// ffmpeg setting can produce wildly different files. The bands below come
/// from `tool/wmprobe/calibrate_compress.sh`, which re-encodes three
/// deliberately different sources (high-detail test pattern, noisy gradient,
/// flat colour) and prints the implied exponents. Re-run it if the pipelines
/// change, and keep the numbers here in step with it.
///
/// Measured (480x270, 60 frames; see the script for the full table):
///
///   resolution ratio   size ratio = ratio^k, k between 0.90 and 1.74
///     0.8 -> 0.77 / 0.81 / 0.80        (testsrc / gradient / flat)
///     0.5 -> 0.36 / 0.33 / 0.51
///     0.2 -> 0.10 / 0.06 / 0.24
///
///   frame stride       size ratio = kept fraction x [0.80 .. 1.08]
///     1/2 -> 0.40 / 0.50 / 0.51
///     1/3 -> 0.27 / 0.33 / 0.35
///     1/5 -> 0.16 / 0.19 / 0.22
///
/// A flat-colour GIF barely shrinks with area (palette and per-frame overhead
/// dominate), which is why the ratio band is so wide: the honest answer for a
/// ratio is "a third to a half", not "263 KB".
// SPDX-License-Identifier: GPL-3.0-or-later

library size_estimate;

import 'dart:math' as math;

import 'package:format_core/format_core.dart';

/// A predicted byte-count range.
class SizeRange {
  const SizeRange(this.lowBytes, this.highBytes);

  final int lowBytes;
  final int highBytes;

  bool get isValid => highBytes > 0;

  /// The single number to show when a range would be false precision.
  int get midBytes => (lowBytes + highBytes) ~/ 2;

  /// How much smaller than [inputBytes] the estimate is, in percent.
  double savingsPercent(int inputBytes) {
    if (inputBytes <= 0) return 0;
    return (1 - midBytes / inputBytes) * 100;
  }
}

/// The measured exponent band for resolution scaling.
const double _minAreaExponent = 0.90;
const double _maxAreaExponent = 1.74;

/// Estimate what scaling a GIF to [ratio] of its width produces.
///
/// [ratio] is the linear scale factor the compress pipeline applies
/// (`scale=iw*<ratio>:-1`), so 0.5 means half the width AND half the height.
/// The area therefore falls by ratio^2, but bytes fall by ratio^k with
/// k < 2 in every measurement: GIF size is not proportional to pixels.
SizeRange estimateCompressedGif(int inputBytes, double ratio) {
  if (inputBytes <= 0 || ratio <= 0) return const SizeRange(0, 0);
  final r = ratio.clamp(0.01, 1.0);
  if (r >= 1.0) return SizeRange(inputBytes, inputBytes);
  final low = (inputBytes * math.pow(r, _maxAreaExponent)).round();
  final high = (inputBytes * math.pow(r, _minAreaExponent)).round();
  return SizeRange(
    math.min(low, high).clamp(1, inputBytes),
    math.max(low, high).clamp(1, inputBytes),
  );
}

/// Estimate what keeping one frame in every [step] produces.
///
/// The output keeps the full duration (the pipeline resamples with `fps=`,
/// measured: 60 frames / 3.00 s in, 20 frames / 3.00 s out at step 3), so the
/// cost scales with the KEPT fraction, plus the measured +/-10% spread.
SizeRange estimateFrameStepGif(
  int inputBytes,
  int frames,
  int step,
) {
  if (inputBytes <= 0 || frames <= 0 || step <= 1) {
    return SizeRange(inputBytes, inputBytes);
  }
  final kept = math.max(1, (frames / step).ceil());
  final fraction = kept / frames;
  final low = (inputBytes * fraction * 0.80).round();
  final high = (inputBytes * fraction * 1.08).round();
  return SizeRange(
    math.min(low, high).clamp(1, inputBytes),
    math.max(low, high).clamp(1, inputBytes),
  );
}

/// Estimate the size of an audio file from its bitrate and duration.
///
/// Unlike the image estimates this one is ARITHMETIC, not a calibration:
/// CBR audio is `bitrate x duration`, and container overhead is under 1%. The
/// small band exists so the UI does not promise a byte-exact number for VBR
/// encoders (mp3 `-q:a` varies with content).
///
/// [bitrateKbps] is the SOURCE's audio bitrate for a stream copy, or the
/// target bitrate for a re-encode. [duration] is the audio's length, not the
/// video's: equal today, different after any future trim feature.
SizeRange estimateAudioBytes({
  required int bitrateKbps,
  required Duration duration,
}) {
  if (bitrateKbps <= 0 || duration.inMilliseconds <= 0) {
    return const SizeRange(0, 0);
  }
  final seconds = duration.inMilliseconds / 1000.0;
  final center = bitrateKbps * 1000 / 8 * seconds;
  final low = (center * 0.97).round();
  final high = (center * 1.02).round();
  return SizeRange(math.min(low, high), math.max(low, high));
}

/// Source-relative byte bands per image format.
///
/// Measured by `tool/formats/calibrate_image.sh` on three deliberately
/// different 480x270 images (noisy photo, test pattern, flat colour). The
/// spread is the point: converting a photo to JPEG gave 1.77 bytes/pixel while
/// a flat colour gave 0.0135 -- 130x. Predicting from PIXELS alone is therefore
/// useless, so the estimate is a ratio of the SOURCE file's size instead, with
/// the measured min/max as the band.
///
/// Lossless targets are the exception: BMP/PPM/PAM/TIFF/EXR have a known
/// bytes-per-pixel, so they get exact(ish) numbers from the pixel count.
const Map<String, (double, double)> _imageRatioBands = {
  'png': (0.8, 3.0),
  'apng': (0.8, 3.0),
  'qoi': (0.9, 3.2),
  'gif': (0.1, 1.2),
  'jpg': (0.25, 1.7),
  'webp': (0.1, 0.9),
  'avif': (0.05, 0.8),
  'j2k': (0.3, 2.0),
  'ico': (0.05, 1.0),
  'tga': (1.5, 4.0),
};

/// Bytes per pixel for the uncompressed targets (measured, not guessed).
const Map<String, (double, double)> _imagePixelBands = {
  'bmp': (3.0, 3.0),
  'ppm': (3.0, 3.0),
  'pam': (3.0, 3.0),
  // TIFF came out 3.02 for the test pattern and 7.41 for the noisy photo.
  'tiff': (3.0, 7.5),
  // EXR: 12.3 bpp measured for the 64x64 probe; half-float RGB is 6 bpp and
  // 32-bit RGBA is 16.
  'exr': (8.0, 26.0),
};

/// Estimate the size of an image conversion.
///
/// Two models, because the formats are not comparable:
///  * **uncompressed** (BMP/PPM/PAM/TIFF/EXR): pixels x bytes-per-pixel. Near
///    exact for BMP, a band for TIFF/EXR where content changes the sparsity;
///  * **compressed** (PNG/JPEG/WebP/AVIF/...): a band of the SOURCE bytes, from
///    the measured table. A photo converted to JPEG lands near the top of its
///    band; a screenshot near the bottom.
///
/// For lossy formats a higher [quality] scales the band up (measured: JPEG q85
/// gave 1.77 bpp on the photo, q60 gave 1.16).
SizeRange estimateImageBytes({
  required int inputBytes,
  required int width,
  required int height,
  required FormatSpec format,
  required int quality,
}) {
  final pixels = width * height;
  final pixelsBand = _imagePixelBands[format.id];
  if (pixelsBand != null && pixels > 0) {
    final low = (pixels * pixelsBand.$1).round();
    final high = (pixels * pixelsBand.$2).round();
    return SizeRange(math.max(1, low), math.max(low, high));
  }

  if (inputBytes <= 0 || pixels <= 0) return const SizeRange(0, 0);
  final band = _imageRatioBands[format.id];
  if (band == null) return const SizeRange(0, 0);

  // Lossless re-encodes do not care about the quality slider; lossy ones do.
  final lossy = format.quality != QualityPolicy.none;
  final scale = lossy ? (quality.clamp(1, 100) / 85).clamp(0.3, 1.8) : 1.0;

  final low = (inputBytes * band.$1 * scale).round();
  final high = (inputBytes * band.$2 * scale).round();
  return SizeRange(math.max(1, math.min(low, high)), math.max(low, high));
}

/// Whether [format]'s estimate is a real number or a coarse band.
///
/// The UI says so: "≈ 2.1 MB" for BMP is a promise, "≈ 300 KB – 1.2 MB" for
/// JPEG is the truth.
bool isExactImageEstimate(FormatSpec format) =>
    _imagePixelBands.containsKey(format.id) &&
    format.id != 'exr' &&
    format.id != 'tiff';
