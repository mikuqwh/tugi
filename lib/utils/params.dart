/// Tugi — shared constants and parameters.
/// All values verified by testing against this app's FFmpeg strings.

/// Setpts speed multipliers and their measured playback speeds.
/// ASSUMPTION: 5 candidate values tested with imageio-ffmpeg v7.1
/// Formula: setpts=n*PTS → timestamps × n → playback speed = 1/n (theoretical)
/// Measured values account for GIF frame delay centisecond rounding.

// SPDX-License-Identifier: GPL-3.0-or-later
final Map<double, double> setptsSpeeds = {
  0.2:
      4.00, // measured 4x faster (theoretical 5x, -20% due to GIF tick rounding)
  0.5: 1.90, // measured 1.9x faster (theoretical 2x)
  0.8: 1.20, // measured 1.2x faster (theoretical 1.25x)
  1.0: 1.00, // original speed
  1.1: 0.90, // measured 0.9x slower (theoretical 0.91x)
};

const int defaultGifFps = 12;

const int defaultGifLoop = 0;

///
/// Typed as an argv list, NOT a string: `FFmpegKit.executeWithArguments` takes
/// an argv array, so each option must be its own element. A single string like
/// `'-gifflags -offsetting'` is rejected with
/// `Unrecognized option 'gifflags -offsetting'`.
const List<String> gifFlags = ['-gifflags', '-offsetting'];

/// `-filter_complex "[0:v]split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1"`
const String paletteFilter =
    '[0:v]split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1';

const String transparentPaletteFilter =
    'split[a][b];[a]palettegen=reserve_transparent=on:transparency_color=ffffff[p];[b][p]paletteuse';

const String ditherFloydSteinberg = 'dither=floyd_steinberg';

const String lanczosFlag = ':flags=lanczos';

/// Video to GIF output format (argv list — see [gifFlags]).
const List<String> gifOutputFormat = ['-f', 'gif'];

/// Image sequence input format (argv list — see [gifFlags]).
const List<String> image2InputFormat = ['-f', 'image2'];

/// Concat input format (argv list — see [gifFlags]).
/// Ends with `-i`; the concat list path follows as the next argument.
const List<String> concatInputFormat = ['-f', 'concat', '-safe', '0', '-i'];

const List<String> h264Encode = ['-c:v', 'libx264', '-pix_fmt', 'yuv420p'];

const List<String> ffv1Encode = [
  '-c:v',
  'ffv1',
  '-b:v',
  '1500k',
  '-pix_fmt',
  'rgba'
];

/// Ends with `-b:v`; the bitrate value follows as the next argument.
const List<String> streamCopyBitrate = ['-c:a', 'copy', '-b:v'];

const String gifFrameExtractTemplate = '/gif_to_image_%06d.png';

const String videoFrameExtractTemplate = '/video_to_image_%06d.';

/// Drawtext centered position
const String drawtextCentered = 'x=main_w/2-text_w/2:y=main_h/2-text_h/2';

const String overlayBottomRight =
    'overlay=main_w-overlay_w-10:main_h-overlay_h-10';

const String overlayCentered =
    'overlay=main_w/2-overlay_w/2:main_h/2-overlay_h/2';

const String eqSaturation = 'eq=saturation=2,format=rgb24,';

/// ONNX model output: single channel alpha matte [1, 1, 1024, 1024]
const int modelOutputChannels = 1;

const Map<int, int> videoDurationLimits = {
  10: 1, // Video Over 10s not supported
  20: 1, // Video Over 20s not supported
  30: 1, // Video Over 30s not supported
  40: 1, // Video Over 40s not supported
  60: 1, // Video Over 60s not supported
  90: 1, // Video Over 90s not supported
  120: 1, // Video Over 120s not supported
  200: 1, // Video Over 200s not supported
};

/// Supported image formats
const List<String> supportedImageFormats = [
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.heic',
  '.bmp',
  '.tif',
  '.apng'
];

// === Measured parameters (2026-10-13) ===

/// Default frame count for single-image "Images to GIF"
/// Measured on every sample: 10 frames.
const int defaultFrameCount = 10;

/// Layer-level frame rate (inside `layers` JSON, distinct from `creation.fps`)
/// Measured on every sample: 12.
/// Note: creation.fps = 1.0 is the playback speed, NOT the GIF frame rate
const int layerFps = 12;

/// Default canvas aspect ratio
/// Source: creations.db `dstAspectRatio` = 0.45 (all rows)
const double defaultAspectRatio = 0.45;

/// Default canvas background color (0 = transparent/black)
/// Source: creations.db `dstBackgroundColor` = 0
const int defaultBackgroundColor = 0;

/// Default device width (used for coordinate scaling)
/// Source: creations.db `fromDeviceWidth` = 411.42857142857144
const double defaultDeviceWidth = 411.42857142857144;

/// Layer key pattern: `frame_layer_{uid}_{frameIndex}`
/// Source: layers JSON keys, e.g. `frame_layer_286_0`
const String layerKeyPattern = 'frame_layer_';

/// Layer encoding: base64url (no padding) → gzip → JSON.
/// Source: creations.db `layers` column decode test
const String layerEncoding = 'base64url-nopad-gzip-json';
