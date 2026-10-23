// SPDX-License-Identifier: GPL-3.0-or-later

/// How hard the encoder should work.
///
/// This is the "fast / slow" trade-off ffmpeg's encoders expose, expressed as
/// something measurable: the GIF side changes the palette search, the colour
/// count and the dithering; the video side changes the x264 preset and CRF.
/// A faster setting really is smaller and quicker, at the cost of banding.
library encode_preset;

enum EncodePreset {
  fast(
    label: '快速',
    detail: '更快、更小，色带略明显',
    gifColors: 128,
    // `single` builds one palette from a sample instead of scanning the whole
    // segment; bayer dithering is a fixed pattern, the cheapest to compute.
    gifStatsMode: 'single',
    transparentStatsMode: 'single',
    gifDither: 'bayer',
    gifDitherArgs: ':bayer_scale=5',
    videoPreset: 'ultrafast',
    videoCrf: 28,
  ),
  balanced(
    label: '均衡',
    detail: '默认，画质与体积折中',
    gifColors: 256,
    gifStatsMode: 'single',
    // The transparent chain has always run with ffmpeg's default (full) here;
    // keeping it empty preserves the output users already have.
    transparentStatsMode: '',
    gifDither: 'sierra2_4a',
    gifDitherArgs: '',
    videoPreset: 'veryfast',
    videoCrf: 23,
  ),
  high(
    label: '高质量',
    detail: '更慢、更大，颜色更干净',
    gifColors: 256,
    // `full` computes the palette from every frame.
    gifStatsMode: 'full',
    transparentStatsMode: 'full',
    gifDither: 'sierra2_4a',
    gifDitherArgs: '',
    videoPreset: 'medium',
    videoCrf: 18,
  );

  const EncodePreset({
    required this.label,
    required this.detail,
    required this.gifColors,
    required this.gifStatsMode,
    required this.transparentStatsMode,
    required this.gifDither,
    required this.gifDitherArgs,
    required this.videoPreset,
    required this.videoCrf,
  });

  final String label;
  final String detail;

  /// Palette size for `palettegen`.
  final int gifColors;

  /// `palettegen=stats_mode=` for the video -> GIF chain (single | full).
  final String gifStatsMode;

  /// The same for the transparency-preserving chain; empty keeps ffmpeg's
  /// default, which is what that path shipped with.
  final String transparentStatsMode;

  /// `paletteuse=dither=`.
  final String gifDither;

  /// Extra dither parameters, e.g. `:bayer_scale=6`.
  final String gifDitherArgs;

  final String videoPreset;
  final int videoCrf;

  /// The palette tail of a GIF filter chain for this preset.
  ///
  /// Shape is fixed by the device: the pre-stages stay unlabelled and glued to
  /// `split`, and `palettegen`/`paletteuse` are labelled exactly like this.
  /// `new=1` is kept for the balanced preset because that is the form the
  /// ffmpeg build has been exercised with, and it produces the same output as
  /// the default when dithering is explicit.
  String get gifPaletteTail => 'split[s1][s2];'
      '[s1]palettegen=stats_mode=$gifStatsMode:max_colors=$gifColors[p];'
      '[s2][p]paletteuse=dither=$gifDither$gifDitherArgs';

  /// The same tail for a chain that must preserve transparency (Edit GIF).
  String get gifTransparentTail => 'split[a][b];'
      '[a]palettegen=reserve_transparent=on:transparency_color=ffffff'
      '${transparentStatsMode.isEmpty ? '' : ':stats_mode=$transparentStatsMode'}'
      ':max_colors=$gifColors[p];'
      '[b][p]paletteuse=dither=$gifDither$gifDitherArgs';
}
