// SPDX-License-Identifier: GPL-3.0-or-later

/// Parsing of `ffmpeg -encoders` / `-muxers` output into codec names.
///
/// The probe exists because the app ships a prebuilt ffmpeg: which codecs are
/// inside is a property of the PACKAGE, not of our code. Today's build has
/// `libwebp` but no `libjxl`; a future custom build flips that. The UI asks
/// this set instead of assuming, so a missing codec greys the format out with
/// an explanation rather than failing after the user pressed Convert.
library;

/// Extracts the encoder/muxer names from `ffmpeg -encoders` / `-muxers` text.
///
/// Two layouts have to be handled, and they differ between ffmpeg versions:
///
/// ```
///  V....D libwebp              libwebp WebP image     <- 6-column flag field
///   E avif             AVIF muxer                     <- 1-letter flag field
/// ```
///
/// The flags themselves are not interpreted: the letters changed across
/// versions (and old listings have no flag column at all), and nothing in this
/// app depends on them. Only the NAME is extracted, with one heuristic to tell
/// a flag column apart from an uppercase codec name (`RPZA`): a flag column is
/// followed by a token that starts lower-case, a codec name by a description.
Set<String> parseCodecNames(String listing) {
  final names = <String>{};
  for (final rawLine in listing.split('\n')) {
    final line = rawLine.trimRight().trimLeft();
    if (line.isEmpty) continue;
    // "Encoders:", "------", " V..... = Video".
    if (line.endsWith(':') || line.startsWith('-') || line.contains(' = ')) {
      continue;
    }

    String name;
    final withFlags = RegExp(r'^([A-Z.]{1,6})\s+(\S+)').firstMatch(line);
    if (withFlags != null &&
        RegExp(r'^[a-z0-9]').hasMatch(withFlags.group(2)!)) {
      name = withFlags.group(2)!;
    } else {
      name = line.split(RegExp(r'\s+')).first;
    }

    if (!RegExp(r'^[a-z0-9][a-zA-Z0-9_\-]*$').hasMatch(name)) continue;
    names.add(name);
  }
  return names;
}
