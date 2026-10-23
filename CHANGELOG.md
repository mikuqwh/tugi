# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [0.4.0] — 2026-10-23

### Added
- Crop editor for Video to GIF and Edit GIF: a draggable frame with four
  corners and four edges, 1:1 / 4:3 / 16:9 / free presets, thirds guides and a
  live pixel readout. The crop is a normalised rect, converted to even
  `crop=w:h:x:y` pixels at export time and placed first in the filter chain.
- Trim timeline in Video to GIF and Edit GIF: a filmstrip of the source with
  two handles, frame snapping and honest labels. Video cuts use a fast
  `-ss/-t` seek; GIF cuts use `trim` + a rebased `setpts`, so the kept segment
  starts at zero. An untouched range produces exactly the old command.

## [0.3.0] — 2026-10-22

### Added
- Works shelf: every successful export is copied into the app's support
  directory, thumbnailed with ffmpeg, indexed with its source file, and made
  browsable (sort by time or size, search by name/format/feature).
- Works preview: tap a card for a full-screen view, swipe between works, zoom
  stills, share the file, or open it with whatever app owns the type (gallery
  for a photo, a player for video, a music player for audio). This replaced
  "用这张再做一次", which fed an output back into the feature that made it -- a
  GIF is not valid input for "Images to GIF".
- Storage controls on the shelf: total size, "keep the last N" (unlimited /
  20 / 50 / 100 / 200, enforced on every new export) and a one-tap cleanup
  that reports what it freed.
- Themed backgrounds: solid colour, generated mesh-gradient "flow", or an
  image (three built-in presets plus a custom import) with opacity.
- Graphical colour wheel with saved palettes, used by the theme and by the
  watermark colour picker.
- Pull-down on the home opens search; feature screens swipe between siblings.
- Rainbow edge on every picker and export button; disabled actions keep a
  muted version of the feature colour.
- Chinese Material localisations (the text selection toolbar is no longer in
  English).
- Pinch-zoom square viewport for Edit Image and the watermark preview.

### Fixed
- The flowing background no longer "restarts" once per loop: its blob
  frequencies were fractional, so every repeat jumped back to an unrelated
  frame. They are integer multiples of the loop now (two summed harmonics per
  blob), which keeps the motion organic without a seam.

### Added
- **Scramble 混淆** (转换 group): turn a picture into tiles or noise and restore
  it with the same password. Four reversible modes — standard (Fisher–Yates pixel
  shuffle + RGB keystream), strong (two shuffles) and Hilbert (curve-ordered
  shuffle). Alpha is never touched, the round trip is byte-exact, and a wrong
  password cannot restore. Heavy images are transformed in an isolate.
- A 速度 / 质量 selector on Video to GIF and Edit GIF. Fast uses a 128-colour
  palette with bayer dithering, balanced keeps the established 256-colour
  sierra chain, high searches every frame for the palette. Measured on a 30 s
  640×360 clip: fast is 24% smaller and roughly 1.5× quicker than balanced.
  Details and the numbers: `docs/TUGI-编码档位实测-20261023.md`.
- Export progress everywhere: every export runs ffmpeg asynchronously and shows
  a real percentage (ffmpeg's own statistics against the job's length) in place
  of the primary button, with cancel. Covered: Video to GIF, Edit GIF, Format
  Convert, Compress GIFs, Extract Audio, GIF to Video, Add watermark, Edit
  Image, GIFs to Images, Images to GIF and Images to Video. Where a length
  cannot be known (a still image, an unknown container) the bar is
  indeterminate rather than frozen at 0.

### Changed
- The trim screens follow the common editor layout: large preview, timeline
  right under it, crop as an icon in the timeline header, a 更多设置 section
  for width / loop / dedup / container, and the primary action docked to the
  bottom so it never scrolls away.
- A fresh install now starts with the app icon as the background image.
- The trim handles keep a 44 px touch target (the visible bar is still 22 px):
  they sit on the strip's edges, where a 22 px grab area was hard to hit, and an
  eager recogniser keeps the page swipe from stealing the drag.

### Changed
- Home is a swipeable pager: 转换 / GIF / 图片 / 收藏 / 作品.
- Feature cards are wide bars with concrete descriptions; the "last used"
  entry is a capsule in the header.
- Edit Image, Format Convert and Extract Audio share the Images-to-Video
  one-column layout.

### Fixed
- Audio exports no longer go to the gallery: image/video use the gallery,
  audio uses the system save dialog, with a fallback either way.
- Replacing a custom background actually replaces it (unique file name, cache
  eviction, no self-delete during cleanup).
- Opening and closing search no longer resets the selected category page.
- Dragging a text-selection handle no longer opens the settings panel.
- Zoomed previews no longer flip to the next feature while panned.

## [0.2.0] — 2026-10-21

### Added
- APNG output for Video→GIF, Images→GIF, Edit GIF and animated watermarks.
- Images to Video containers: MP4/H.264, MP4/H.265, WebM/VP9, MOV, MKV.
- Full device format matrix test (28 formats, codec-verified).

### Fixed
- Save-by-type routing for every exporting screen.

## [0.1.0] — 2026-10-21

Initial Tugi build: eleven media tools on a shared command-builder +
service architecture.

[0.3.0]: https://github.com/OWNER/tugi/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/OWNER/tugi/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/OWNER/tugi/releases/tag/v0.1.0
