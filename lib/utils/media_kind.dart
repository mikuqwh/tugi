/// What kind of media a file holds, decided from its bytes.
///
/// The Add Watermark feature has to pick an output shape before it can
/// build a command: a GIF needs the palette split, an image is a single
/// frame, a video needs H.264. The previous implementation reaches the same conclusion
/// from the bytes it decodes, and a file whose name says `.gif` but whose
/// bytes are a JPEG should not get a broken command.
///
/// This lives in its own file, away from the service, because the service
/// imports `ffmpeg_kit_flutter_new` and therefore cannot be loaded by the
/// plain Dart VM -- which is exactly where the tests for this run.
// SPDX-License-Identifier: GPL-3.0-or-later

library media_kind;

import 'dart:typed_data';

import '../ffmpeg/commands.dart' show WatermarkMediaKind;

/// True when the bytes start with a GIF signature.
///
/// Both revisions are accepted: `GIF89a` and `GIF87a`. The previous implementation
/// GIF spec is `GIF87a`; the 89a revision added the interlaced and
/// transparency extensions and is what everything emits today, but a
/// 1980s-era file is still a GIF and must not be classified as an image
/// (which would freeze it into a single frame).
bool looksLikeGif(Uint8List b) {
  if (b.length < 6) return false;
  return b[0] == 0x47 && // G
      b[1] == 0x49 && // I
      b[2] == 0x46 && // F
      b[3] == 0x38 && // 8  (both revisions share it)
      b[5] == 0x61; // a
}

/// True when the bytes look like an MP4/MOV container.
///
/// The `ftyp` / `moov` / `mdat` box types are checked at offset 4, which
/// is where every ISO-BMFF file puts them. A raw video stream would be a
/// different container, and the ffmpeg-kit build this app uses handles the
/// MP4 family for this feature.
bool looksLikeVideo(Uint8List b) {
  if (b.length < 12) return false;
  for (final tag in const ['ftyp', 'moov', 'mdat']) {
    if (b[4] == tag.codeUnitAt(0) &&
        b[5] == tag.codeUnitAt(1) &&
        b[6] == tag.codeUnitAt(2) &&
        b[7] == tag.codeUnitAt(3)) {
      return true;
    }
  }
  return false;
}

/// The media kind of [bytes].
///
/// GIF is checked first: a GIF is also a valid image, so the generic image
/// reader would happily accept one and the output would be a still frame
/// of an animation.
WatermarkMediaKind mediaKindOfBytes(Uint8List bytes) {
  if (looksLikeGif(bytes)) return WatermarkMediaKind.gif;
  if (looksLikeVideo(bytes)) return WatermarkMediaKind.video;
  return WatermarkMediaKind.image;
}

/// The file extension an output of [kind] should carry.
///
/// The extension follows the KIND, not the input's extension: a GIF input
/// always produces a `.gif` (so the muxer is never guessed from a name), an
/// image input a `.png` (lossless, so the watermark's own colours survive
/// exactly), a video input a `.mp4`.
String outputExtensionFor(WatermarkMediaKind kind) {
  switch (kind) {
    case WatermarkMediaKind.gif:
      return 'gif';
    case WatermarkMediaKind.image:
      return 'png';
    case WatermarkMediaKind.video:
      return 'mp4';
  }
}
