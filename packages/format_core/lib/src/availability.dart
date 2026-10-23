import 'format_registry.dart';
import 'media_kind.dart';

/// Whether [spec] can actually be produced on a build exposing [available]
/// codec and muxer names (see [parseCodecNames]).
///
/// A spec is usable when its encoder is present AND, if it names a muxer, that
/// muxer is present too. Formats with no token at all (PNG, BMP, ...) are
/// compiled into ffmpeg itself, so there is nothing to probe for and they are
/// always available.
bool isFormatAvailable(FormatSpec spec, Set<String> available) {
  final token = spec.probeToken;
  if (token != null && !available.contains(token)) return false;
  final muxer = spec.muxer;
  if (muxer != null && !available.contains(muxer)) return false;
  return true;
}

/// [formatRegistry] filtered to what this build can write.
///
/// Pass [kind] to get only what makes sense for a given source; omit it for
/// the full matrix (used by the probe report).
List<FormatSpec> availableFormats(
  Set<String> available, {
  MediaKind? kind,
}) {
  final all = kind == null ? formatRegistry : formatsFor(kind);
  return all.where((f) => isFormatAvailable(f, available)).toList();
}

/// The formats [kind] could produce, and whether this build can: the UI needs
/// both halves to grey an entry out WITH A REASON instead of hiding it.
List<(FormatSpec spec, bool available)> availabilityFor(
  Set<String> available,
  MediaKind kind,
) {
  return [
    for (final spec in formatsFor(kind))
      (spec, isFormatAvailable(spec, available)),
  ];
}
