/// Image and video conversion commands (Tugi S3).
///
/// The format knowledge (encoder args, extension, quality policy) comes from
/// `packages/format_core`; this file only turns a [FormatSpec] plus the user's
/// choices into argv. Keeping the split means the registry has one source of
/// truth and the command tests stay about SHAPE.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:format_core/format_core.dart';

/// Build an image conversion command.
///
/// [backgroundArgb] flattens transparency onto a colour, which JPEG/BMP need:
/// without it ffmpeg simply drops the alpha channel and every transparent
/// pixel becomes whatever RGB it happened to carry (usually black). The
/// flatten is done with an `overlay` of a colour source sized to the frame,
/// because ffmpeg has no "composite onto colour" option on the encoder.
///
/// [width]/[height] scale the result (height follows the aspect when only one
/// is given). [dropAnimation] keeps the first frame only -- the screen uses it
/// when the user converts an animated source to a still format, and the UI says
/// so rather than silently losing the animation.
List<String> convertImage({
  required String inputPath,
  required String outputPath,
  required FormatSpec format,
  int quality = 85,
  int? width,
  int? height,
  int? backgroundArgb,
  bool dropAnimation = false,
}) {
  final filters = <String>[];
  if (width != null || height != null) {
    final w = width?.toString() ?? '-2';
    final h = height?.toString() ?? '-2';
    filters.add('scale=$w:$h');
  }

  final qualityArgsList = format.quality == QualityPolicy.none
      ? const <String>[]
      : qualityArgs(format.quality, quality);

  final base = <String>['-y', '-i', inputPath];

  if (backgroundArgb != null) {
    // A colour source has to be sized explicitly (`color=...:s=WxH`); iw/ih
    // are not available there, so the caller passes the probed size. Without
    // a size the flatten is skipped and the encoder's default (drop alpha)
    // applies -- the screen never takes that path, but the builder is total.
    final color =
        '0x${(backgroundArgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final size =
        (width != null && height != null) ? 's=${width}x$height' : null;
    if (size != null) {
      final chain = [
        '[1:v][0:v]overlay=format=auto',
        if (filters.isNotEmpty) ...filters,
        'format=rgb24',
      ].join(',');
      return [
        ...base,
        '-f',
        'lavfi',
        '-i',
        'color=c=$color:$size',
        '-filter_complex',
        chain,
        if (dropAnimation) ...['-frames:v', '1'],
        ...format.encoderArgs,
        ...qualityArgsList,
        if (format.muxer != null) ...['-f', format.muxer!],
        outputPath,
      ];
    }
  }

  return [
    ...base,
    if (filters.isNotEmpty) ...['-vf', filters.join(',')],
    if (dropAnimation) ...['-frames:v', '1'],
    ...format.encoderArgs,
    ...qualityArgsList,
    if (format.muxer != null) ...['-f', format.muxer!],
    outputPath,
  ];
}

/// Build a video conversion command.
///
/// [quality] is the UI's 1..100 value, translated by the format's policy
/// (crf for x264/x265/VP9/AV1). [hardware] swaps in MediaCodec's H.264/H.265
/// encoder: much faster on long clips, slightly different quality, and it
/// ignores crf -- so the caller only offers it as an explicit choice.
///
/// [dropAudio] adds `-an`. When the target file keeps audio, AAC at 192 kbps
/// is written; a WebM container is the one exception where Opus is used,
/// because AAC-in-WebM is not a thing players agree on.
List<String> convertVideo({
  required String inputPath,
  required String outputPath,
  required FormatSpec format,
  int quality = 75,
  int? width,
  double? fps,
  bool dropAudio = false,
  bool hardware = false,
  int audioBitrateKbps = 192,
}) {
  final filters = <String>[
    if (width != null) 'scale=$width:-2',
    if (fps != null) 'fps=${fps.toStringAsFixed(3)}',
  ];

  final encoder = hardware
      ? switch (format.id) {
          'mp4_h264' || 'mkv_h264' || 'mov_h264' => ['-c:v', 'h264_mediacodec'],
          'mp4_h265' => ['-c:v', 'hevc_mediacodec'],
          // No hardware path for VP9/AV1/MJPEG in this build.
          _ => format.encoderArgs,
        }
      : format.encoderArgs;

  // MediaCodec takes a bitrate, not a crf; deriving one from the UI quality
  // keeps the slider meaningful without pretending it maps to crf.
  final hardwareEncoder = encoder.any((e) => e.contains('mediacodec'));
  final qualityArgsList = hardware && hardwareEncoder
      ? ['-b:v', '${(quality * 40).clamp(500, 12000)}k']
      : (format.quality == QualityPolicy.none
          ? const <String>[]
          : qualityArgs(format.quality, quality));

  final isWebm = format.extension == 'webm';
  final audioArgs = dropAudio
      ? const ['-an']
      : isWebm
          ? ['-c:a', 'libopus', '-b:a', '${audioBitrateKbps}k']
          : ['-c:a', 'aac', '-b:a', '${audioBitrateKbps}k'];

  return [
    '-y',
    '-i',
    inputPath,
    ...encoder,
    ...qualityArgsList,
    if (filters.isNotEmpty) ...['-vf', filters.join(',')],
    ...audioArgs,
    if (format.extension == 'mp4' || format.extension == 'mov') ...[
      '-movflags',
      '+faststart',
    ],
    outputPath,
  ];
}

/// Convert one audio file to another audio format.
///
/// Same policy as the extraction path: copy when the container accepts the
/// source codec, re-encode otherwise. `-vn` is harmless on an audio-only file
/// and keeps cover-art streams from confusing the muxer.
List<String> convertAudio({
  required String inputPath,
  required String outputPath,
  required FormatSpec format,
  int quality = 192,
  bool copy = false,
}) {
  return [
    '-y',
    '-i',
    inputPath,
    '-vn',
    if (copy) ...['-c:a', 'copy'] else ...format.encoderArgs,
    if (!copy && format.quality != QualityPolicy.none)
      ...qualityArgs(format.quality, quality),
    if (format.id == 'aac') ...['-f', 'adts'],
    outputPath,
  ];
}
