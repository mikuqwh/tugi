// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - FFmpeg command builders.
///
/// Pure Dart: no Flutter and no plugin imports, so the whole command surface
/// is unit-testable on the host VM with `dart run test`. The execution side
/// (which does need ffmpeg-kit) lives in ffmpeg_pipeline.dart and re-exports
/// everything here, so callers keep importing a single file.
///
/// and the filter graph, and the global options, must be separate argv entries.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:format_core/format_core.dart';

import '../models/encode_preset.dart';
import '../utils/params.dart';

/// Build Video to GIF command.
///
///   ` -filter_complex [0:v]split[s1][s2];[s1]palettegen=stats_mode=single[p];
///
/// The previous implementation decodes the video in a SINGLE pass; there is no
/// extract-to-PNG-then-concat stage in this path (its
/// `/video_to_image_%06d.` template is only used for thumbnails). One pass
/// also keeps peak memory low, which matters here: the `split` +
/// `palettegen` graph buffers the `[b]` branch until EOF.
///
/// [dedup] prepends mpdecimate, dropping duplicate frames for a smaller file
/// at the cost of the output frame count no longer matching `duration * fps`.
/// It must run BEFORE `fps`, otherwise resampling re-introduces the
/// duplicates it was meant to remove.
/// `trim=start=..:end=..` (or an empty string).
String _trimExpr(double? start, double? end) {
  final parts = <String>[
    if (start != null && start > 0) 'start=${start.toStringAsFixed(3)}',
    if (end != null && end > 0) 'end=${end.toStringAsFixed(3)}',
  ];
  if (parts.isEmpty) return '';
  return 'trim=${parts.join(':')}';
}

/// The same expression with the trailing comma a filter chain needs.
String _trimFilter(double? start, double? end) {
  final expr = _trimExpr(start, end);
  return expr.isEmpty ? '' : '$expr,';
}

/// `-ss` / `-t` for the input side of a video command.
///
/// Seeking BEFORE `-i` is ffmpeg's fast path (jump to the nearest keyframe);
/// the resulting start can be up to one GOP early, which a GIF at 12 fps
/// cannot show anyway. Seeking after `-i` would decode the whole prefix.
/// `crop=w:h:x:y` (or an empty string) for the head of a filter chain.
String _cropExpr(String? crop) => (crop == null || crop.isEmpty) ? '' : crop;

List<String> _trimInputArgs(double? start, double? duration) {
  if (start == null && duration == null) return const [];
  return [
    if (start != null && start > 0) ...['-ss', start.toStringAsFixed(3)],
    if (duration != null && duration > 0) ...[
      '-t',
      duration.toStringAsFixed(3)
    ],
  ];
}

List<String> videoToGif({
  required String inputPath,
  required String outputPath,
  int fps = 12,
  int? outputWidth,
  bool loop = true,
  bool dedup = false,
  double? start,
  double? duration,
  String? crop,
  EncodePreset preset = EncodePreset.balanced,
}) {
  final pre = <String>[
    // Cropping first means the encoder never sees the discarded pixels.
    if (_cropExpr(crop).isNotEmpty) _cropExpr(crop),
    'fps=$fps',
    // `mpdecimate` must run AFTER `fps`, not before:
    //   before -> it dedups at the source rate (30 fps here) and the following
    //             `fps` filter resamples back up, so almost nothing is dropped
    //             (100 frames out of 100, i.e. no dedup at all);
    //   after  -> it dedups at the target rate, which is the point.
    // And no `setpts=N/FRAME_RATE/TB`: renumbering the surviving frames
    // compacts away the time gaps the dropped frames left behind, so a 5 s
    // video came out as 2.5 s. Leaving the previous implementation PTS alone lets `-fps_mode
    // vfr` widen the delay of the frame that follows a drop (50/100 ms instead
    // of a flat 50 ms), which keeps the total duration correct.
    if (dedup) 'mpdecimate',
    if (outputWidth != null) 'scale=${outputWidth.toInt()}:-2:flags=lanczos',
  ];
  // The chain must read `fps=N,split[s1][s2];[s1]palettegen...[p];[s2][p]...`
  // with the pre-stages UNLABELLED and glued directly onto `split`.
  //
  // Two wrong forms, both found on the device:
  //   `[0:v]fps=12,[0:v]split...` -> two unlabeled video outputs, and the GIF
  //       muxer refuses with "gif muxer does not support more than one stream
  //       of type video".
  //   `[0:v]fps=12,split[s1][s2]...` (label kept on the fps stage) -> "More
  //       output link labels specified for filter 'fps' than it has outputs:
  //       2 > 1", because [s1]/[s2] then bind to `fps` instead of `split`.
  // Build the tail of the chain by hand rather than slicing `paletteFilter`:
  // string surgery inside a `${...}` interpolation upset the kernel
  // snapshotter (`Target kernel_snapshot_program failed`) even though
  // `flutter analyze` was clean.
  final filter = '${pre.join(',')},${preset.gifPaletteTail}';

  return [
    '-y',
    ..._trimInputArgs(start, duration),
    '-i',
    inputPath,
    '-filter_complex',
    filter,
    ...gifFlags,
    // GIF muxer loop count: 0 = loop forever, 1 = play once. The default is
    // already 0, so "play once" has to be asked for explicitly -- omitting
    // the flag does NOT turn looping off.
    ...['-loop', loop ? '0' : '1'],
    // (host) and ffmpeg-kit 8.0.0 (device) removed `-vsync`; the replacement
    // is `-fps_mode`. vfr and `-r` are mutually exclusive -- ffmpeg rejects
    // the combination with "One of -r/-fpsmax was specified together a
    // non-CFR -fps_mode" -- so in dedup mode the output rate comes from the
    // filter's own `fps=` stage instead.
    //
    // Measured on the 5 s / 30 fps / 640x480 fixture:
    //   fps=12          -> 60 frames, delays 80/90 ms
    //   fps=12 + dedup  -> 30 frames, delays 80/90 ms (mpdecimate halved it)
    //   fps=20 w=480    -> 100 frames, delay 50 ms, 480x360
    //   fps=20 w=480 + dedup -> 55 frames, delays 50/100 ms, still 5.00 s
    if (dedup) ...['-fps_mode', 'vfr'] else ...['-r', fps.toString()],
    '-f',
    'gif',
    outputPath,
  ];
}

/// Build Images to GIF command (concat + palette).
/// ASSUMPTION: T2 PASS.
List<String> imagesToGif({
  required String concatListPath,
  required String outputPath,
  int fps = 12,
  bool loop = true,
}) {
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    concatListPath,
    '-filter_complex',
    'fps=$fps,split[s1][s2];'
        '[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1',
    ...gifFlags,
    ...['-loop', loop ? '0' : '1'],
    '-r',
    fps.toString(),
    '-f',
    'gif',
    outputPath,
  ];
}

/// Build GIF to Video command.
///
///   `The above selection is resolution width, height will be auto-calculated
///
/// The previous implementation offers "keep the source resolution or pick a width"; there is
/// function defaulted to `scale=iw*0.5`, which was a guess and is wrong), so
/// [outputWidth] == null means "do not scale at all".
///
/// [fps] re-times the GIF onto a constant frame rate. Note that this changes
/// the frame COUNT, not just the timing: a 77-frame / 5.14 s GIF (about 15 fps)
/// yields 62 frames at 12 fps and all 77 at 15 fps.
List<String> gifToVideo({
  required String inputPath,
  required String outputPath,
  int fps = 12,
  int? outputWidth,
  FormatSpec? format,
  int quality = 75,
}) {
  final filters = <String>[
    'fps=$fps',
    // -2 keeps the height even, which yuv420p requires; odd heights make
    // libx264 fail outright.
    if (outputWidth != null) 'scale=${outputWidth.toInt()}:-2:flags=lanczos',
  ];

  // No format means the historical H.264 MP4, so callers that predate the
  // picker keep working byte-for-byte.
  final encoder = format?.encoderArgs ?? h264Encode;
  final qualityArgsList = format == null || format.quality == QualityPolicy.none
      ? const <String>[]
      : qualityArgs(format.quality, quality);
  final ext = format?.extension ?? 'mp4';

  return [
    '-y',
    '-i',
    inputPath,
    '-vf',
    filters.join(','),
    ...encoder,
    ...qualityArgsList,
    if (ext == 'mp4' || ext == 'mov') ...['-movflags', '+faststart'],
    outputPath,
  ];
}

/// Single-pass video -> APNG.
///
/// The APNG twin of [videoToGif]: same pre-stages (fps, optional dedup and
/// scale) but no palette split -- APNG is true-colour, so quantising would
/// throw away exactly what it is for.
///
/// `fps=` IS needed here, unlike [apngFromFrames]: the input is a video with
/// its own timestamps, and the user picked a target rate. It is applied once,
/// before anything else, so the muxer's delays follow the resampled frames.
List<String> videoToApng({
  required String inputPath,
  required String outputPath,
  int fps = 12,
  int? outputWidth,
  bool loop = true,
  bool dedup = false,
  double? start,
  double? duration,
  String? crop,
}) {
  final filters = <String>[
    if (_cropExpr(crop).isNotEmpty) _cropExpr(crop),
    'fps=$fps',
    if (dedup) 'mpdecimate',
    if (outputWidth != null) 'scale=${outputWidth.toInt()}:-2:flags=lanczos',
  ];
  return [
    '-y',
    ..._trimInputArgs(start, duration),
    '-i',
    inputPath,
    '-vf',
    filters.join(','),
    ...['-plays', loop ? '0' : '1'],
    '-f',
    'apng',
    outputPath,
  ];
}

/// Build GIF to Images command (frame extraction).
/// ASSUMPTION: T4 PASS (36 PNG frames).
///
///   `Confirm to save all frames?` / `Confirm to save all images?`
///   `cancel_extracting_frames`  extraction is cancellable
///
/// [framestep] = keep 1 frame out of every N (1 = keep everything).
/// [outputWidth] = optional horizontal scale; height follows via -1.
///
/// The filters go into a single `-filter_complex` placed AFTER `-i <input>`.
/// (The previous implementation spliced `-vf framestep=N` in at index 2,
/// which landed between `-i` and its value and made ffmpeg read "-vf" as
/// the input filename -- every framestep > 1 run silently failed.)
///
/// DO NOT pass `-ignore_loop 0` (see compressGif for why: both host 9.0.2 and
/// device 8.0.0 decode the GIF forever and abort with a Scudo OOM).
List<String> gifToImages({
  required String inputPath,
  required String outputPattern,
  int framestep = 1,
  int? outputWidth,
  List<String> encoderArgs = const [],
  List<String> qualityArgs = const [],
}) {
  final filters = <String>[];
  if (framestep > 1) filters.add('framestep=$framestep');
  if (outputWidth != null) filters.add('scale=$outputWidth:-1');

  return [
    '-y',
    '-i', inputPath,
    if (filters.isNotEmpty) ...['-filter_complex', '[0:v]${filters.join(',')}'],
    ...encoderArgs,
    ...qualityArgs,
    // ffmpeg infers the image2 muxer + encoder from the extension; the
    // encoder args above are only needed where the extension is ambiguous or
    // the default quality is wrong (JPEG, WebP).
    outputPattern,
  ];
}

/// Build Compress GIFs command (Reduce Resolution mode).
///
/// 2026-10-15: input 320x180/77f/727KB -> 50% -> 160x90/77f/263KB.
/// Measured facts:
///  - output dims = input * ratio exactly (scale=iw*<ratio>:-1)
///  - frame count and per-frame delays preserved
///  - palette stays 256 colors (no max_colors reduction)
///  - NO dithering: output is 98.2% pixel-identical to a plain lanczos scale
///    (floyd_steinberg would create checkerboard noise across gradients)
///  - output GIF keeps the source loop count (written by `-loop 0` below)
///
/// the palette pass wants it). Both ffmpeg builds we tested treat it as "decode
/// the GIF forever" instead of "respect the loop count":
///  - host ffmpeg 9.0.2 (gyan): hangs/OOM on a 77-frame looping GIF
///  - device ffmpeg-kit 8.0.0: native abort, `Scudo ERROR: internal map
///    failure (Out of memory)` in av_buffersrc_add_frame_flags
/// Cause: the `split` + `palettegen` graph buffers every frame of the [b]
/// branch until palettegen emits the palette at EOF. An infinite decode means
/// that buffer never stops growing. Without the flag the same command finishes
/// in seconds and the output is byte-identical to this app
/// (md5 ed27faf05c7bddecec15b2ddb58a903a, 262995 bytes @ 50%).
List<String> compressGif({
  required String inputPath,
  required String outputPath,
  required double ratio,
  bool loop = true,
}) {
  // ratio is the linear scale factor on width (0.8 / 0.5 / 0.2 / custom).
  // Height follows via -1 to preserve aspect ratio.
  final filter = '[0:v]scale=iw*$ratio:-1:flags=lanczos,'
      'split[a][b];[a]palettegen=reserve_transparent=on:transparency_color=ffffff[p];'
      '[b][p]paletteuse';
  return [
    '-y',
    '-i',
    inputPath,
    '-filter_complex',
    filter,
    ...gifFlags,
    ...['-loop', loop ? '0' : '1'],
    '-f',
    'gif',
    outputPath,
  ];
}

/// Build Compress GIFs command (Extract Frames mode).
///
/// This is this app's second compress mode: instead of making the
/// picture smaller, it keeps fewer frames. The reverse-engineered evidence is
/// the string set `compress_mode` / `extract_way` / `extract_2_1` /
/// `extract_3_1` / `extract_5_1` (the reference strings) plus the command fragments
/// ` -r 12 -y -f gif` and `-vf 'fps=` -- a frame-rate reduction, not a
/// resolution one.
///
/// [sourceFps] is the source GIF's average frame rate; the pipeline asks for
/// `sourceFps / frameStep`, which keeps ONE frame in every [frameStep].
///
/// Why `fps=` rather than `select=not(mod(n\,N))`: both keep the same frames
/// and produce the same bytes (measured: 335261 both ways at step 2), but
/// `select` leaves the LAST kept frame's delay unextended, so a 3.00 s source
/// came out 2.80 s at step 5. `fps=` re-times evenly and keeps 3.00 s
/// (measured at steps 2, 3 and 5). Sound timing matters more than avoiding a
/// near-duplicate frame on odd rates.
List<String> compressGifByFrames({
  required String inputPath,
  required String outputPath,
  required double sourceFps,
  required int frameStep,
  bool loop = true,
}) {
  final step = frameStep < 2 ? 1 : frameStep;
  // An unreadable rate assumes a 10 fps source rather than 0 (fps=0 makes
  // ffmpeg fail); the stride then applies to that assumption.
  final baseFps = sourceFps <= 0 ? 10.0 : sourceFps;
  final target = baseFps / step;
  // Six decimals. ffmpeg WOULD take a rational (`fps=20/3` was measured
  // working), but the source rate here is a measurement -- frames over
  // summed frame delays -- not a nice fraction, so there is nothing exact to
  // put in the numerator. Six decimals of 20/3 keeps a 3 s GIF within a
  // frame of 3.00 s.
  final rate = target.toStringAsFixed(6);
  final filter = '[0:v]fps=$rate,'
      'split[a][b];[a]palettegen=reserve_transparent=on:transparency_color=ffffff[p];'
      '[b][p]paletteuse';
  return [
    '-y',
    '-i',
    inputPath,
    '-filter_complex',
    filter,
    ...gifFlags,
    ...['-loop', loop ? '0' : '1'],
    '-f',
    'gif',
    outputPath,
  ];
}

/// Where a watermark sits on the frame.
///
///
/// The x/y expression FRAGMENTS the previous implementation assembles those anchors from
/// are the ground truth for the geometry:
///
///
/// and for the image variant:
///
///
/// The 9 anchors below are exactly what those fragments spell out, with a
/// 10 px margin on the right/bottom edges (the previous implementation's own bottom-right
/// overlay uses `-10`).
enum WatermarkPosition {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

/// Where a watermark sits, in one of two ways.
///
/// * an **anchor** -- one of the nine presets. This is what the previous implementation
///   exposes through its own named anchors, and it keeps the margin the
///   original uses.
/// * a **free** position -- the watermark's CENTRE as a fraction of the
///   frame, each axis 0..1. This is what the drag gesture produces.
///
/// The free form deliberately stores a centre fraction rather than a pixel
/// offset: the screen drags at preview resolution but ffmpeg renders at
/// source resolution, and a fraction is the one form that means the same
/// thing at both. It is also why the builder emits
/// `x = fx*main_w - text_w/2` and lets ffmpeg do the subtraction -- the
/// watermark's own size is known to ffmpeg but not to the caller, and
/// measuring it in Dart would reintroduce exactly the mismatch this avoids.
class WatermarkPlacement {
  const WatermarkPlacement.anchor(WatermarkPosition anchor, {this.margin = 10})
      : _anchor = anchor,
        fx = 0,
        fy = 0;

  const WatermarkPlacement.free(this.fx, this.fy)
      : _anchor = null,
        margin = 10;

  final WatermarkPosition? _anchor;

  /// The preset anchor, or null for a free position.
  WatermarkPosition? get anchor => _anchor;

  /// True when this is a free (dragged) position.
  bool get isFree => _anchor == null;

  /// The gap kept from the right and bottom edges, for anchored placements.
  final int margin;

  /// The watermark's centre as a fraction of the frame, for free placements.
  final double fx;
  final double fy;
}

/// The x/y expressions for a watermark of the given [textWidth] x
/// [textHeight] at [position].
///
/// One table for both the text and the image variant: the geometry is the
/// same, only the size variable differs (`text_w`/`text_h` vs
/// `overlay_w`/`overlay_h`). Keeping them in one place stops the two
/// variants from drifting apart.
///
/// [margin] is the gap kept from the right and bottom edges, matching the
/// original's `overlay=main_w-overlay_w-10:main_h-overlay_h-10`.
///
/// Note the trailing-dash fragments in the previous implementation
/// the margin number is appended to them, which is what makes
/// `main_h-text_h-` a valid expression at all (a bare trailing `-` would
/// not parse).
String watermarkPositionExpression(
  WatermarkPosition position, {
  required String sizeVar,
  int margin = 10,
}) {
  final (x, y) =
      watermarkPositionParts(position, sizeVar: sizeVar, margin: margin);
  return 'x=$x:y=$y';
}

/// The x/y expression for any [placement], anchored or free.
///
/// This is what the builders call. It dispatches on the placement kind so
/// the two forms can never drift apart in how they are spelled.
String watermarkPlacementExpression(
  WatermarkPlacement placement, {
  required String sizeVar,
}) {
  final (x, y) = watermarkPlacementParts(placement, sizeVar: sizeVar);
  return 'x=$x:y=$y';
}

/// The raw x and y expressions for [placement], without the `x=`/`y=`
/// prefixes.
///
/// Split out so the positional form (`overlay=<x>:<y>`) and the named form
/// (`x=<x>:y=<y>`) are built from the SAME strings. Do not derive one from
/// the other by slicing -- a slice of `x=main_w/2-overlay_w/2` that drops
/// the prefix also drops the first two characters of the expression, and
/// the resulting `in_w/2-overlay_w/2` fails only at ffmpeg runtime.
(String, String) watermarkPlacementParts(
  WatermarkPlacement placement, {
  required String sizeVar,
}) {
  final anchor = placement.anchor;
  if (anchor != null) {
    return watermarkPositionParts(
      anchor,
      sizeVar: sizeVar,
      margin: placement.margin,
    );
  }

  // Free: the watermark's centre, as a fraction of the frame.
  //
  // ffmpeg evaluates this per frame, so `main_w`/`main_h` are the real
  // frame size and `text_w`/`overlay_w` the real watermark size -- the
  // watermark lands centred on the dragged point without the caller
  // having to measure anything.
  final parts = sizeVar.split('/');
  final w = parts[0];
  final h = parts[1];
  final fx = placement.fx.clamp(0.0, 1.0);
  final fy = placement.fy.clamp(0.0, 1.0);
  return ('${_fmt(fx)}*main_w-$w/2', '${_fmt(fy)}*main_h-$h/2');
}

/// Format a fraction for an ffmpeg expression.
///
/// `0.5` must not become `0.5000000000000000` -- the expression is a
/// string that gets embedded in the command, and a shorter one is easier to
/// read in a log. Six decimals is sub-pixel at any realistic frame width.
String _fmt(double v) {
  var s = v.toStringAsFixed(6);
  // Trim trailing zeros, but keep at least one decimal so the result is
  // never an integer-looking literal like `0` (which would still parse, but
  // reads as a bug).
  s = s.replaceAll(RegExp(r'0+$'), '');
  s = s.replaceAll(RegExp(r'\.$'), '.0');
  return s;
}

/// The raw x and y expressions for [position], without the `x=`/`y=`
/// prefixes.
///
/// Split out so the positional form (`overlay=<x>:<y>`) and the named form
/// (`x=<x>:y=<y>`) are built from the same numbers, with no string
/// surgery between them.
(String, String) watermarkPositionParts(
  WatermarkPosition position, {
  required String sizeVar,
  int margin = 10,
}) {
  // `sizeVar` is the pair of ffmpeg size variables, e.g. 'text_w/text_h'.
  final sizeParts = sizeVar.split('/');
  final w = sizeParts[0];
  final h = sizeParts[1];
  final m = margin;
  String x;
  String y;
  switch (position) {
    case WatermarkPosition.topLeft:
      x = '0';
      y = '0';
      break;
    case WatermarkPosition.topCenter:
      x = 'main_w/2-$w/2';
      y = '0';
      break;
    case WatermarkPosition.topRight:
      x = 'main_w-$w-$m';
      y = '0';
      break;
    case WatermarkPosition.centerLeft:
      x = '0';
      y = 'main_h/2-$h/2';
      break;
    case WatermarkPosition.center:
      x = 'main_w/2-$w/2';
      y = 'main_h/2-$h/2';
      break;
    case WatermarkPosition.centerRight:
      x = 'main_w-$w-$m';
      y = 'main_h/2-$h/2';
      break;
    case WatermarkPosition.bottomLeft:
      x = '0';
      y = 'main_h-$h-$m';
      break;
    case WatermarkPosition.bottomCenter:
      x = 'main_w/2-$w/2';
      y = 'main_h-$h-$m';
      break;
    case WatermarkPosition.bottomRight:
      x = 'main_w-$w-$m';
      y = 'main_h-$h-$m';
      break;
  }
  return (x, y);
}

/// The `drawtext` filter body for a text watermark.
///
///
/// **The text goes in through `textfile=`, never inline.**
///
/// The previous implementation interpolates the user's text straight into `:text='...'`,
/// which is a filtergraph string. That makes the text subject to TWO
/// layers of parsing (the filtergraph's own quoting, and drawtext's `%{}`
/// expansion) and a watermark containing `%` or `:` breaks the command.
///
/// Measured on host ffmpeg 9.0.2: `text='50%'` fails with `Stray % near ''`,
/// and `text='50%%'` fails too (it eats a `%` and still errors) -- so the
/// "double the percent signs" workaround does not exist on this build.
/// `expansion=none` plus `textfile=` sidesteps both layers entirely, and
/// was measured to survive 15/15 hostile inputs (percent signs, colons,
/// quotes, backslashes, commas, semicolons, newlines, full-width
/// punctuation).
///
/// `expansion=none` also switches off drawtext's `%{...}` expansion, which
/// is what a *dynamic* watermark (a timestamp, say) would need. This
/// builder is for STATIC watermarks; a dynamic one would have to handle
/// `%` deliberately and must not reuse this path.
String drawtextWatermarkFilter({
  required String fontFilePath,
  required String textFilePath,
  required int fontSize,
  required String fontColor,
  required WatermarkPlacement placement,
  double opacity = 1.0,
}) {
  final pos = watermarkPlacementExpression(
    placement,
    sizeVar: 'text_w/text_h',
  );
  // `fontcolor=white@0.6` is ffmpeg's own colour-with-alpha syntax; the
  // separate `alpha=` option would be a SECOND multiplier, so pick one.
  // The colour form is what the previous implementation uses (`:fontcolor=` + `:alpha=`).
  final color =
      opacity >= 1.0 ? fontColor : '$fontColor@${opacity.toStringAsFixed(3)}';
  return 'drawtext=fontfile=$fontFilePath:'
      'textfile=$textFilePath:'
      'expansion=none:'
      'fontsize=$fontSize:'
      'fontcolor=$color:'
      '$pos';
}

/// The filter stage that prepares the watermark image for compositing.
///
///
/// The previous implementation applies image-watermark opacity with
/// `colorchannelmixer=aa=<v>`, which multiplies the alpha channel of an
/// RGBA stream. `overlay` itself has an `alpha` option, but that one
/// switches between premultiplied and straight alpha -- it is NOT an
/// opacity knob, so it is not what "adjust opacity of watermark"
///
/// `format=rgba` is not optional even at full opacity: `colorchannelmixer`
/// needs an alpha channel to scale, and a source without one (a plain
/// JPEG) would otherwise be treated as fully opaque. Normalising every
/// watermark to RGBA also keeps the branch identical whether or not an
/// opacity was asked for.
///
/// This is a SEPARATE filter stage, not a prefix to the `overlay`
/// options: `colorchannelmixer` does not understand `x`/`y`, so folding
/// the position into the same filter would make ffmpeg reject the graph.
String overlayWatermarkAlphaStage(double opacity) {
  final buffer = StringBuffer('format=rgba');
  if (opacity < 1.0) {
    buffer.write(',colorchannelmixer=aa=${opacity.toStringAsFixed(3)}');
  }
  return buffer.toString();
}

/// The `overlay` filter body for an image watermark.
///
///
/// The position is passed POSITIONALLY (`overlay=<x>:<y>`), the way the
/// original spells it, rather than as named `x=`/`y=` options. Both forms
/// work in ffmpeg, but matching the previous implementation keeps the command
/// byte-comparable against it.
String overlayWatermarkFilter({
  required WatermarkPlacement placement,
}) {
  final (x, y) = watermarkPlacementParts(
    placement,
    sizeVar: 'overlay_w/overlay_h',
  );
  return 'overlay=$x:$y';
}

/// The palette tail every GIF output needs.
///
/// separate string (`split[s1][s2];[s1]palettegen=stats_mode=single[p];
/// glues it onto whatever the feature did to the frames.
///
/// A GIF cannot carry truecolour, so the frames have to be quantised. The
/// watermark therefore has to be applied BEFORE the palette split, not
/// after -- a watermark added to the palette would be quantised into
/// whatever colours happened to survive, and a semi-transparent one would
/// be destroyed.
const String watermarkGifTail =
    'split[s1][s2];[s1]palettegen=stats_mode=single[p];[s2][p]paletteuse=new=1';

/// What kind of media the watermark is being applied to, and therefore what
/// the output looks like.
///
/// a GIF output needs the palette split, an image output is a single
/// frame, a video output needs H.264.
enum WatermarkMediaKind {
  gif,
  image,
  video,
}

/// Build the Add Watermark command (text watermark).
///
///
/// [textFilePath] must point at a file holding the literal watermark text.
/// The text is deliberately NOT a parameter of this function: see
/// [drawtextWatermarkFilter] for why it must not be spliced into the
/// filtergraph.
///
/// [fontFilePath] must be an absolute path to a TTF/OTF. The device build
/// has no usable fontconfig, so there is no system-font fallback: without
/// `fontfile=` the filter aborts with "Cannot find a valid font".
///
/// [kind] selects the output shape:
///  - [WatermarkMediaKind.gif] gets the palette tail (a GIF is 256-colour,
///    so the watermark has to be drawn before the quantisation) plus the
///    GIF muxer flags;
///  - [WatermarkMediaKind.image] is a plain single-frame encode;
///  - [WatermarkMediaKind.video] adds the H.264 encoder.
List<String> addWatermarkText({
  required String inputPath,
  required String outputPath,
  required String textFilePath,
  required String fontFilePath,
  WatermarkMediaKind kind = WatermarkMediaKind.gif,
  int fontSize = 24,
  String fontColor = 'white',
  WatermarkPlacement placement =
      const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
  double opacity = 1.0,
  bool loop = true,
}) {
  final drawtext = drawtextWatermarkFilter(
    fontFilePath: escapeFilterPath(fontFilePath),
    textFilePath: escapeFilterPath(textFilePath),
    fontSize: fontSize,
    fontColor: fontColor,
    placement: placement,
    opacity: opacity,
  );

  switch (kind) {
    case WatermarkMediaKind.gif:
      return [
        '-y',
        '-i',
        inputPath,
        '-filter_complex',
        '$drawtext,$watermarkGifTail',
        ...gifFlags,
        ...['-loop', loop ? '0' : '1'],
        '-f',
        'gif',
        outputPath,
      ];
    case WatermarkMediaKind.image:
      return [
        '-y',
        '-i',
        inputPath,
        '-vf',
        drawtext,
        outputPath,
      ];
    case WatermarkMediaKind.video:
      return [
        '-y',
        '-i',
        inputPath,
        '-vf',
        drawtext,
        ...h264Encode,
        '-movflags',
        '+faststart',
        outputPath,
      ];
  }
}

/// Build the Add Watermark command (image watermark).
///
///
/// The watermark image is the SECOND input; the source is the first. The
/// `overlay` filter consumes both.
///
/// [watermarkWidth] scales the watermark before it is composited, in
/// own branch, before the overlay, so the overlay's `overlay_w`/`overlay_h`
/// refer to the SCALED size -- which is what the position maths needs.
List<String> addWatermarkImage({
  required String inputPath,
  required String watermarkPath,
  required String outputPath,
  WatermarkMediaKind kind = WatermarkMediaKind.gif,
  WatermarkPlacement placement =
      const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
  double opacity = 1.0,
  int? watermarkWidth,
  bool loop = true,
}) {
  final alpha = overlayWatermarkAlphaStage(opacity);
  final overlay = overlayWatermarkFilter(placement: placement);
  final scale = watermarkWidth == null || watermarkWidth <= 0
      ? ''
      : 'scale=$watermarkWidth:-1,';
  // The watermark stream is normalised to RGBA (so the alpha channel
  // exists) and, when an opacity is asked for, scaled by it. That happens
  // on the watermark's own branch BEFORE the overlay, because
  // `colorchannelmixer` and `overlay` are different filters and cannot
  // share one option string.
  final chain = '[1:v]$scale$alpha[wm];[0:v][wm]$overlay';

  switch (kind) {
    case WatermarkMediaKind.gif:
      return [
        '-y',
        '-i',
        inputPath,
        '-i',
        watermarkPath,
        '-filter_complex',
        '$chain,$watermarkGifTail',
        ...gifFlags,
        ...['-loop', loop ? '0' : '1'],
        '-f',
        'gif',
        outputPath,
      ];
    case WatermarkMediaKind.image:
      return [
        '-y',
        '-i',
        inputPath,
        '-i',
        watermarkPath,
        '-filter_complex',
        chain,
        outputPath,
      ];
    case WatermarkMediaKind.video:
      return [
        '-y',
        '-i',
        inputPath,
        '-i',
        watermarkPath,
        '-filter_complex',
        chain,
        ...h264Encode,
        '-movflags',
        '+faststart',
        outputPath,
      ];
  }
}

/// Build the Add Watermark command (GIF watermark -- an animated one).
///
/// The user's mental model is "put this GIF on top", and that is roughly
/// what happens: the watermark is a second VIDEO stream and `overlay`
/// composites it frame by frame. Three details make it actually work.
///
/// **1. The watermark has to be looped.**
/// `overlay`'s default `eof_action` is `repeat`, which holds the
/// watermark's LAST frame once its input ends -- so a 1 s watermark on a
/// 3 s source freezes for the last 2 s and looks broken. Measured on host
/// ffmpeg 9.0.2 with a 1 s watermark on a 2 s base: without looping, frames
/// 12-24 are byte-identical; with it, the sequence resumes.
///
/// Looping needs the `loop` filter (`loop=loop=-1`) on the watermark's own
/// branch. `-ignore_loop 1` on the input does NOT do it -- measured, it
/// produces output identical to not looping at all.
///
/// **2. `shortest=1` is mandatory once the watermark loops.**
/// An infinitely looping input never ends, so `overlay`'s default of
/// "run until the longest input ends" never terminates -- measured, that
/// produced 19306 frames / 2436 s from a 2 s source. `shortest=1` cuts the
/// output at the base's end, which is the length the user expects.
///
/// **3. `size` must be at least the watermark's frame count.**
/// The `loop` filter's `size` is its frame-buffer capacity. Measured:
/// `size=1` collapses the watermark to a single frozen frame (24 frames,
/// 1 unique state); `size=0` broke a short watermark entirely (11 frames
/// instead of 24); anything >= the watermark's frame count is correct. The
/// caller passes the real count read from the file, so this is exact
/// rather than a guessed constant.
///
/// [watermarkFrames] is that count. When it is unknown the caller should
/// pass a generous value rather than a small one.
///
/// The output for a GIF source is still a GIF, so the palette tail comes
/// after the overlay as usual.
List<String> addWatermarkGif({
  required String inputPath,
  required String watermarkPath,
  required String outputPath,
  WatermarkMediaKind kind = WatermarkMediaKind.gif,
  WatermarkPlacement placement =
      const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
  double opacity = 1.0,
  int? watermarkWidth,
  int watermarkFrames = 256,
  bool loop = true,
}) {
  final alpha = overlayWatermarkAlphaStage(opacity);
  final overlay = overlayWatermarkFilter(placement: placement);
  final scale = watermarkWidth == null || watermarkWidth <= 0
      ? ''
      : 'scale=$watermarkWidth:-1,';
  final bufferSize = watermarkFrames < 1 ? 1 : watermarkFrames;
  // Note the comma after the alpha stage: `overlayWatermarkAlphaStage`
  // returns a bare filter chain with no trailing separator, and without it
  // `format=rgba` and `loop=` would fuse into one unparseable option name.
  final chain = '[1:v]$scale$alpha,loop=loop=-1:size=$bufferSize[wm];'
      '[0:v][wm]$overlay:shortest=1';

  switch (kind) {
    case WatermarkMediaKind.gif:
      return [
        '-y',
        '-i',
        inputPath,
        '-i',
        watermarkPath,
        '-filter_complex',
        '$chain,$watermarkGifTail',
        ...gifFlags,
        ...['-loop', loop ? '0' : '1'],
        '-f',
        'gif',
        outputPath,
      ];
    case WatermarkMediaKind.video:
      return [
        '-y',
        '-i',
        inputPath,
        '-i',
        watermarkPath,
        '-filter_complex',
        chain,
        ...h264Encode,
        '-movflags',
        '+faststart',
        outputPath,
      ];
    case WatermarkMediaKind.image:
      // A still image with an animated watermark: the output IS a GIF, and
      // its length follows the watermark (the base is a single frame that
      // overlay repeats). Looping is neither needed nor possible here --
      // there is no base length to cut at, so `shortest=1` would truncate
      // the output to one frame.
      return [
        '-y',
        '-i',
        inputPath,
        '-i',
        watermarkPath,
        '-filter_complex',
        '[1:v]$scale$alpha[wm];[0:v][wm]$overlay,$watermarkGifTail',
        ...gifFlags,
        ...['-loop', loop ? '0' : '1'],
        '-f',
        'gif',
        outputPath,
      ];
  }
}

/// What a single watermark layer is drawn from.
///
/// The three cases are separate because they composite differently: a text
/// watermark is a `drawtext` filter on the base stream, an image watermark
/// is a second input fed to `overlay`, and an animated GIF watermark is that
/// same overlay plus a `loop` filter (see [addWatermarkGif]).
enum WatermarkLayerKind {
  text,
  image,
  gif,
}

/// One watermark in a multi-layer job.
///
/// The fields are the union of what the three kinds need; the builder asserts
/// the ones its [kind] actually requires rather than modelling the three as
/// separate types, because the UI edits a heterogeneous list of them.
class WatermarkLayerSpec {
  const WatermarkLayerSpec({
    required this.kind,
    required this.placement,
    this.opacity = 1.0,
    this.textFilePath,
    this.fontFilePath,
    this.fontSize = 24,
    this.fontColor = 'white',
    this.mediaPath,
    this.width,
    this.frames = 256,
  });

  final WatermarkLayerKind kind;
  final WatermarkPlacement placement;
  final double opacity;

  /// Text layers only: the file holding the literal text, and the font.
  final String? textFilePath;
  final String? fontFilePath;
  final int fontSize;
  final String fontColor;

  /// Image/GIF layers only: the watermark file.
  final String? mediaPath;

  /// Image/GIF layers only: the watermark's width in SOURCE pixels.
  final int? width;

  /// GIF layers only: the watermark's own frame count, for the `loop`
  /// filter's buffer size.
  final int frames;
}

/// Build the Add Watermark command for one or more layers, in a single pass.
///
/// The layers are composited in list order: later layers paint over earlier
/// ones. Each still-image or animated-GIF layer becomes one extra `-i` input,
/// and the graph threads the base stream through them:
///
/// ``
/// [0:v]drawtext=...[b0];
/// [1:v]scale=60:-1,format=rgba[wm1];
/// [b0][wm1]overlay=x:y[o1];
/// [2:v]scale=40:-1,format=rgba,loop=loop=-1:size=8[wm2];
/// [o1][wm2]overlay=x:y:shortest=1[o2];
/// [o2]split[s1][s2];[s1]palettegen=...[s2][p]paletteuse=new=1
/// ``
///
/// Why one pass rather than N passes: each extra pass is another full
/// re-encode. A GIF would be quantised twice and a video would lose another
/// generation of quality, on top of N times the runtime.
///
/// Two rules differ from the single-layer builders, both about duration:
///
///  - **Moving source** (GIF/video): animated layers are looped and their
///    overlays carry `shortest=1`, so the output ends with the source. This
///    is [addWatermarkGif]'s rule, applied per layer.
///  - **Still source**: nothing is looped and no `shortest` is used. The
///    shortest input there is the one-frame base, so `shortest=1` would cut
///    the output to a single frame; instead each animated watermark plays its
///    own length and `overlay`'s default `eof_action=repeat` holds its last
///    frame, so the output runs as long as the LONGEST watermark. With one
///    watermark that is exactly [addWatermarkGif]'s still-image behaviour.
///
/// Animated layers are ignored when the source is still only if they are the
/// only content: the caller decides the output kind ([kind]) from whether any
/// animated layer is present.
List<String> addWatermarks({
  required String inputPath,
  required String outputPath,
  required WatermarkMediaKind kind,
  required List<WatermarkLayerSpec> layers,
  bool loop = true,
  bool stillSource = false,
  FormatSpec? format,
  int quality = 90,
}) {
  if (layers.isEmpty) {
    throw ArgumentError.value(layers, 'layers', 'at least one layer');
  }

  final segments = <String>[];
  final pendingText = <String>[];
  var current = '[0:v]';
  var mediaInputs = 0;

  var closing = false;
  for (var i = 0; i < layers.length; i++) {
    final layer = layers[i];
    final last = i == layers.length - 1;

    switch (layer.kind) {
      case WatermarkLayerKind.text:
        final textPath = layer.textFilePath;
        final fontPath = layer.fontFilePath;
        if (textPath == null || fontPath == null) {
          throw ArgumentError('text layer needs textFilePath and fontFilePath');
        }
        pendingText.add(drawtextWatermarkFilter(
          fontFilePath: escapeFilterPath(fontPath),
          textFilePath: escapeFilterPath(textPath),
          fontSize: layer.fontSize,
          fontColor: layer.fontColor,
          placement: layer.placement,
          opacity: layer.opacity,
        ));
        if (last) {
          // The final stage stays UNLABELLED so it is the graph's output.
          segments.add('$current${pendingText.join(',')}');
          closing = true;
        }
      case WatermarkLayerKind.image:
      case WatermarkLayerKind.gif:
        final path = layer.mediaPath;
        if (path == null) {
          throw ArgumentError('${layer.kind.name} layer needs mediaPath');
        }
        // Flush any text waiting on the current stream before the overlay
        // takes it over.
        if (pendingText.isNotEmpty) {
          final label = '[t${segments.length}]';
          segments.add('$current${pendingText.join(',')}$label');
          current = label;
          pendingText.clear();
        }
        mediaInputs++;
        final prep = StringBuffer('[$mediaInputs:v]');
        if (layer.width != null && layer.width! > 0) {
          prep.write('scale=${layer.width}:-1,');
        }
        prep.write(overlayWatermarkAlphaStage(layer.opacity));
        if (layer.kind == WatermarkLayerKind.gif && !stillSource) {
          final buffer = layer.frames < 1 ? 1 : layer.frames;
          prep.write(',loop=loop=-1:size=$buffer');
        }
        final wm = '[wm$mediaInputs]';
        segments.add('$prep$wm');
        final overlay = overlayWatermarkFilter(placement: layer.placement);
        final shortest = layer.kind == WatermarkLayerKind.gif && !stillSource
            ? ':shortest=1'
            : '';
        final out = last ? '' : '[o$mediaInputs]';
        segments.add('$current$wm$overlay$shortest$out');
        current = out;
        if (last) closing = true;
    }
  }

  var graph = segments.join(';');
  final isApng = format?.id == 'apng';
  if (kind == WatermarkMediaKind.gif && !isApng) {
    // The palette split must come after every watermark (the tail comment on
    // [watermarkGifTail] explains why): it is appended to the stream that is
    // still unlabelled.
    graph = '$graph,$watermarkGifTail';
  }
  assert(closing, 'the last stage must close the graph');

  final inputs = <String>['-i', inputPath];
  for (final layer in layers) {
    if (layer.kind != WatermarkLayerKind.text) {
      inputs.addAll(['-i', layer.mediaPath!]);
    }
  }

  // No format keeps the historical output per kind: GIF for animations, PNG
  // for stills, H.264 MP4 for videos. The pickers pass one to widen that.
  final encoder = switch (kind) {
    WatermarkMediaKind.video => format?.encoderArgs ?? h264Encode,
    WatermarkMediaKind.image => format?.encoderArgs ?? const <String>[],
    WatermarkMediaKind.gif => const <String>[],
  };
  final qArgs = format == null || format.quality == QualityPolicy.none
      ? const <String>[]
      : qualityArgs(format.quality, quality);
  final ext = format?.extension ??
      switch (kind) {
        WatermarkMediaKind.video => 'mp4',
        WatermarkMediaKind.image => 'png',
        WatermarkMediaKind.gif => 'gif',
      };

  switch (kind) {
    case WatermarkMediaKind.gif:
      if (isApng) {
        // APNG is true-colour: no palette tail, no gif muxer flags, and the
        // loop is expressed as `-plays` instead of `-loop`.
        return [
          '-y',
          ...inputs,
          '-filter_complex',
          graph,
          ...['-plays', loop ? '0' : '1'],
          '-f',
          'apng',
          outputPath,
        ];
      }
      return [
        '-y',
        ...inputs,
        '-filter_complex',
        graph,
        ...gifFlags,
        ...['-loop', loop ? '0' : '1'],
        '-f',
        'gif',
        outputPath,
      ];
    case WatermarkMediaKind.image:
      return [
        '-y',
        ...inputs,
        '-filter_complex',
        graph,
        ...encoder,
        ...qArgs,
        if (format?.muxer != null) ...['-f', format!.muxer!],
        outputPath,
      ];
    case WatermarkMediaKind.video:
      return [
        '-y',
        ...inputs,
        '-filter_complex',
        graph,
        ...encoder,
        ...qArgs,
        if (ext == 'mp4' || ext == 'mov') ...['-movflags', '+faststart'],
        outputPath,
      ];
  }
}

///
/// Used for the "before" state of the preview: the subject has to be on
/// screen before the user has configured any watermark, and the animated
/// source cannot be shown directly (a GIF would play, and a video would
/// need a player).
List<String> firstFrame({
  required String inputPath,
  required String outputPath,
  int width = 480,
}) {
  return [
    '-y',
    '-i',
    inputPath,
    '-vf',
    'scale=$width:-2',
    '-frames:v',
    '1',
    outputPath,
  ];
}

/// Escape a filesystem path for use as a filtergraph option value.
///
/// Inside `key=value` the characters `\` and `:` are structural: a colon
/// would be read as the next option's separator, and a backslash as an
/// escape. On Android the app's paths look like
/// `/data/user/0/<pkg>/cache/...` and contain neither -- but the rule is
/// applied unconditionally rather than "on Android it is fine", because a
/// path that breaks the filtergraph is a very confusing failure.
String escapeFilterPath(String path) {
  return path
      .replaceAll('\\', '\\\\')
      .replaceAll(':', '\\:')
      .replaceAll("'", "\\'")
      .replaceAll('[', '\\[')
      .replaceAll(']', '\\]')
      .replaceAll(',', '\\,');
}

/// Build Images to Video command for a concat list of still images.
///
/// **Two different clocks, deliberately separate.**
///
/// - *How long each image stays* is the concat list's `duration` directive,
///   written by the service (`secondsPerImage`). It is NOT a builder argument.
/// - *How smooth the stream is* is [fps].
///
/// Measured on host ffmpeg 9.0.2 with the concat demuxer (5 images, ffprobe):
///
///   D=2.0  F=12 -> 10.000000 s, 120 frames   (expected 10.0 s / 120)
///   D=0.3  F=12 ->  1.500000 s,  18 frames   (expected  1.5 s /  18)
///
/// So `duration` alone controls output length here: the mp4 muxer honours the
/// PTS. That is the opposite of the GIF path, where the gif muxer takes each
/// frame's delay from the *output frame rate* and a bare `duration` is not
/// enough (`images_to_gif_service.dart` documents that measurement). The
/// difference is the muxer, not the concat demuxer -- do not port the GIF rule
/// here, and do not port this rule there.
///
/// **Prefer [imagesToVideoSegments] when a canvas is in play.** This builder
/// asks the `fps` filter to synthesise the frames between still images, and how
/// well that works is build-dependent: on the device (ffmpeg-kit, ffmpeg
/// n8.1.2) a 4-image / 4 s input reported `Duration: 00:00:04.00` yet encoded
/// only `frame=36 time=00:00:02.75`, while host ffmpeg 9.0.2 produced the full
/// 48 frames from identical arguments. Rendering each image to its own segment
/// first avoids the synthesis entirely.
///
/// **Keep `fps * secondsPerImage >= 1`, ideally >= 2.** Below 1 an image can
/// miss every output frame and vanish outright. Measured, 5 images:
///
///   D=0.3  F=2  (0.6) -> 3 frames, only red/blue/magenta survive
///   D=0.05 F=12 (0.6) -> 3 frames, only green/blue/magenta survive, and the
///                        total collapsed to 0.25 s instead of 1.5 s
///   D=0.3  F=12 (3.6) -> 18 frames, all five survive
///
/// Note the loss is position-dependent, not "the tail gets cut": at D=0.05 the
/// FIRST image disappeared. Duration can still look right while content is
/// missing, which is why the caller must clamp rather than trust the product.
List<String> imagesToVideo({
  required String concatListPath,
  required String outputPath,
  int fps = 12,
}) {
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    concatListPath,
    '-vf',
    'fps=$fps',
    ...h264Encode,
    '-movflags',
    '+faststart',
    outputPath,
  ];
}

/// Map the editor's JPEG quality knob (2/5/10, lower is better) onto WebP's
/// 0..100 scale, where higher is better.
int _webpQuality(int jpegQuality) =>
    (100 - (jpegQuality - 2) * 8).clamp(20, 100);

/// Join pre-encoded, already-uniform segments into the final mp4.
///
/// Used by Images to Video when a canvas is in play: the service renders each
/// image to its own `-t <seconds> -r <fps>` segment first, so this join is a
/// pure stream copy. Nothing is re-encoded, nothing is resampled, and the
/// output length is simply the sum of the segments.
///
/// This is the portable path. Asking the concat demuxer to expand still images
/// itself requires an `fps` filter to synthesise the in-between frames, and
/// that synthesis is build-dependent: on the device (ffmpeg-kit, ffmpeg
/// n8.1.2) a 4-image / 4 s input reported `Duration: 00:00:04.00` yet encoded
/// only `frame=36 time=00:00:02.75`, while host ffmpeg 9.0.2 produced the full
/// 48 frames from identical arguments. Pre-rendered segments sidestep it.
///
/// `+faststart` moves the moov atom to the front so the file streams and shares
/// without a full download first.
List<String> imagesToVideoSegments({
  required String concatListPath,
  required String outputPath,
  String? muxer,
}) {
  // faststart only exists for mp4/mov; WebM and MKV have no moov atom to move.
  final faststart = muxer == null || muxer == 'mp4' || muxer == 'mov';
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    concatListPath,
    '-c',
    'copy',
    if (faststart) ...['-movflags', '+faststart'],
    if (muxer != null) ...['-f', muxer],
    outputPath,
  ];
}

/// Filter chain that letterboxes one image onto a fixed canvas.
///
/// `decrease` scales the image DOWN to fit inside the canvas; `pad` then
/// centres it on that canvas. Nothing is upscaled (a small image keeps its
/// detail and simply sits in a larger frame) and nothing is cropped, which is
/// what makes mixed orientations safe to combine.
///
/// **`setsar=1` is required, and not for the reason it first appears.** Rounding
/// the canvas height to an even number rarely preserves the source ratio
/// (1080x608 is 1.7763:1 against 16:9's 1.7778:1), so ffmpeg would otherwise tag
/// the stream with a non-square sample aspect ratio such as 1216:1215. Forcing
/// square pixels is correct on its own merits -- the frame should not be
/// silently stretched to a different display aspect than its pixels imply.
///
/// It is NOT a fix for the device truncation. That was measured separately and
/// `setsar=1` did not change the frame count at all; per-image segments did.
/// Do not let this comment imply otherwise.
///
/// Lives here rather than in the service so tests exercise the same string the
/// encoder uses, instead of a copy that can drift.
String imagesToVideoLetterboxFilter(int width, int height) =>
    'scale=$width:$height:force_original_aspect_ratio=decrease,'
    'pad=$width:$height:(ow-iw)/2:(oh-ih)/2,'
    'setsar=1';

/// Build the command that renders one image into a fixed-rate video segment.
///
/// `-loop 1` holds the still on screen, `-t` bounds it, and `-r` fixes the
/// frame rate, so the segment contains exactly `seconds * fps` frames and
/// needs no resampling downstream.
///
/// This is what makes the mixed-orientation path portable. Letting the concat
/// demuxer expand stills itself requires an `fps` filter to synthesise the
/// in-between frames, and that synthesis is build-dependent: on the device
/// (ffmpeg-kit, ffmpeg n8.1.2) a 4-image / 4 s input reported
/// `Duration: 00:00:04.00` yet encoded only `frame=36 time=00:00:02.75`, while
/// host ffmpeg 9.0.2 produced all 48 frames from identical arguments.
List<String> imagesToVideoSegment({
  required String inputPath,
  required String outputPath,
  required (int, int) canvas,
  required double seconds,
  required int fps,
  List<String> encoderArgs = h264Encode,
}) {
  final (w, h) = canvas;
  // The segment's CONTAINER is inferred from [outputPath]; every caller keeps
  // segments in mp4 except WebM (VP9 does not belong in mp4).
  return [
    '-y',
    '-loop',
    '1',
    '-i',
    inputPath,
    '-t',
    seconds.toStringAsFixed(3),
    '-r',
    fps.toString(),
    '-vf',
    imagesToVideoLetterboxFilter(w, h),
    ...encoderArgs,
    outputPath,
  ];
}

/// Default target width for the Images to Video canvas.
///
/// Used when the caller has no width preference. 1080 keeps a 16:9 source at
/// roughly 1080x608 -- full HD class without upscaling most phone photos past
/// their native detail.
const int imagesToVideoDefaultWidth = 1080;

/// Round a canvas size to what `libx264 -pix_fmt yuv420p` can actually encode.
///
/// Both dimensions must be even: chroma subsampling halves them, and an odd
/// value either fails the encode or gets silently floored. Rounds DOWN so the
/// padded frame never exceeds what the caller asked for, and floors at 2
/// (a 0-width canvas would make `scale`/`pad` reject the graph).
///
/// Returns null for null input, so callers can pass a partially-known canvas
/// straight through and get the passthrough path.
int? imagesToVideoCanvas(int? value) {
  if (value == null) return null;
  final even = value - (value % 2);
  return even < 2 ? 2 : even;
}

/// Smallest number of output frames each still image must span.
///
/// Below 1 an image can miss every output frame and disappear from the video
/// entirely -- measured on host ffmpeg 9.0.2: five images at D=0.3 F=2 produced
/// 3 frames and only red/blue/magenta survived. The loss is not even "the tail
/// gets cut": at D=0.05 F=12 the FIRST image vanished. Worse, the total duration
/// can still come out looking correct while content is missing, so this has to
/// be prevented up front rather than detected afterwards.
const int imagesToVideoMinFramesPerImage = 2;

/// The frame rate to actually use, raised until each image spans at least
/// [imagesToVideoMinFramesPerImage] output frames.
///
/// Clamping here (rather than rejecting) keeps the UI honest: the user picks
/// "each image ~0.2 s" and gets a smooth stream instead of a video that quietly
/// dropped every other photo.
///
/// Lives in this file, not the service, so it is reachable from `dart test`:
/// the service imports `ffmpeg_kit_flutter_new`, which pulls in Flutter and
/// cannot be loaded by the plain Dart VM.
int imagesToVideoSettleFps({
  required double secondsPerImage,
  required int requestedFps,
}) {
  if (secondsPerImage <= 0) return requestedFps;
  final needed = (imagesToVideoMinFramesPerImage / secondsPerImage).ceil();
  return needed > requestedFps ? needed : requestedFps;
}

/// True when [fps] and [secondsPerImage] together keep every image on screen.
///
/// This is the POST-clamp assertion, not a UI predicate. [imagesToVideoSettleFps]
/// only ever raises the rate, so it can always satisfy this -- which means a
/// warning keyed on it would be dead code. Its real use is as a guard: after
/// settling the rate, assert the invariant still holds, so a future change to
/// either function fails loudly instead of shipping a video with missing
/// photos.
///
/// Compares against [imagesToVideoMinFramesPerImage], the same constant the
/// clamp targets. An earlier version hardcoded `1` here while the clamp aimed
/// at `2`, so the two could disagree about what "safe" meant.
bool imagesToVideoTimingIsSafe({
  required double secondsPerImage,
  required int fps,
}) =>
    secondsPerImage * fps >= imagesToVideoMinFramesPerImage;

/// Build Edit GIF speed change command (single pass).
///
///   `*PTS,split[a][b];[a]palettegen=reserve_transparent=on:transparency_color=
///
/// This is NOT the Video to GIF palette (`stats_mode=single`): the previous implementation's
/// Edit path keeps transparency with `reserve_transparent=on` instead.
///
/// Semantics measured on the 320x180 / 77 frames / 5.14 s host fixture:
///   `setpts=N*PTS` multiplies the timestamps, so N < 1 plays faster and
///   N > 1 plays slower. 2.0x keeps all 77 frames and doubles the duration
///   (each delay grows); 0.5x compresses the timeline and redundant frames
///   drop out (77 -> 40 frames, 5.14 s -> 2.67 s).
///
/// NO `-r` here. Measured with and without on the same fixture: `-r 12`
/// resamples a second time and silently drops 14 frames (77 -> 63, and the
/// duration drifts to 5.25 s); without it, frame count and duration are
/// preserved exactly at speed 1.0.
/// Encode a frames concat list as APNG instead of GIF.
///
/// APNG cannot ride the palette tail the GIF paths share: it is a true-colour
/// container, so quantising would only destroy the colours APNG exists to
/// keep. That also means an APNG output preserves alpha exactly, where GIF
/// gets 1-bit transparency.
///
/// Timing comes from the concat list's own `duration` directives; no `-r` and
/// no `fps=` filter are applied, because both resample a second time and were
/// measured to drop frames (the GIF path can afford that because it has just
/// extracted at the target rate; an edited/sourced list cannot).
///
/// [prefixFilter] is the caller's pre-stage (a scale for Images to GIF, a
/// dedup for Video to GIF) and runs before the frames are muxed.
List<String> apngFromFrames({
  required String concatListPath,
  required String outputPath,
  bool loop = true,
  String prefixFilter = '',
}) {
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    concatListPath,
    if (prefixFilter.isNotEmpty) ...['-filter_complex', prefixFilter],
    // `-plays 0` is an infinite loop; APNG's default is to play once.
    ...['-plays', loop ? '0' : '1'],
    '-f',
    'apng',
    outputPath,
  ];
}

List<String> editGifSpeed({
  required String inputPath,
  required String outputPath,
  required double speedMultiplier,
  bool loop = true,
  FormatSpec? format,
  double? start,
  double? end,
  String? crop,
  EncodePreset preset = EncodePreset.balanced,
}) {
  // Pre-stage stays unlabelled and glued onto split (see videoToGif for the
  // two broken forms the device rejected). Built as const concatenation --
  // runtime string surgery inside a `${...}` interpolation has upset the
  // kernel snapshotter before.
  final tail = preset.gifTransparentTail;
  final isApng = format?.id == 'apng';
  // A trimmed segment must start at zero: `trim` leaves the original
  // timestamps in place, so the speed stage works on PTS-STARTPTS instead.
  final trim = _trimFilter(start, end);
  final speed = trim.isEmpty
      ? 'setpts=$speedMultiplier*PTS'
      : 'setpts=$speedMultiplier*(PTS-STARTPTS)';
  final cropExpr = _cropExpr(crop);
  final chain = '$trim${cropExpr.isEmpty ? '' : '$cropExpr,'}$speed';
  final filter = isApng ? chain : '$chain,$tail';
  if (isApng) {
    return [
      '-y',
      '-i',
      inputPath,
      '-filter_complex',
      filter,
      ...['-plays', loop ? '0' : '1'],
      '-f',
      'apng',
      outputPath,
    ];
  }
  return [
    '-y',
    '-i',
    inputPath,
    '-filter_complex',
    filter,
    ...gifFlags,
    // Both tokens together: a conditional '-loop' element would leave a bare
    // '0' behind when loop is off, and ffmpeg would read it as the output
    // filename ("Unable to choose an output format for '0'").
    ...['-loop', loop ? '0' : '1'],
    '-f',
    'gif',
    outputPath,
  ];
}

/// Build Edit GIF reverse command (single pass, built-in `reverse` filter).
///
/// and the DB's `fileFrameIndexOrderMap` suggests the previous implementation re-orders
/// decoded frames in-app; there is no ffmpeg command string for this path, so
/// the shape follows the speed path. `reverse` buffers every decoded frame
/// and emits them back-to-front, which is the same decoded-frames semantics.
///
/// Measured on the 320x180/77-frame fixture: 77 frames / 5.14 s preserved,
/// delay sequence exact, first output frame == last source frame (PSNR 44.5
/// vs 9.9 against the first source frame).
///
/// An extract-to-PNG + reversed-concat pipeline was measured first and
/// rejected: the concat demuxer reads PNGs at a fixed 1/25 s timebase, which
/// cannot represent GIF centisecond delays -- 70/60 ms came out as 80/40 ms.
/// (Host ffmpeg 9.0.2 concat offers no timebase option; `duration` lines are
/// quantized on arrival.) `reverse` keeps the timestamps it is given, so
/// uniformly-paced inputs -- anything this app produces, and most animated
/// GIFs -- come out exact. Inputs with wildly varying per-frame delays keep
/// frame count, content order and total duration, but the filter re-stamps
/// the pacing between frames; a purely byte-level block reversal would avoid
/// that yet corrupt partial-frame (delta-encoded) GIFs, so it is not an
/// option either.
///
/// [speedMultiplier] != 1.0 composes AFTER the reverse: reversal restores the
/// original per-frame delays, then setpts scales them all.
/// Like [editGifSpeed], no `-r` (it would resample and drop frames).
List<String> editGifReverse({
  required String inputPath,
  required String outputPath,
  double speedMultiplier = 1.0,
  bool loop = true,
  FormatSpec? format,
  double? start,
  double? end,
  String? crop,
  EncodePreset preset = EncodePreset.balanced,
}) {
  final trim = _trimExpr(start, end);
  final pre = <String>[
    // Trim first, so `reverse` only buffers the kept segment, then crop so the
    // reversed buffer holds the smaller frame.
    if (trim.isNotEmpty) trim,
    if (_cropExpr(crop).isNotEmpty) _cropExpr(crop),
    'reverse',
    if (speedMultiplier != 1.0)
      trim.isEmpty
          ? 'setpts=$speedMultiplier*PTS'
          : 'setpts=$speedMultiplier*(PTS-STARTPTS)',
  ];
  final isApng = format?.id == 'apng';
  final filter =
      isApng ? pre.join(',') : '${pre.join(',')},$transparentPaletteFilter';
  if (isApng) {
    return [
      '-y',
      '-i',
      inputPath,
      '-filter_complex',
      filter,
      ...['-plays', loop ? '0' : '1'],
      '-f',
      'apng',
      outputPath,
    ];
  }
  return [
    '-y',
    '-i',
    inputPath,
    '-filter_complex',
    filter,
    ...gifFlags,
    // Both tokens together: a conditional '-loop' element would leave a bare
    // '0' behind when loop is off, and ffmpeg would read it as the output
    // filename ("Unable to choose an output format for '0'").
    ...['-loop', loop ? '0' : '1'],
    '-f',
    'gif',
    outputPath,
  ];
}

/// Edit Image parameter bundles. Field values are UI slider units; every
/// neutral value makes its filter stage disappear entirely, so a user who
/// only touched brightness gets exactly `eq=brightness=...` -- never a
/// malformed `eq=:,hue=h=` chain.
class EditImageAdjust {
  /// -100..100, neutral 0 -> `eq=brightness=offset/100` (0 is neutral).
  final double brightness;

  /// -100..100, neutral 0 -> `eq=contrast=1.0 + offset/100`.
  /// The eq contrast neutral is 1.0, NOT 0 -- feeding the raw offset turns a
  /// mid-slider image into washed-out mush.
  final double contrast;

  /// 0..200, neutral 100 -> `eq=saturation=v/100`.
  final double saturation;

  /// -180..180 degrees, neutral 0 -> `hue=h=deg`.
  final double hue;

  /// 0..300, neutral 0 -> `unsharp=5:5:amount/100:5:5:0`. Positive sharpens.
  final double sharpen;

  /// 0..30, neutral 0 -> `gblur=sigma=v:steps=3`.
  final double blur;

  /// -100..100, neutral 0 -> `eq=gamma_r=1+t/200:gamma_g=1:gamma_b=1-t/200`.
  /// Positive is warm (R up, B down).
  final double temperature;

  /// -30..30 each, neutral 0. Guide template `colorbalance=rs=…:gm=…:bh=…`:
  /// the three sliders drive red-shadow / green-midtone / blue-highlight.
  final double shadows;
  final double midtones;
  final double highlights;

  const EditImageAdjust({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 100,
    this.hue = 0,
    this.sharpen = 0,
    this.blur = 0,
    this.temperature = 0,
    this.shadows = 0,
    this.midtones = 0,
    this.highlights = 0,
  });

  bool get isNeutral =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 100 &&
      hue == 0 &&
      sharpen == 0 &&
      blur == 0 &&
      temperature == 0 &&
      shadows == 0 &&
      midtones == 0 &&
      highlights == 0;
}

class EditImageCropRect {
  /// Top-left corner and size in source pixels (crop filter order w:h:x:y).
  final int x;
  final int y;
  final int width;
  final int height;

  const EditImageCropRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// Pure-geometry edit state. [quarterTurns] counts CLOCKWISE 90-degree steps
/// (1 = 90°, 2 = 180°, 3 = 270°).
class EditImageGeometry {
  final int quarterTurns;
  final bool flipH;
  final bool flipV;

  /// Target width in pixels; height follows with an even `-2`.
  final int? scaleWidth;
  final EditImageCropRect? crop;

  const EditImageGeometry({
    this.quarterTurns = 0,
    this.flipH = false,
    this.flipV = false,
    this.scaleWidth,
    this.crop,
  });

  bool get isNeutral =>
      quarterTurns == 0 &&
      !flipH &&
      !flipV &&
      scaleWidth == null &&
      crop == null;
}

/// Fixed-point text for filter parameters: `1.0 + (-70)/100` is
/// 0.30000000000000004 in IEEE-754 and would leak straight into the filter
/// string. Round to 3 decimals and strip trailing zeros.
String _editImageNum(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Build Edit Image command: single-pass `-vf` chain, ordered
/// geometry -> color -> detail (order changes the result: e.g. sharpening a
/// scaled-down image hits different pixels than sharpening first).
///
/// Every stage below was measured on host ffmpeg 9.0.2 AND its output md5
/// matches the golden set (12/12 replicated with exactly this argv shape:
/// plain `-vf`, default output options, output path last):
///
/// - 90° steps use `transpose=dir=clock|cclock` -- names, not the deprecated
///   numeric form. NEVER `rotate=`: vf_rotate defaults ow/oh to iw/ih, so a
///   "90°" stays 640x480 with the corners cut off, while transpose really
///   swaps the dimensions to 480x640. 180° is `hflip,vflip`.
/// - Flips use the dedicated `hflip`/`vflip`, not transpose combinations.
/// - `crop=w:h:x:y`; `scale=W:-2:flags=lanczos` (-2 keeps dimensions even so
///   planar conversions never hit odd-dimension errors).
/// - eq/hue for color: brightness 0-neutral, contrast 1.0-neutral,
///   saturation 1.0-neutral; only the touched options are emitted.
/// - `unsharp=5:5:A:5:5:0`: the matrix size MUST be odd (12:12 and 4:4 are
///   rejected with "Invalid even size"), so it is fixed at 5:5 and only the
///   amount is exposed. `gblur=sigma=S:steps=3` for blur.
///
/// Output: `jpg` adds `-q:v <jpegQuality>` -- the mjpeg quality scale runs
/// 2 (best) .. 31 (worst), the opposite intuition of CRF; measured on the
/// same source: png 31.7 KB / q:v 2 43.4 KB / q:v 5 30.8 KB. `png` adds
/// nothing: the png encoder picks rgba automatically when the input has
/// alpha, and forcing `-pix_fmt rgba` would change the bytes (and md5) of
/// every opaque-image output for no benefit.
///
/// With everything neutral the command carries no `-vf` at all (a plain
/// re-encode into the requested container; `-c copy` cannot convert formats
/// and is not what "save as JPEG" means).
List<String> editImageTransform({
  required String inputPath,
  required String outputPath,
  EditImageGeometry geometry = const EditImageGeometry(),
  EditImageAdjust adjust = const EditImageAdjust(),
  String preset = 'none',
  int presetStrength = 100,
  String format = 'jpg',
  int jpegQuality = 2,
}) {
  final chain = editImageFilterChain(
    geometry: geometry,
    adjust: adjust,
    preset: preset,
    presetStrength: presetStrength,
  );

  final args = <String>['-y', '-i', inputPath];
  if (chain.isNotEmpty) {
    args
      ..add('-vf')
      ..add(chain);
  }
  if (format == 'webp') {
    args.addAll(
        ['-c:v', 'libwebp', '-quality', '${_webpQuality(jpegQuality)}']);
  } else if (format != 'png') {
    args
      ..add('-q:v')
      ..add('$jpegQuality');
  }
  return args..add(outputPath);
}

/// The `-vf` chain for one edit state: geometry -> color -> detail, in that
/// order because it changes the result (sharpening a scaled-down image hits
/// different pixels than sharpening first).
///
/// Extracted so [editImageTransform] and [editImageTransformWithPreview] emit
/// exactly the same chain -- the ordering above is measured against the golden
/// set, and two copies would eventually drift.
///
/// Returns an empty string when every stage is neutral: the caller then emits
/// no filter at all (a plain re-encode into the requested container), because
/// `-c copy` cannot convert formats and is not what "save as JPEG" means.
String editImageFilterChain({
  EditImageGeometry geometry = const EditImageGeometry(),
  EditImageAdjust adjust = const EditImageAdjust(),
  String preset = 'none',
  int presetStrength = 100,
}) {
  final f = <String>[
    if (geometry.crop != null)
      'crop=${geometry.crop!.width}:${geometry.crop!.height}:'
          '${geometry.crop!.x}:${geometry.crop!.y}',
    if (geometry.quarterTurns == 1) 'transpose=dir=clock',
    if (geometry.quarterTurns == 3) 'transpose=dir=cclock',
    if (geometry.quarterTurns == 2) ...['hflip', 'vflip'],
    if (geometry.flipH) 'hflip',
    if (geometry.flipV) 'vflip',
    if (geometry.scaleWidth != null)
      'scale=${geometry.scaleWidth!.toInt()}:-2:flags=lanczos',
  ];

  final eq = <String>[
    if (adjust.brightness != 0)
      'brightness=${_editImageNum(adjust.brightness / 100)}',
    if (adjust.contrast != 0)
      'contrast=${_editImageNum(1 + adjust.contrast / 100)}',
    if (adjust.saturation != 100)
      'saturation=${_editImageNum(adjust.saturation / 100)}',
    // Temperature rides the same eq filter: gamma per channel, G pinned to 1.
    if (adjust.temperature != 0) ...[
      'gamma_r=${_editImageNum(1 + adjust.temperature / 200)}',
      'gamma_g=1',
      'gamma_b=${_editImageNum(1 - adjust.temperature / 200)}',
    ],
  ];
  if (eq.isNotEmpty) f.add('eq=${eq.join(':')}');
  if (adjust.hue != 0) f.add('hue=h=${_editImageNum(adjust.hue)}');
  f.addAll(editImagePresetFilters(preset, presetStrength));
  final cb = <String>[
    if (adjust.shadows != 0) 'rs=${_editImageNum(adjust.shadows / 100)}',
    if (adjust.midtones != 0) 'gm=${_editImageNum(adjust.midtones / 100)}',
    if (adjust.highlights != 0) 'bh=${_editImageNum(adjust.highlights / 100)}',
  ];
  if (cb.isNotEmpty) f.add('colorbalance=${cb.join(':')}');
  if (adjust.sharpen != 0) {
    f.add('unsharp=5:5:${_editImageNum(adjust.sharpen / 100)}:5:5:0');
  }
  if (adjust.blur != 0) {
    f.add('gblur=sigma=${_editImageNum(adjust.blur)}:steps=3');
  }

  return f.join(',');
}

/// Style-preset filter strings, inserted into the chain right after the
/// manual hue segment. [strength] 0..100 scales every parameter toward its
/// neutral (0 = no-op, so the strength slider doubles as an off switch);
/// each mapping below is verified against a host-ffmpeg golden.
///
/// Intensity is parameter scaling rather than a blend with the previous implementation:
/// true opacity blending needs `blend`, which requires a split/overlay
/// filter_complex, not the linear `-vf` chain this builder emits.
List<String> editImagePresetFilters(String preset, int strength) {
  if (preset == 'none' || strength <= 0) return const [];
  final f = strength / 100;
  switch (preset) {
    case 'bw': // 黑白
      return ['eq=saturation=${_editImageNum(1 - f)}'];
    case 'vintage': // 复古: identity-mixed sepia matrix
      String m(String k, double target, bool diag) =>
          '$k=${_editImageNum(diag ? 1 + f * (target - 1) : f * target)}';
      return [
        'colorchannelmixer='
            '${m('rr', 0.393, true)}:${m('rg', 0.769, false)}:'
            '${m('rb', 0.189, false)}:${m('gr', 0.349, false)}:'
            '${m('gg', 0.686, true)}:${m('gb', 0.168, false)}:'
            '${m('br', 0.272, false)}:${m('bg', 0.534, false)}:'
            '${m('bb', 0.131, true)}',
      ];
    case 'cool': // 冷调
      return [
        'eq=gamma_r=${_editImageNum(1 - 0.15 * f)}:'
            'gamma_g=1:gamma_b=${_editImageNum(1 + 0.15 * f)}',
      ];
    case 'warm': // 暖调
      return [
        'eq=gamma_r=${_editImageNum(1 + 0.15 * f)}:'
            'gamma_g=1:gamma_b=${_editImageNum(1 - 0.15 * f)}',
      ];
    case 'contrast': // 高对比
      return ['eq=contrast=${_editImageNum(1 + 0.4 * f)}'];
    case 'lowsat': // 低饱和
      return ['eq=saturation=${_editImageNum(1 - 0.4 * f)}'];
    case 'cine': // 电影感: slightly crushed + teal-shifted balance
      return [
        'eq=contrast=${_editImageNum(1 + 0.2 * f)}:'
            'saturation=${_editImageNum(1 - 0.25 * f)}',
        'colorbalance=rs=${_editImageNum(0.08 * f)}:'
            'bs=${_editImageNum(-0.08 * f)}',
      ];
    case 'soft': // 柔光: negative unsharp amount softens instead of sharpening
      return ['unsharp=5:5:${_editImageNum(-0.8 * f)}:5:5:0'];
    default:
      return const [];
  }
}

/// Low-resolution working copy for the Edit Image editor: all real filter
/// work runs on the previous implementation file, the editor only ever DISPLAYS this
/// 1080-wide JPEG (and must decode it with cacheWidth -- a 1080px image on a
/// 3x screen decodes to 3240px / ~42 MB otherwise).
List<String> editImagePreview({
  required String inputPath,
  required String outputPath,
}) {
  return [
    '-y',
    '-i',
    inputPath,
    '-vf',
    'scale=1080:-2:flags=lanczos',
    '-q:v',
    '4',
    outputPath,
  ];
}

/// [editImageTransform] plus the 1080-wide display copy, in ONE ffmpeg pass.
///
/// The naive flow decodes and filters the source twice per apply: once for the
/// full-size output, then again from that output to build the preview. On a
/// 4032x3024 photo the second decode alone dominated the apply step, so this
/// variant splits the filtered stream instead (`split` -> two scaled encodes)
/// and pays for the source decode once.
///
/// Why `filter_complex` and not two `-vf` outputs: `-vf` applies to exactly one
/// output; a second output would re-read and re-filter the input. `split`
/// forks the already-filtered frames, which is the whole point.
///
/// `[vout]` keeps the full-resolution filtered stream; `[vprev]` appends the
/// same `scale=1080:-2:flags=lanczos` the standalone preview uses, so the
/// display copy is byte-identical in intent to [editImagePreview]'s.
///
/// Returns the argv; the caller runs it once and gets both files.
List<String> editImageTransformWithPreview({
  required String inputPath,
  required String outputPath,
  required String previewPath,
  EditImageGeometry geometry = const EditImageGeometry(),
  EditImageAdjust adjust = const EditImageAdjust(),
  String preset = 'none',
  int presetStrength = 100,
  String format = 'jpg',
  int jpegQuality = 2,
}) {
  final chain = editImageFilterChain(
    geometry: geometry,
    adjust: adjust,
    preset: preset,
    presetStrength: presetStrength,
  );

  final filter = '${chain.isEmpty ? 'null' : chain},'
      'split=2[vout][vpre];'
      '[vpre]scale=1080:-2:flags=lanczos[vprev]';

  return [
    '-y',
    '-i',
    inputPath,
    '-filter_complex',
    filter,
    // Full-size result. The quality knob belongs to this output only.
    '-map',
    '[vout]',
    if (format == 'webp') ...[
      '-c:v',
      'libwebp',
      '-quality',
      '${_webpQuality(jpegQuality)}',
    ] else if (format != 'png') ...[
      '-q:v',
      '$jpegQuality'
    ],
    outputPath,
    // Display copy, pinned to the preview builder's own quality.
    '-map',
    '[vprev]',
    '-q:v',
    '4',
    previewPath,
  ];
}

/// GPU-preview stand-in for a style preset, as a 4x5 color matrix in Flutter's
/// 0..255 space (rows of [r g b scaleX translate] plus the alpha row).
///
/// Returns null when the preset has no reasonable matrix equivalent, which is
/// the caller's signal to keep showing the unfiltered preview:
///
///  - `soft` is a negative `unsharp` amount. Sharpening is a convolution and
///    `ColorFilter.matrix` is affine, so there is nothing to approximate it
///    with; faking it with a blur would overshoot the actual radius.
///  - `cine` additionally carries a `colorbalance` term, which is a
///    per-luminance-band split that a single global matrix cannot express.
///    Its eq half is still shown, so the user sees the contrast/saturation
///    shift rather than nothing.
///
/// The `eq`-based presets (`bw`, `contrast`, `lowsat`) map exactly, because
/// `eq` saturates by mixing toward luma with the same sRGB coefficients this
/// matrix uses. `vintage` is a literal `colorchannelmixer` matrix and is
/// reproduced term for term. `cool`/`warm` are per-channel gamma in ffmpeg --
/// non-linear, so the diagonal gain below is an approximation, tuned to land
/// close over the mid-tones rather than exactly.
///
/// [strength] is 0..100 and scales each parameter toward its neutral value,
/// matching [editImagePresetFilters].
List<double>? editImagePresetPreviewMatrix(String preset, int strength) {
  if (preset == 'none' || strength <= 0) return null;
  final f = strength / 100.0;

  List<double> identity() => <double>[
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
      ];

  // Scale the 3x3 block in place; the alpha row stays untouched.
  void scale3(List<double> m, double s) {
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        m[i * 5 + j] *= s;
      }
    }
  }

  void mix3(List<double> m, List<double> target, double t) {
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        final idx = i * 5 + j;
        m[idx] = m[idx] + (target[i * 5 + j] - m[idx]) * t;
      }
    }
  }

  /// `eq=saturation=v`: mix toward Rec.709 luma.
  ///
  /// The luma coefficient is selected by the INPUT channel (matrix column),
  /// not the output one, so every row comes out as [lr, lg, lb] -- which is
  /// what makes R'=G'=B' at v=0. Getting this backwards yields rows of
  /// [lr,lr,lr], which collapses each channel onto its own gain instead of
  /// onto the luma (and no longer preserves brightness at all).
  List<double> saturationMatrix(double v) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    const luma = [lr, lg, lb];
    final m = identity();
    scale3(m, v);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        m[i * 5 + j] += (1 - v) * luma[j];
      }
    }
    return m;
  }

  switch (preset) {
    case 'bw':
      return saturationMatrix(1 - f);
    case 'lowsat':
      return saturationMatrix(1 - 0.4 * f);
    case 'contrast':
      // eq contrast pivots around mid-grey: v' = v*c + 128*(1-c).
      final c = 1 + 0.4 * f;
      final m = identity();
      scale3(m, c);
      final t = 128 * (1 - c);
      m[4] = t;
      m[9] = t;
      m[14] = t;
      return m;
    case 'vintage':
      // The same nine coefficients editImagePresetFilters emits, laid out as
      // a 4x5 (rows of [r g b alpha translate]). Row-major R/G/B order matches
      // the colorchannelmixer argument order rr:rg:rb:gr:gg:gb:br:bg:bb.
      final m = identity();
      const target = <double>[
        0.393, 0.769, 0.189, 0, 0, //
        0.349, 0.686, 0.168, 0, 0,
        0.272, 0.534, 0.131, 0, 0,
        0, 0, 0, 1, 0,
      ];
      mix3(m, target, f);
      return m;
    case 'cool':
    case 'warm':
      // ffmpeg applies per-channel gamma; a diagonal gain is the closest
      // affine stand-in (same choice the temperature slider already makes).
      // Only the diagonal entries may move: R lives at index 0, B at 12.
      final d = preset == 'cool' ? -0.15 * f : 0.15 * f;
      final m = identity();
      m[0] = 1 + d;
      m[12] = 1 - d;
      return m;
    case 'cine':
      // eq half only; the colorbalance half has no matrix equivalent.
      final m = saturationMatrix(1 - 0.25 * f);
      final c = 1 + 0.2 * f;
      scale3(m, c);
      final t = 128 * (1 - c);
      m[4] = t;
      m[9] = t;
      m[14] = t;
      return m;
    default:
      return null;
  }
}

class FFmpegException implements Exception {
  final String message;
  final String? output;
  FFmpegException(this.message, [this.output]);
  @override
  String toString() =>
      'FFmpegException: $message${output != null ? "\n$output" : ""}';
}

/// How hard the compressor should work to hit a target byte count.
///
/// ffmpeg's mjpeg encoder has no "target size" mode and no CRF/bitrate knob
/// that maps to a size, so the size is reached by searching the quality scale:
/// `-q:v` runs 2 (best) .. 31 (worst). Measured on the 640x480 testsrc2
/// fixture: q=2 -> 42.9 KB, q=5 -> 29.9 KB, q=10 -> 21.3 KB, q=15 -> 16.9 KB,
/// q=20 -> 14.4 KB, q=28 -> 12.0 KB.
enum ImageCompressionMode {
  /// Keep the pixels, re-encode only. Smallest quality loss.
  qualityOnly,

  /// Allow downscaling when quality alone cannot reach the target.
  /// Usually the only way to hit an aggressive target on a large photo.
  qualityThenScale,

  /// Never scale; take the worst quality that fits.
  qualityFloor,
}

class ImageCompressionPlan {
  const ImageCompressionPlan({
    required this.targetBytes,
    required this.quality,
    required this.maxWidth,
    this.mode = ImageCompressionMode.qualityThenScale,
  });

  /// 0 = no explicit target, just encode at [quality].
  final int targetBytes;

  /// Starting `-q:v` value (2 = best).
  final int quality;

  /// Floor for downscaling when [mode] allows it.
  final int? maxWidth;

  final ImageCompressionMode mode;

  bool get hasTarget => targetBytes > 0;
}

/// Whether [mode] permits dropping pixels when quality alone cannot reach the
/// target. The service consults this instead of comparing enum values inline,
/// so the rule stays testable off-device.
bool compressionAllowsScaling(ImageCompressionMode mode) =>
    mode == ImageCompressionMode.qualityThenScale;

/// Whether the Edit Image apply button still has pending work: the chosen
/// target differs from what the current image has already been compressed to.
///
/// [appliedTarget] is null when nothing has been applied to the current image
/// yet. A target of 0 ("不压缩") is never pending -- there is no compression
/// intent left to realise -- so switching back to it must be able to disarm
/// the button rather than leave a live "apply" that does nothing. 0 is also a
/// real target, which is why it cannot double as the "nothing applied" marker;
/// that is what the nullability is for.
bool compressionTargetPending(int target, int? appliedTarget) {
  if (target == 0) return false;
  return target != appliedTarget;
}

/// What one compression run settled on, and how hard it had to work to get
/// there. Produced by `EditImageService.compress`, kept here so the ladder
/// search stays unit-testable without an ffmpeg runtime.
class ImageCompressionResult {
  const ImageCompressionResult({
    required this.path,
    required this.bytes,
    required this.quality,
    required this.width,
  });

  /// Absolute path of the kept file.
  final String path;

  final int bytes;

  /// `-q:v` the accepted file was encoded at.
  final int quality;

  /// Output width the accepted file was scaled to; null = source width.
  final int? width;

  bool fits(int targetBytes) => bytes <= targetBytes;
}

/// One width's worth of a compression search.
///
/// A phase is tried in two steps: [probeQuality] first (the WORST rung), and
/// only if that fits does the service walk [walkQuality] from best to worst.
/// See [compressionSearchPhases] for why the probe exists.
class CompressionPhase {
  const CompressionPhase({
    required this.width,
    required this.probeQuality,
    required this.walkQuality,
  });

  /// Already clamped to an even width, or null to keep the source resolution.
  final int? width;

  /// The worst (largest) `-q:v` rung. Encoding this first tells us whether
  /// ANY quality at this width can meet the target.
  final int probeQuality;

  /// The remaining rungs, best (smallest q) first. The probe is excluded
  /// because it has already been encoded and measured.
  final List<int> walkQuality;

  /// Total encodes this phase can cost.
  int get maxEncodes => 1 + walkQuality.length;
}

/// The ordered phases of a compression search.
///
/// **Why the worst-quality probe comes first.** `-q:v` on mjpeg is monotonic
/// in output size, so if even the worst rung overshoots the target, no rung at
/// that width can hit it and the rest of the ladder is pure waste. Skipping
/// straight to the next width is what stops the descent from being starved:
/// measured on a 1920x1080 testsrc2 with a 20 KB target, walking quality to
/// exhaustion at each width costs **68 attempts** before it ever narrows,
/// while probing first costs **13**. With the old linear walk and an iteration
/// budget of 12, an aggressive target spent the entire budget on quality rungs
/// at the source width and reported "已压到质量/尺寸下限" even though 960 px
/// would have fit comfortably.
///
/// The probe also preserves the fast common case: a target the source width
/// already meets still costs one probe plus a short walk, not a full sweep.
///
/// [sourceWidth] is the un-scaled pixel width of the input. It matters only
/// when [startWidth] is null ("输出宽度: 原始"), because that is the case where
/// the caller has no width cap of its own and the source resolution is the
/// real starting point. Passing it is what lets an aggressive target actually
/// narrow the image instead of walking quality to the floor and giving up --
/// see [imageCompressionWidthSearchOrder].
List<CompressionPhase> compressionSearchPhases({
  required int startQuality,
  required int? startWidth,
  required bool allowScale,
  int? sourceWidth,
}) {
  final qualityOrder = imageCompressionSearchOrder(startQuality);
  // No explicit cap: the source width IS the cap, so the ladder descends from
  // it. Without this the width search was empty and "允许缩小尺寸" did nothing
  // whenever the output-width chip stayed on 原始.
  final effective = startWidth ?? sourceWidth;
  final clampedStart = imageCompressionClampWidth(effective);
  final widths = <int?>[
    // The first phase always encodes at the caller's own width: null means
    // "full size", which is right even when we know the source width.
    imageCompressionClampWidth(startWidth),
    if (allowScale && clampedStart != null)
      ...imageCompressionWidthSearchOrder(clampedStart),
  ];
  return [
    for (final w in widths)
      CompressionPhase(
        width: w,
        probeQuality: qualityOrder.last,
        walkQuality: qualityOrder.sublist(0, qualityOrder.length - 1),
      ),
  ];
}

/// Total encodes [compressionSearchPhases] can cost in the worst case.
///
/// Used to size the iteration budget: a cap below this would silently
/// truncate the search and report a worse result than was achievable.
int compressionWorstCaseEncodes(List<CompressionPhase> phases) =>
    phases.fold(0, (sum, p) => sum + p.maxEncodes);

/// The quality ladder walked while hunting for a target size.
///
/// Deliberately coarse at the top (where quality costs the most bytes) and
/// finer at the bottom, because that is where the last few KB are cheapest to
/// give up without wrecking the image. 31 is ffmpeg's mjpeg worst case.
const List<int> imageCompressionQualityLadder = <int>[
  2,
  4,
  6,
  8,
  10,
  12,
  14,
  16,
  18,
  20,
  22,
  24,
  26,
  28,
  31,
];

/// Width ladder used when [ImageCompressionMode.qualityThenScale] bottoms out
/// on quality and still misses the target. Keeps the long edge proportional
/// so aspect ratio survives.
const List<int> imageCompressionWidthLadder = <int>[
  2560,
  2048,
  1600,
  1280,
  1080,
  960,
  800,
  640,
  480,
  320,
];

/// Nearest ladder entry at or below [quality] (i.e. the best quality that is
/// not finer than what the caller asked for). Returns null when [quality] is
/// already better than the ladder's best entry, which the search treats as
/// "start at the top".
int? imageCompressionQualityCeiling(int quality) {
  int? best;
  for (final q in imageCompressionQualityLadder) {
    if (q <= quality) {
      if (best == null || q > best) best = q;
    }
  }
  return best;
}

/// Quality search order for a compression run: the ladder from [startQuality]
/// toward worse quality, never finer than the start.
///
/// Ascending in `-q:v`, because mjpeg output size is monotonic in q (bigger q,
/// smaller file): walking this list and stopping at the first entry that fits
/// yields the BEST quality that still meets the target, in a single pass.
List<int> imageCompressionSearchOrder(int startQuality) {
  final start = imageCompressionQualityCeiling(startQuality) ??
      imageCompressionQualityLadder.first;
  return imageCompressionQualityLadder
      .where((q) => q >= start)
      .toList(growable: false);
}

/// Width downgrade order for [ImageCompressionMode.qualityThenScale]: every
/// ladder entry strictly narrower than [startWidth], widest first.
///
/// The start width is clamped first (odd widths round down, anything at or
/// below the bottom rung floors there), so the walk never re-encodes at the
/// same effective size it just tried.
///
/// Null (no width cap) means "the source resolution is already the floor",
/// so nothing is downgraded.
List<int> imageCompressionWidthSearchOrder(int? startWidth) {
  final start = imageCompressionClampWidth(startWidth);
  if (start == null) return const <int>[];
  return imageCompressionWidthLadder
      .where((w) => w < start)
      .toList(growable: false);
}

/// The width rungs [compressionProbePlan] should try, best-first.
///
/// Separate from the phases so the *order* is unit-testable: the rungs come out
/// widest-first (index ascending = width descending = file size descending), so
/// a fitting rung is always at a HIGHER index than an overshooting one. Getting
/// that backwards silently returns the widest, oversized rung.
List<int> compressionWidthRungs(List<CompressionPhase> phases) =>
    phases.length > 1
        ? phases.sublist(1).map((p) => p.width).whereType<int>().toList()
        : const <int>[];

/// Index into [rungs] of the widest rung that fits, or null when none do.
///
/// [fitsAt] is an async predicate answering "does rung i fit the target?", and
/// is expected to be monotonic: once a rung fits, every narrower (higher-index)
/// rung fits too. That is what makes a bisection valid here.
///
/// `overshoot`/`fits` are the two boundary indices, and the invariant is
/// `fits > overshoot` at all times:
///   - `overshoot` starts at -1 (nothing known to overshoot) and only ever
///     holds an index measured NOT to fit;
///   - `fits` starts at rungs.length (nothing known to fit) and only ever
///     holds an index measured TO fit.
/// A null answer from [fitsAt] means "stop asking" (budget spent); the best
/// confirmed fitting index seen so far is returned instead.
Future<int?> compressionWidestFittingRung({
  required List<int> rungs,
  required Future<bool?> Function(int index) fitsAt,
}) async {
  var overshoot = -1; // known NOT to fit; rungs[overshoot] is wider
  var fits = rungs.length; // known TO fit; rungs[fits] is narrower
  int? best;
  while (fits - overshoot > 1) {
    final mid = (overshoot + fits) ~/ 2;
    final ok = await fitsAt(mid);
    if (ok == null) break; // budget spent: keep the best confirmed so far
    if (ok) {
      fits = mid;
      best = mid;
    } else {
      overshoot = mid;
    }
  }
  return best;
}

/// Clamp a caller-supplied output width to something [imageCompress] and the
/// ladder agree on: even, positive, and not finer than the last rung.
int? imageCompressionClampWidth(int? width) {
  if (width == null) return null;
  final w = width <= 0 ? 1 : width;
  final last = imageCompressionWidthLadder.last;
  if (w <= last) return last;
  return w % 2 == 0 ? w : w - 1;
}
