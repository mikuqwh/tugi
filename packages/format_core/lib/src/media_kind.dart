// SPDX-License-Identifier: GPL-3.0-or-later

/// What a media file is, from the converter's point of view.
///
/// `animated` is deliberately separate from `image`: converting a GIF to JPEG
/// has to DROP frames, which the UI must say out loud rather than do silently.
enum MediaKind {
  image,
  animated,
  video,
  audio;

  bool get isVisual => this != MediaKind.audio;
  bool get hasDuration =>
      this == MediaKind.animated ||
      this == MediaKind.video ||
      this == MediaKind.audio;
}
