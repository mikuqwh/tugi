// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi's format core: the data and pure functions behind every converter.
///
/// Deliberately Flutter-free and IO-free:
///
///  * it can be tested with `dart test` (no emulator, no widget harness);
///  * it can be reused by a CLI or a future native shell without dragging the
///    UI along;
///  * the command builders in the app stay thin — they look values up here.
library format_core;

export 'src/audio_copy.dart';
export 'src/availability.dart';
export 'src/capability.dart';
export 'src/format_registry.dart';
export 'src/media_kind.dart';
export 'src/quality.dart';
