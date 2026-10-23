# Contributing to Tugi

Thanks for taking a look. This is a small, opinionated project; the notes below
are the rules the existing code follows, so a patch that breaks them will be
asked to change.

## Ground rules

1. **Everything is local.** No network calls, no analytics, no accounts. A pull
   request that adds a network dependency needs a very good reason.
2. **Licence**: contributions are GPL-3.0-or-later. By opening a PR you agree to
   license your work that way.
3. **No new native plugins if avoidable.** The Android side currently has one
   hand-written method channel (`tugi/export`) precisely to avoid plugin
   symlink requirements on Windows. Prefer Flutter/Dart.

## Before you start

- Run the app on an emulator or device: `flutter run --release`.
- Read `docs/TUGI-实施路线图-20261021.md` (roadmap) for the intended shape of
  the project.

## Tests

Every change to a command builder or a service is expected to come with a test.
The suite is split on purpose:

```bash
cd packages/format_core && dart test        # pure Dart registry
flutter test test/ffmpeg test/convert test/services test/ui test/utils
flutter test integration_test/ffmpeg/convert_matrix_device_test.dart   # needs a device
```

- **Command tests** (`test/ffmpeg/`) assert argv shapes — no ffmpeg runtime.
- **Service tests** cover routing, persistence and corrupt-data handling.
- **Widget tests** must run with reduced motion (`disableAnimations: true`) when
  the screen shows the rainbow CTA, otherwise `pumpAndSettle` never settles.
- **Device tests** are the only place that proves a format actually encodes.

`flutter analyze` must stay at zero errors **and zero warnings**.

## Code style

- One concern per file; the layer boundaries are: screen (UI + state) →
  service (I/O and orchestration) → `lib/ffmpeg/commands.dart` (pure argv).
- Comments explain *why*, and prefer recording a measurement over restating the
  code ("`-r 12` dropped 14 frames, measured").
- User-visible strings are Chinese; identifiers, comments, tests and commits are
  English.
- New UI goes through the design system in `lib/ui/`: pick `FeaturePalette` for
  colours, `RainbowGlow` for a primary action, `FlowBackground` for the
  background.

## Adding a feature

1. Add an entry to `lib/ui/feature_catalog.dart` (id, label, subtitle, icon,
   category, builder, search keywords) — the home, search and routes read it.
2. Add a colour pair in `lib/ui/app_palette.dart` (`FeatureColors` +
   `FeaturePalette.byId`); a test pins contrast at 4.5:1 and a >25° hue shift.
3. Put the argv in `lib/ffmpeg/commands.dart`, the orchestration in
   `lib/services/`, and the screen in `lib/screens/`.
4. Record exports on success (`WorksService.instance.record`).

## Commit messages

Short imperative subject, then a body explaining the problem and the decision.
If you fixed a bug, say what the *actual* cause was.
