import 'media_kind.dart';
import 'quality.dart';

/// One output format the converter can produce.
///
/// This is DATA, not behaviour: the command builders read it, the UI reads it,
/// and the capability probe decides whether it is usable on the current device.
/// Everything here was verified on the device build (see the proposal doc's
/// capability matrix); a format that has not been verified does not belong in
/// the registry, however obvious it seems.
class FormatSpec {
  const FormatSpec({
    required this.id,
    required this.label,
    required this.extension,
    required this.mime,
    required this.kind,
    this.encoderArgs = const [],
    this.muxer,
    this.supportsAlpha = false,
    this.supportsAnimation = false,
    this.quality = QualityPolicy.none,
    this.probeToken,
    this.note = '',
  });

  /// Stable identifier used by the UI and the tests (`png`, `mp4_h264`).
  final String id;

  /// What the user sees on the format grid.
  final String label;

  /// Output file extension, without the dot.
  final String extension;

  final String mime;
  final MediaKind kind;

  /// `-c:v <x>` / `-c:a <x>` and friends. Empty means "let ffmpeg infer from
  /// the extension", which is right for the simpler image encoders.
  final List<String> encoderArgs;

  /// Explicit `-f <muxer>` when the extension is ambiguous.
  ///
  /// APNG is the reason this exists: writing `out.png` goes through image2 and
  /// silently produces a single frame, while `-f apng` writes the animation.
  final String? muxer;

  final bool supportsAlpha;
  final bool supportsAnimation;
  final QualityPolicy quality;

  /// The token to look for in `ffmpeg -encoders` / `-muxers` output.
  ///
  /// Null for formats that need no external library (the built-in PNG, BMP ...
  /// encoders are always present in this build), so the probe passes them.
  final String? probeToken;

  /// Shown in the UI when the format has a caveat (slow encoder, size, ...).
  final String note;

  bool get isLossless =>
      quality == QualityPolicy.none && kind != MediaKind.audio;

  String get fileName => '$label ($extension)';
}

/// Every output format this project has actually produced on device.
///
/// Order matters: it is the order of the format grid.
const List<FormatSpec> formatRegistry = [
  // ---- images -----------------------------------------------------------
  FormatSpec(
    id: 'png',
    label: 'PNG',
    extension: 'png',
    mime: 'image/png',
    kind: MediaKind.image,
    supportsAlpha: true,
    note: '无损，支持透明',
  ),
  FormatSpec(
    id: 'jpg',
    label: 'JPEG',
    extension: 'jpg',
    mime: 'image/jpeg',
    kind: MediaKind.image,
    encoderArgs: ['-c:v', 'mjpeg'],
    quality: QualityPolicy.jpegQ,
    note: '有损；透明底会垫背景色',
  ),
  FormatSpec(
    id: 'webp',
    label: 'WebP',
    extension: 'webp',
    mime: 'image/webp',
    kind: MediaKind.image,
    encoderArgs: ['-c:v', 'libwebp'],
    quality: QualityPolicy.webpQ,
    supportsAlpha: true,
    probeToken: 'libwebp',
  ),
  FormatSpec(
    id: 'avif',
    label: 'AVIF',
    extension: 'avif',
    mime: 'image/avif',
    kind: MediaKind.image,
    encoderArgs: ['-c:v', 'libaom-av1', '-cpu-used', '8'],
    quality: QualityPolicy.crf,
    probeToken: 'libaom-av1',
    note: '体积小但编码慢（AV1）',
  ),
  FormatSpec(
    id: 'gif',
    label: 'GIF',
    extension: 'gif',
    mime: 'image/gif',
    kind: MediaKind.animated,
    supportsAlpha: true,
    supportsAnimation: true,
    note: '256 色；动图会保留',
  ),
  FormatSpec(
    id: 'apng',
    label: 'APNG',
    extension: 'apng',
    mime: 'image/apng',
    kind: MediaKind.animated,
    muxer: 'apng',
    supportsAlpha: true,
    supportsAnimation: true,
    note: '全彩动图，必须显式指定 muxer',
  ),
  FormatSpec(
    id: 'bmp',
    label: 'BMP',
    extension: 'bmp',
    mime: 'image/bmp',
    kind: MediaKind.image,
    note: '无压缩，体积大',
  ),
  FormatSpec(
    id: 'tiff',
    label: 'TIFF',
    extension: 'tiff',
    mime: 'image/tiff',
    kind: MediaKind.image,
    supportsAlpha: true,
  ),
  FormatSpec(
    id: 'j2k',
    label: 'JPEG 2000',
    extension: 'jp2',
    mime: 'image/jp2',
    kind: MediaKind.image,
    encoderArgs: ['-c:v', 'jpeg2000'],
    supportsAlpha: true,
  ),
  FormatSpec(
    id: 'qoi',
    label: 'QOI',
    extension: 'qoi',
    mime: 'image/qoi',
    kind: MediaKind.image,
    supportsAlpha: true,
    note: '无损，极快',
  ),
  FormatSpec(
    id: 'ico',
    label: 'ICO',
    extension: 'ico',
    mime: 'image/x-icon',
    kind: MediaKind.image,
    supportsAlpha: true,
    note: '图标；多尺寸需另行拼接',
  ),
  FormatSpec(
    id: 'tga',
    label: 'TGA',
    extension: 'tga',
    mime: 'image/x-tga',
    kind: MediaKind.image,
    supportsAlpha: true,
  ),
  FormatSpec(
    id: 'exr',
    label: 'EXR',
    extension: 'exr',
    mime: 'image/x-exr',
    kind: MediaKind.image,
    note: '浮点 HDR，体积很大',
  ),
  FormatSpec(
    id: 'pam',
    label: 'PAM',
    extension: 'pam',
    mime: 'image/x-portable-arbitrarymap',
    kind: MediaKind.image,
    supportsAlpha: true,
  ),
  FormatSpec(
    id: 'ppm',
    label: 'PPM',
    extension: 'ppm',
    mime: 'image/x-portable-pixmap',
    kind: MediaKind.image,
    note: '原始像素，体积大',
  ),

  // ---- audio ------------------------------------------------------------
  FormatSpec(
    id: 'mp3',
    label: 'MP3',
    extension: 'mp3',
    mime: 'audio/mpeg',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'libmp3lame'],
    quality: QualityPolicy.audioBitrate,
    probeToken: 'libmp3lame',
  ),
  FormatSpec(
    id: 'm4a',
    label: 'M4A',
    extension: 'm4a',
    mime: 'audio/mp4',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'aac'],
    quality: QualityPolicy.audioBitrate,
    note: '可与源视频直接流复制，零损失',
  ),
  FormatSpec(
    id: 'aac',
    label: 'AAC',
    extension: 'aac',
    mime: 'audio/aac',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'aac'],
    quality: QualityPolicy.audioBitrate,
  ),
  FormatSpec(
    id: 'flac',
    label: 'FLAC',
    extension: 'flac',
    mime: 'audio/flac',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'flac'],
    note: '无损，体积大',
  ),
  FormatSpec(
    id: 'ogg',
    label: 'OGG',
    extension: 'ogg',
    mime: 'audio/ogg',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'libvorbis'],
    quality: QualityPolicy.audioBitrate,
    probeToken: 'libvorbis',
  ),
  FormatSpec(
    id: 'opus',
    label: 'Opus',
    extension: 'opus',
    mime: 'audio/opus',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'libopus'],
    quality: QualityPolicy.audioBitrate,
    probeToken: 'libopus',
  ),
  FormatSpec(
    id: 'wav',
    label: 'WAV',
    extension: 'wav',
    mime: 'audio/wav',
    kind: MediaKind.audio,
    encoderArgs: ['-c:a', 'pcm_s16le'],
    note: '未压缩，体积很大',
  ),

  // ---- video ------------------------------------------------------------
  FormatSpec(
    id: 'mp4_h264',
    label: 'MP4 · H.264',
    extension: 'mp4',
    mime: 'video/mp4',
    kind: MediaKind.video,
    encoderArgs: ['-c:v', 'libx264', '-pix_fmt', 'yuv420p'],
    quality: QualityPolicy.x264Crf,
    probeToken: 'libx264',
    note: '兼容性最好',
  ),
  FormatSpec(
    id: 'mp4_h265',
    label: 'MP4 · H.265',
    extension: 'mp4',
    mime: 'video/mp4',
    kind: MediaKind.video,
    // hvc1 so iOS/相册 recognize it; without the tag some players refuse it.
    encoderArgs: ['-c:v', 'libx265', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1'],
    quality: QualityPolicy.x264Crf,
    probeToken: 'libx265',
    note: '更小，但老设备可能放不了',
  ),
  FormatSpec(
    id: 'webm_vp9',
    label: 'WebM · VP9',
    extension: 'webm',
    mime: 'video/webm',
    kind: MediaKind.video,
    encoderArgs: ['-c:v', 'libvpx-vp9', '-pix_fmt', 'yuv420p'],
    quality: QualityPolicy.crf,
    probeToken: 'libvpx-vp9',
    note: '网页友好；编码慢',
  ),
  FormatSpec(
    id: 'mkv_h264',
    label: 'MKV · H.264',
    extension: 'mkv',
    mime: 'video/x-matroska',
    kind: MediaKind.video,
    encoderArgs: ['-c:v', 'libx264', '-pix_fmt', 'yuv420p'],
    quality: QualityPolicy.x264Crf,
    probeToken: 'libx264',
  ),
  FormatSpec(
    id: 'mov_h264',
    label: 'MOV · H.264',
    extension: 'mov',
    mime: 'video/quicktime',
    kind: MediaKind.video,
    encoderArgs: ['-c:v', 'libx264', '-pix_fmt', 'yuv420p'],
    quality: QualityPolicy.x264Crf,
    probeToken: 'libx264',
  ),
  FormatSpec(
    id: 'avi_mjpeg',
    label: 'AVI · MJPEG',
    extension: 'avi',
    mime: 'video/x-msvideo',
    kind: MediaKind.video,
    encoderArgs: ['-c:v', 'mjpeg'],
    note: '老设备/老软件兼容',
  ),
];

/// Formats that can be produced from a source of [kind].
///
/// Converting audio to video or an image to audio is nonsense; making the
/// registry answer this keeps the UI from having to re-derive the rules.
List<FormatSpec> formatsFor(MediaKind kind) {
  switch (kind) {
    case MediaKind.image:
    case MediaKind.animated:
      // A still image can become an animation (the encoder repeats the frame),
      // so animated formats are offered for both.
      return formatRegistry
          .where(
              (f) => f.kind == MediaKind.image || f.kind == MediaKind.animated)
          .toList();
    case MediaKind.video:
      return formatRegistry
          .where((f) => f.kind == MediaKind.video || f.kind == MediaKind.audio)
          .toList();
    case MediaKind.audio:
      return formatRegistry.where((f) => f.kind == MediaKind.audio).toList();
  }
}

FormatSpec? formatById(String id) {
  for (final f in formatRegistry) {
    if (f.id == id) return f;
  }
  return null;
}
