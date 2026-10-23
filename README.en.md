<p align="center">
  <img src="assets/brand/app_icon_256.png" width="120" height="120" alt="Tugi">
</p>

<h1 align="center">Tugi</h1>

<p align="center"><b>A fully offline Android toolbox for images, GIFs and video.</b></p>

<p align="center">
Twelve tools, all running on-device through ffmpeg — no upload, no account, no<br>
network permission required to process media. Built with Flutter, GPL-3.0-or-later.
</p>

<p align="center">
  <a href="https://github.com/mikuqwh/tugi/releases/latest"><img alt="download" src="https://img.shields.io/badge/Download-APK-2ea44f?logo=android&logoColor=white"></a>
  <img alt="platform" src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&logoColor=white">
  <img alt="flutter" src="https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter&logoColor=white">
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">
  <img alt="tests" src="https://img.shields.io/badge/host%20tests-510%20passed-brightgreen">
  <img alt="network" src="https://img.shields.io/badge/network-none-black">
</p>

<p align="center"><b>English</b> · <a href="README.md">中文</a></p>

---

<a id="toc"></a>
## Contents

- [Install](#download)
- [What it does](#features)
- [Why "offline"](#why-offline)
- [Design principles](#principles)
- [Architecture](#architecture)
- [Stack](#stack)
- [Repository layout](#layout)
- [Build](#build)
- [Testing](#testing)
- [Size and speed](#performance)
- [FAQ](#faq)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)
- [Credits](#credits)

---

<a id="download"></a>
## Install

👉 **[Latest release](https://github.com/mikuqwh/tugi/releases/latest)**

| File | For | Size |
|---|---|---|
| `app-arm64-v8a-release.apk` | Essentially every phone since 2017 | 70.8 MB |
| `app-armeabi-v7a-release.apk` | Older 32-bit devices | 104.6 MB |
| `app-x86_64-release.apk` | Emulators | 78.5 MB |

1. Pick the APK for your CPU (arm64 if unsure).
2. Install it and allow "unknown sources" when Android asks.
3. Open it — no onboarding, no sign-in, no first-run download.

> The current build is signed with the **debug keystore**: it installs and runs,
> but it cannot update an install signed elsewhere and cannot be shipped to a
> store. To publish your own build, copy
> [`android/key.properties.example`](android/key.properties.example) to
> `android/key.properties` and rebuild.

Requires **Android 7.0 (API 24)** or newer.

---

<a id="features"></a>
## What it does

The home screen is four swipeable groups; long-press any tool to favourite it.

### Convert

| Tool | Purpose | Notes |
|---|---|---|
| **Format Convert** | Image / GIF / video / audio conversion | 15 image, 7 audio and 6 video containers; capabilities are probed at runtime, unsupported targets are greyed out with a reason |
| **Extract Audio** | Pull the audio track from a video | Stream-copies when the codec already matches (`-c copy`), so it is instant and lossless |
| **Images to Video** | Stills → video | Per-image duration, output width, container (MP4 / WebM / MKV / MOV) |
| **Scramble** | Obscure an image, restore it later | Four reversible modes: mosaic tiles, per-pixel, strong, Hilbert; all byte-exact round trips |

### GIF

| Tool | Purpose | Notes |
|---|---|---|
| **Video to GIF** | Clip a video into GIF / APNG | Timeline trim, frame rate, width, dedupe, three speed/quality presets |
| **Images to GIF** | Stills → animated GIF | Per-frame duration and width; APNG supported |
| **Edit GIF** | Modify a GIF | Speed, reverse, trim; same presets |
| **GIF to Video** | GIF → video | MP4 / WebM / MKV with chosen frame rate and width |
| **GIFs to Images** | Extract frames | Frame step, format, quality; batch save |
| **Compress GIFs** | Shrink a GIF | Scale or frame-drop paths, with a size estimate |

### Image

| Tool | Purpose | Notes |
|---|---|---|
| **Add watermark** | Watermark photos | Text, image or GIF layers, up to six, batch capable; the layer is clamped back inside the frame |
| **Edit Image** | Photo editor | Crop, rotate, flip, colour adjustments, presets, target-size compression, pinch-zoom preview |

### Works

Every export is indexed together with its source: sort by time or size, search,
open full screen (zoom, swipe between items), share, hand off to the system app,
see total size and prune to the last N entries.

### Also

Search (Chinese and English keywords), favourites, a "last used" pill, background
choice (solid / animated mesh gradient / photo with opacity), a custom accent
colour picked from a colour wheel and persisted, Chinese text-selection menu, and
audio exports routed through the system save dialog.

---

<a id="why-offline"></a>
## Why "offline"

It is not a slogan; it is a fact in the manifest: the app **does not declare the
`INTERNET` permission** and contains no HTTP client. That means:

- your media never leaves the phone — not even "hypothetically";
- no account, no analytics, no crash reporting (symbols stay in `build/symbols/`);
- the cost is size: the full-gpl ffmpeg build ships inside the APK.

All media work is delegated to ffmpeg's Android build (libx264 / libx265 /
libvpx / libwebp / libass …); the UI only chooses parameters and orchestrates.

---

<a id="principles"></a>
## Design principles

1. **Commands are pure functions.** Every ffmpeg invocation is produced by a pure
   function in `lib/ffmpeg/commands.dart` that returns `List<String>`. No runtime
   dependency, so the exact argv can be unit-tested off-device. This is the most
   important testability decision in the project.
2. **Capabilities drive the UI.** Encoders and muxers are probed from the bundled
   ffmpeg at startup instead of a hard-coded list; unsupported targets are greyed
   out with an explanation.
3. **Progress is derived, never faked.** Jobs read ffmpeg's own statistics
   (processed time / total time). When the length is unknown the bar is
   indeterminate rather than frozen at 0 % or 100 %.
4. **Errors speak human.** stderr is summarised into one readable reason instead
   of dumping the log.
5. **No "looks enabled" compromises.** A button that cannot run yet is pale; a
   feature that cannot work is disabled with a reason.

---

<a id="architecture"></a>
## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ screens/          UI and state: read input, call a service,  │
│                   render, report errors                      │
│                   home · 12 tools · works · full-screen view  │
└──────────────────────────┬──────────────────────────────────┘
                           │ calls (never talks to ffmpeg)
┌──────────────────────────▼──────────────────────────────────┐
│ services/         orchestration                              │
│   ffmpeg_progress.dart  async + statistics + cancel          │
│   *_service.dart        one pipeline per tool                │
│   export_service.dart   gallery / system save dialog routing │
│   works_service.dart    export index and pruning             │
└──────────────────────────┬──────────────────────────────────┘
                           │ pure functions
┌──────────────────────────▼──────────────────────────────────┐
│ ffmpeg/commands.dart       arguments → List<String> (tested) │
│ utils/                     pure algorithms: scramble, sizes  │
└──────────────────────────┬──────────────────────────────────┘
                           │ executeAsync
┌──────────────────────────▼──────────────────────────────────┐
│ ffmpeg-kit full-gpl                                          │
└─────────────────────────────────────────────────────────────┘
```

**One real path (Video → GIF)**

```
user drags the timeline
  └─ TrimRange(start, duration)                 normalised range
      └─ VideoToGifService.convertVideoToGif(args)
          ├─ ffmpeg.videoToGif(...)             → List<String> (unit-tested)
          ├─ runWithProgress(args, totalMs)     → FfmpegJob
          │     ├─ onProgress: statistics.time / totalMs → progress bar
          │     └─ cancel(): session.cancel()            → FfmpegCancelled
          └─ ExportService.save(path)           → gallery (falls back to the save dialog)
              └─ WorksService.record(...)       → works index
```

**Notable details**

- **Async progress and cancel.** `runWithProgress()` settles the `ReturnCode` in
  the completion callback (`session.getReturnCode()` returns null if you await it
  directly — an ffmpeg-kit trap). Cancel throws `FfmpegCancelled` so callers can
  delete partial output.
- **Crop** is stored as normalised edges (0..1) and only converted to even-pixel
  `crop=w:h:x:y` at export time, ahead of everything else in the filter chain so
  the encoder never sees the discarded pixels.
- **Trimming**: video uses `-ss/-t`; GIF uses `trim` plus a rebasing `setpts`
  (otherwise the kept segment carries the leading blank time).
- **Scramble**: password → FNV-1a 64-bit seed → xorshift64-driven permutation.
  Mosaic moves whole blocks (8–40 px); the per-pixel mode is Fisher–Yates plus an
  RGB keystream. Alpha never participates in the XOR, large images run in an
  isolate, and the partial strip at the right/bottom edge stays put — both a
  visual convention and the reason the round trip is exact.
- **Save routing**: images and video go to the gallery (`gal`), audio goes through
  `ACTION_CREATE_DOCUMENT`, and a gallery refusal falls back to the dialog.

---

<a id="stack"></a>
## Stack

| Layer | Choice |
|---|---|
| Framework | Flutter 3.47 / Dart 3.13 (Material 3) |
| Media | [ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) `ffmpeg_kit_flutter_new` 8.0.0 (full-gpl) |
| Gallery | `gal` |
| Picking | `image_picker` |
| Sharing | `share_plus` |
| Paths | `path_provider` |
| Fonts | Noto Sans SC / Noto Serif SC (`drawtext` needs real font files on Android) |
| Native code | one MethodChannel: `ACTION_CREATE_DOCUMENT` save + FileProvider open |

---

<a id="layout"></a>
## Repository layout

```
lib/
  screens/          14 screens: home, 12 tools, works, preview
  services/         orchestration: conversion, watermark, compression, export, works
  ffmpeg/           pure argv builders (commands / convert / audio / pipeline)
  models/           data models, encode presets, crop rect, format specs
  ui/               design system: tokens, palette, timeline, crop overlay, progress
  utils/            pure algorithms: image scramble, size estimates, formatting
packages/format_core/   pure-Dart format registry (no Flutter import)
test/               host tests: argv shape, services, UI, algorithms
integration_test/   on-device tests: real ffmpeg, format matrix, gesture regressions
tool/               build script, icon/background generators, capability probes
docs/               design notes in chronological order (the "why")
```

---

<a id="build"></a>
## Build

Requires Flutter 3.35+ (verified on 3.47 / Dart 3.13) and Android SDK 35+.

```bash
git clone https://github.com/mikuqwh/tugi.git
cd tugi
flutter pub get

# universal APK (~230 MB)
flutter build apk --release

# or per ABI (recommended for releases)
flutter build apk --release --split-per-abi
```

- The first build pulls the full-gpl ffmpeg artifacts; a large APK is expected.
- `build/symbols/` holds the crash symbols: archive them with the APK, never
  commit them and never ship them inside the APK.
- Release signing: copy
  [`android/key.properties.example`](android/key.properties.example) to
  `android/key.properties`; without it the build falls back to the debug keystore.
- To shrink the app, swap to the `min-gpl` variant — some formats will disappear
  (the app greys them out automatically).

---

<a id="testing"></a>
## Testing

```bash
# pure-Dart format registry
cd packages/format_core && dart test

# host tests: 510 of them
flutter test test/ffmpeg test/convert test/services test/ui test/utils

# on-device: convert 28 formats and verify the resulting codec
flutter test integration_test/ffmpeg/convert_matrix_device_test.dart
```

| Suite | What it covers |
|---|---|
| `test/ffmpeg` | argv shape: argument order and values for every command (pure, fastest) |
| `test/convert` | capability probing and registry consistency |
| `test/services` | export routing, works index, settings migration and corruption, size arithmetic |
| `test/ui` | screen state: progress, readiness of buttons, crop, timeline, scramble round trip, empty states |
| `test/utils` | size estimates, time formatting, scramble algorithms |
| `integration_test` | real ffmpeg runs: format matrix, watermark at the frame edge, saving, gesture conflicts |

CI runs `analyze + 510 host tests + a debug APK build` on every push; the release
workflow builds per-ABI APKs and attaches them to the tag.

---

<a id="performance"></a>
## Size and speed

- **Speed/quality presets** (30 s 720p clip): fast 746 KB, balanced 966 KB, high
  972 KB; fast takes about two thirds of balanced's time.
- **GIF compression**: scale and frame-drop paths, with honest size estimates
  (ranges for lossy, arithmetic for lossless).
- **APK**: 70.8 MB for arm64 (about 55 MB of that is ffmpeg); per-ABI splits keep
  it from doubling.
- **Startup**: no network calls; the only startup work is a one-off ffmpeg
  capability probe (~200 ms).

---

<a id="faq"></a>
## FAQ

**Why is the APK so big?**
Full-gpl ffmpeg (x264 / x265 / vpx / webp / ass…) is over 50 MB on its own.
`min-gpl` roughly halves it but drops a set of formats.

**Why "unknown sources"?**
The app is not on a store; it installs straight from the release page.

**Why the debug keystore?**
A release certificate should not live in a public repository. Configure your own
via `key.properties.example` when you publish a build.

**Is Scramble secure?**
It is a reversible shuffle, **not encryption**: security depends on password
strength, there is no authentication, and it will not stop a determined attacker.
It is meant to stop casual resharing, not to protect secrets.

**iOS or desktop?**
Android only, verified. The iOS/desktop folders are Flutter scaffolding, untested.

**Does it phone home?**
No. Without the `INTERNET` permission it cannot even resolve DNS.

---

<a id="roadmap"></a>
## Roadmap

- [ ] Time/size table for the x264 CRF and preset options
- [ ] Per-frame GIF editing (delete, reorder, per-frame duration)
- [ ] Batch rename and export templates
- [ ] An optional on-device OCR / de-watermark experimental branch (still offline)

---

<a id="contributing"></a>
## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The one non-negotiable rule: **no network
dependencies**. Bugs and requests go to
[Issues](https://github.com/mikuqwh/tugi/issues); security reports follow
[SECURITY.md](SECURITY.md).

---

<a id="security"></a>
## Security

- No `INTERNET` permission, no telemetry.
- Scramble is obfuscation, not encryption; the UI says so too.
- Files are read only when the user picks them and written only to the gallery,
  the system save dialog, or the app's own cache.
- Full threat model in [SECURITY.md](SECURITY.md).

---

<a id="license"></a>
## License

- **GPL-3.0-or-later**, see [LICENSE](LICENSE).
- Third-party components: [THIRD_PARTY.md](THIRD_PARTY.md); attribution:
  [NOTICE](NOTICE); source files carry SPDX identifiers.
- Built on the full-gpl ffmpeg-kit variant, which is why the whole app must be GPL.
- Fonts: Noto Sans SC / Noto Serif SC (SIL OFL 1.1).
- Icons and background art are drawn or generated for this project (`tool/brand/`).

---

<a id="credits"></a>
## Credits

**Designed and implemented entirely by DeepSeek (大肥鱼).**

UI, algorithms, tests, documentation and release tooling were produced by that AI
under human direction. No third-party application's code or assets were reused.

If it is useful to you, a ⭐ is the best thanks.
