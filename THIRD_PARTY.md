# Third-party components

Tugi is distributed under **GPL-3.0-or-later** (see [LICENSE](LICENSE)).
That choice is not arbitrary: the app links `ffmpeg-kit` built with the
**full-gpl** variant, and the GPL requires the combined work to be GPL as well.

| Component | Version | Licence | Why it is here | Upstream |
|---|---|---|---|---|
| [ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) (`full-gpl`) | 8.0.0 | LGPL-3.0 for the kit, **GPL-3.0** for the bundled ffmpeg build | all media processing | <https://github.com/arthenica/ffmpeg-kit> |
| [FFmpeg](https://ffmpeg.org) | 8.0 | GPL-3.0 (enabled with `--enable-gpl`: x264, x265, xvid, vidstab) | the actual codecs and filters | <https://ffmpeg.org/legal.html> |
| [Flutter](https://flutter.dev) / Dart | 3.47 / 3.13 | BSD-3-Clause | UI framework | <https://github.com/flutter/flutter> |
| [images_watermark](https://pub.dev/packages/image_picker) → `image_picker`, `gal`, `share_plus`, `path_provider`, `ffmpeg_kit_flutter_new`, `shared_preferences`, `animations` | as pinned in `pubspec.lock` | MIT / BSD / Apache-2.0 | picking, saving, sharing, paths, settings, transitions | see each package page |
| Noto Sans SC / Noto Serif SC | — | SIL Open Font License 1.1 | UI and watermark text | <https://fonts.google.com/noto> |
| `assets/brand/*.png`, `assets/icons/*` | — | © Tugi contributors (GPL-3.0-or-later, artwork) | app icon and backgrounds | this repository |

## What the GPL asks of a distributor

If you redistribute a Tugi APK (or a modified build):

1. make the corresponding source available, including your changes;
2. keep the licence notices and this file;
3. do not add restrictions that forbid the recipient from sharing their copy.

The `ffmpeg-kit` dependency ships its own licence texts inside the AAR; the
full texts for FFmpeg's GPL build are also available at
<https://ffmpeg.org/legal.html>. The font licence is reproduced verbatim in
[`assets/fonts/OFL-LICENSE.txt`](assets/fonts/OFL-LICENSE.txt).

## Font notice

```
Noto Sans SC, Noto Serif SC
Copyright 2014-2024 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.
Licensed under the SIL Open Font License, Version 1.1.
Full text: assets/fonts/OFL-LICENSE.txt
```

## Build options that affect licensing

`pubspec.yaml` pins `ffmpeg_kit_flutter_new` with the `full-gpl` variant.
Swapping it for `min-gpl` or `https` (no GPL components) would allow a
different licence for the app, at the cost of some encoders — the in-app
format list is probed at runtime, so those formats simply disappear.
