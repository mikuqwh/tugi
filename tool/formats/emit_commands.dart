import 'dart:io';

import 'package:format_core/format_core.dart';

/// Prints one line per registry format so `probe_matrix.sh` can run the EXACT
/// arguments the app would use -- no second copy of the table to drift.
///
/// Format: `<id>\t<extension>\t<args...>`
///
/// Run from the repo root: `dart run tool/formats/emit_commands.dart`
void main() {
  for (final spec in formatRegistry) {
    final encoder = spec.encoderArgs.join(' ');
    final muxer = spec.muxer == null ? '' : '-f ${spec.muxer}';
    // A still source for every kind: the matrix checks the ENCODER, not the
    // content. Audio needs its own source (a still image has no audio).
    // Stills get ONE frame: writing two frames to a non-sequence filename
    // fails inside image2 ("Terminating thread with return code -22"). Only
    // the animated containers need more.
    final source = switch (spec.kind) {
      MediaKind.image => '-f lavfi -i color=c=red:size=64x64 -frames:v 1',
      MediaKind.animated => '-f lavfi -i color=c=red:size=64x64 -frames:v 3',
      MediaKind.audio => '-f lavfi -i sine=frequency=440:duration=1',
      MediaKind.video =>
        '-f lavfi -i testsrc2=size=96x64:rate=10:duration=1',
    };
    final quality = qualityArgs(
      spec.quality,
      defaultQualityFor(spec.quality),
    ).join(' ');
    final args = [source, encoder, muxer, quality]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    stdout.writeln('${spec.id}\t${spec.extension}\t$args');
  }
}
