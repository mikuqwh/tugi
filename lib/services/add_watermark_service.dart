// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - Add Watermark service.
///
/// Four things happen here that the pure command builders cannot do:
///
/// 1. **The fonts are put on disk.** `drawtext` needs `fontfile=` to point
///    at a real file. A Flutter asset lives inside the APK and is read
///    through the asset manager, not the filesystem, so freetype cannot
///    open it. Each bundled font is copied out to the app's own directory
///    on first use and reused afterwards.
/// 2. **The text is put on disk.** The watermark text travels to ffmpeg
///    through a `textfile=`, never inline -- see
///    [ffmpeg.drawtextWatermarkFilter] for why.
/// 3. **The media kind is detected.** The previous implementation has three separate
///    and the output shape differs for each: a GIF needs the palette
///    split, an image is a single frame, a video needs H.264.
/// 4. **A video source's first frame is extracted.** Flutter can display a
///    GIF or a still image straight from the file, but a video needs a
///    decoder the preview has no business owning.
// SPDX-License-Identifier: GPL-3.0-or-later

library add_watermark_service;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:format_core/format_core.dart';

import '../ffmpeg/commands.dart' as ffmpeg;
import '../utils/gif_reader.dart' as gr;
import '../utils/image_reader.dart' as ir;
import '../utils/media_kind.dart' as mk;
import '../utils/watermark_fonts.dart';

class AddWatermarkException implements Exception {
  AddWatermarkException(this.message, [this.details]);
  final String message;
  final String? details;
  @override
  String toString() => 'AddWatermarkException: $message'
      '${details != null ? '\n$details' : ''}';
}

/// One watermark layer, as the screen describes it.
///
/// Text layers carry [text]/[font]/[fontSize]/[fontColor]; image and GIF
/// layers carry [mediaPath]/[width]. The unused fields stay null rather than
/// being split into three classes, because the screen edits one list of them.
class WatermarkLayerRequest {
  const WatermarkLayerRequest({
    required this.kind,
    required this.placement,
    this.opacity = 1.0,
    this.text,
    this.font,
    this.fontSize = 24,
    this.fontColor = 'white',
    this.mediaPath,
    this.width,
  });

  final ffmpeg.WatermarkLayerKind kind;
  final ffmpeg.WatermarkPlacement placement;
  final double opacity;
  final String? text;
  final WatermarkFont? font;
  final int fontSize;
  final String fontColor;
  final String? mediaPath;
  final int? width;
}

/// The bundled watermark font, as an asset.
///
/// The previous implementation lets the user import their own font
///
/// This clone ships one instead: a 2.4 MB subset of Noto Sans SC (GB2312
/// hanzi + Latin), produced by `tool/build_watermark_font.py`. Shipping a
/// font means the feature works on first launch instead of dead-ending on
/// an import dialog, and a CJK subset matters because the UI is Chinese.
const String watermarkFontAsset = 'assets/fonts/NotoSansSC-Regular.ttf';

/// The file name the font is copied to inside the work directory.
const String watermarkFontFileName = 'watermark_font.ttf';

class AddWatermarkService {
  AddWatermarkService({required this.workDir});

  final String workDir;

  /// The on-disk font files, keyed by font id, so a session that switches
  /// between fonts copies each one at most once.
  final Map<String, String> _fontPaths = {};

  /// The absolute path of the on-disk copy of [font], copying it out of the
  /// APK on first use.
  ///
  /// Cached in [workDir]: the copies are 2.5-3.5 MB each and the app
  /// re-enters this screen often, so re-copying every time would be
  /// wasteful. The file is verified by size before it is trusted -- a
  /// truncated copy from a killed process would otherwise produce a
  /// confusing "cannot find a valid font" from ffmpeg much later.
  Future<String> ensureFontFile(WatermarkFont font) async {
    final cached = _fontPaths[font.id];
    if (cached != null && File(cached).existsSync()) return cached;

    await Directory(workDir).create(recursive: true);
    final target = '$workDir/${font.fileName}';
    final targetFile = File(target);

    Uint8List bytes;
    try {
      final data = await rootBundle.load(font.assetPath);
      bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    } catch (e) {
      throw AddWatermarkException('读取内置字体失败: $e');
    }

    if (bytes.length < 1024) {
      throw AddWatermarkException('内置字体数据异常（${bytes.length} 字节）');
    }
    // A cached file of the right size is reused; anything else is rewritten.
    if (!targetFile.existsSync() || targetFile.lengthSync() != bytes.length) {
      await targetFile.writeAsBytes(bytes, flush: true);
    }
    _fontPaths[font.id] = target;
    return target;
  }

  /// Write the watermark text to a file and return its path.
  ///
  /// The text is written as UTF-8. ffmpeg's `textfile` reads it back with
  /// the same encoding, so Chinese text survives the round trip -- measured
  /// on host ffmpeg 9.0.2.
  ///
  /// A trailing newline is deliberately NOT appended: ffmpeg would draw it
  /// as a second line.
  Future<String> writeTextFile(String text) async {
    await Directory(workDir).create(recursive: true);
    final path =
        '$workDir/watermark_text_${DateTime.now().millisecondsSinceEpoch}.txt';
    await File(path).writeAsString(text, encoding: utf8, flush: true);
    return path;
  }

  /// Work out what kind of media [path] is.
  ///
  /// The detection is by CONTENT, not by file extension: the previous implementation
  /// reaches the same conclusion from the bytes it decodes, and a user who
  /// picks a `.gif` that is really a JPEG should not get a broken command.
  ///
  /// The rules themselves live in `utils/media_kind.dart` so they can be
  /// unit-tested on the host VM -- this service imports `ffmpeg_kit_flutter_new`
  /// and therefore cannot be loaded by the plain Dart VM.
  static Future<ffmpeg.WatermarkMediaKind> detectKind(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw AddWatermarkException('找不到文件: $path');
    }
    final bytes = await file.readAsBytes();
    return mk.mediaKindOfBytes(bytes);
  }

  /// The output file name for a watermarked [inputPath].
  ///
  /// The extension follows the KIND, not the input's extension: a GIF
  /// input always produces a `.gif` (so the muxer is never guessed from a
  /// name), an image input a `.png` (lossless, so the watermark's own
  /// colours survive exactly), a video input a `.mp4`.
  static String outputNameFor(
    String workDir,
    ffmpeg.WatermarkMediaKind kind,
    int stamp,
  ) {
    return '$workDir/watermarked_$stamp.${mk.outputExtensionFor(kind)}';
  }

  /// One watermark layer as the UI describes it: content plus parameters,
  /// no ffmpeg arguments.
  ///
  /// The union-of-fields shape mirrors [ffmpeg.WatermarkLayerSpec] because
  /// the UI edits a heterogeneous list; the service turns each request into
  /// a spec after putting the text and fonts on disk.
  Future<String> addLayers({
    required String inputPath,
    required List<WatermarkLayerRequest> layers,
    required ffmpeg.WatermarkMediaKind kind,
    bool stillSource = false,
    bool loop = true,
    FormatSpec? format,
    int quality = 90,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    if (layers.isEmpty) {
      throw AddWatermarkException('请至少添加一个水印');
    }

    final specs = <ffmpeg.WatermarkLayerSpec>[];
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      final label = '第 ${i + 1} 个水印';
      switch (layer.kind) {
        case ffmpeg.WatermarkLayerKind.text:
          final text = layer.text?.trim() ?? '';
          if (text.isEmpty) {
            throw AddWatermarkException('$label没有文字');
          }
          final font = layer.font;
          if (font == null) {
            throw AddWatermarkException('$label没有选择字体');
          }
          specs.add(ffmpeg.WatermarkLayerSpec(
            kind: ffmpeg.WatermarkLayerKind.text,
            placement: layer.placement,
            opacity: layer.opacity,
            textFilePath: await writeTextFile(text),
            fontFilePath: await ensureFontFile(font),
            fontSize: layer.fontSize,
            fontColor: layer.fontColor,
          ));
        case ffmpeg.WatermarkLayerKind.image:
        case ffmpeg.WatermarkLayerKind.gif:
          final path = layer.mediaPath;
          if (path == null || !File(path).existsSync()) {
            throw AddWatermarkException('$label找不到文件: $path');
          }
          specs.add(ffmpeg.WatermarkLayerSpec(
            kind: layer.kind,
            placement: layer.placement,
            opacity: layer.opacity,
            mediaPath: path,
            width: layer.width,
            frames: layer.kind == ffmpeg.WatermarkLayerKind.gif
                ? await gifFrameCount(path)
                : 256,
          ));
      }
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    // The picker decides the container; without one the historical default
    // per kind applies (gif/png/mp4).
    final output = format == null
        ? outputNameFor(workDir, kind, stamp)
        : '$workDir/watermarked_$stamp.${format.extension}';
    final args = ffmpeg.addWatermarks(
      inputPath: inputPath,
      outputPath: output,
      kind: kind,
      layers: specs,
      loop: loop,
      stillSource: stillSource,
      format: format,
      quality: quality,
    );
    await _run(
      args,
      output,
      onProgress: onProgress,
      onJob: onJob,
      totalMs: totalMs,
    );
    return output;
  }

  /// Apply a TEXT watermark.
  Future<String> addText({
    required String inputPath,
    required String text,
    required WatermarkFont font,
    int fontSize = 24,
    String fontColor = 'white',
    ffmpeg.WatermarkPlacement placement =
        const ffmpeg.WatermarkPlacement.anchor(
            ffmpeg.WatermarkPosition.bottomRight),
    double opacity = 1.0,
    ffmpeg.WatermarkMediaKind kind = ffmpeg.WatermarkMediaKind.gif,
    bool loop = true,
  }) async {
    if (text.trim().isEmpty) {
      throw AddWatermarkException('请输入水印文字');
    }
    final fontPath = await ensureFontFile(font);
    final textPath = await writeTextFile(text);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final output = outputNameFor(workDir, kind, stamp);

    final args = ffmpeg.addWatermarkText(
      inputPath: inputPath,
      outputPath: output,
      textFilePath: textPath,
      fontFilePath: fontPath,
      kind: kind,
      fontSize: fontSize,
      fontColor: fontColor,
      placement: placement,
      opacity: opacity,
      loop: loop,
    );

    await _run(args, output);
    return output;
  }

  /// Apply an IMAGE watermark.
  Future<String> addImage({
    required String inputPath,
    required String watermarkPath,
    ffmpeg.WatermarkPlacement placement =
        const ffmpeg.WatermarkPlacement.anchor(
            ffmpeg.WatermarkPosition.bottomRight),
    double opacity = 1.0,
    int? watermarkWidth,
    ffmpeg.WatermarkMediaKind kind = ffmpeg.WatermarkMediaKind.gif,
    bool loop = true,
  }) async {
    final wm = File(watermarkPath);
    if (!wm.existsSync()) {
      throw AddWatermarkException('找不到水印图片: $watermarkPath');
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final output = outputNameFor(workDir, kind, stamp);

    final args = ffmpeg.addWatermarkImage(
      inputPath: inputPath,
      watermarkPath: watermarkPath,
      outputPath: output,
      kind: kind,
      placement: placement,
      opacity: opacity,
      watermarkWidth: watermarkWidth,
      loop: loop,
    );

    await _run(args, output);
    return output;
  }

  /// Apply a GIF watermark (an animated one).
  ///
  /// [watermarkFrames] is the watermark GIF's own frame count, which the
  /// `loop` filter needs as its buffer capacity -- see
  /// [ffmpeg.addWatermarkGif] for why a wrong value silently breaks the
  /// animation. It is read from the file with [GifReader]; a watermark that
  /// cannot be parsed gets a generous default rather than a small one,
  /// because an oversized buffer is harmless and an undersized one is not.
  Future<String> addGifWatermark({
    required String inputPath,
    required String watermarkPath,
    ffmpeg.WatermarkPlacement placement =
        const ffmpeg.WatermarkPlacement.anchor(
            ffmpeg.WatermarkPosition.bottomRight),
    double opacity = 1.0,
    int? watermarkWidth,
    ffmpeg.WatermarkMediaKind kind = ffmpeg.WatermarkMediaKind.gif,
    bool loop = true,
  }) async {
    final wm = File(watermarkPath);
    if (!wm.existsSync()) {
      throw AddWatermarkException('找不到 GIF 水印: $watermarkPath');
    }
    final frames = await gifFrameCount(watermarkPath);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final output = outputNameFor(workDir, kind, stamp);

    final args = ffmpeg.addWatermarkGif(
      inputPath: inputPath,
      watermarkPath: watermarkPath,
      outputPath: output,
      kind: kind,
      placement: placement,
      opacity: opacity,
      watermarkWidth: watermarkWidth,
      watermarkFrames: frames,
      loop: loop,
    );

    await _run(args, output);
    return output;
  }

  /// The frame count of the GIF at [path], or a generous fallback.
  ///
  /// The fallback is deliberately large: the `loop` filter's `size` only
  /// breaks things when it is too SMALL (measured: size=1 freezes the
  /// watermark, size=0 truncated the output), never when it is too large.
  static Future<int> gifFrameCount(String path) async {
    try {
      final info = gr.GifReader.parse(await File(path).readAsBytes());
      if (info.isValidFrames) return info.frames;
    } catch (_) {
      // Fall through to the default.
    }
    return 256;
  }

  /// Render a single-frame preview of the watermarked result.
  ///
  /// The preview is a SEPARATE ffmpeg pass on a downscaled copy of the
  /// first frame. Rendering the whole GIF would take seconds and produce a
  /// file the UI cannot display cheaply; one frame at 480 px is enough to
  /// show where the watermark lands and how big it looks.
  /// A displayable still of the source, as a PNG file path.
  ///
  /// Flutter can draw a GIF or a still image straight from the file, so
  /// this only has work to do for a VIDEO source: its first frame is
  /// extracted with ffmpeg. Returns null when the extraction fails -- a
  /// missing preview must not fail the whole feature, since the real output
  /// is what matters.
  Future<String?> sourceFrame(String inputPath) async {
    try {
      await Directory(workDir).create(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final output = '$workDir/wm_source_$stamp.png';
      final session = await FFmpegKit.executeWithArguments(
        ffmpeg.firstFrame(inputPath: inputPath, outputPath: output),
      );
      final code = await session.getReturnCode();
      if (code?.isValueSuccess() != true) return null;
      final file = File(output);
      if (!file.existsSync() || file.lengthSync() == 0) return null;
      return output;
    } catch (_) {
      return null;
    }
  }

  Future<void> _run(
    List<String> args,
    String output, {
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    try {
      final job = await runWithProgress(
        args,
        totalMs: totalMs,
        onProgress: onProgress,
      );
      onJob?.call(job);
      await job.wait();
    } on FfmpegCancelled {
      rethrow;
    } on FfmpegException catch (e) {
      throw AddWatermarkException('处理失败: ${_summarize(e.output)}');
    }
    final file = File(output);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw AddWatermarkException('处理结束但没有产出文件');
    }
  }

  /// Pull the useful lines out of ffmpeg's log.
  ///
  /// ffmpeg is chatty; the last dozen lines are what say what went wrong.
  static String _summarize(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '(no output)';
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '(no output)';
    final interesting = lines.where((l) {
      final lower = l.toLowerCase();
      return lower.contains('error') ||
          lower.contains('invalid') ||
          lower.contains('failed') ||
          lower.contains('cannot') ||
          lower.contains('unable') ||
          lower.contains('no such') ||
          lower.contains('not found') ||
          lower.contains('unsupported') ||
          lower.contains('unrecognized');
    }).toList();
    if (interesting.isNotEmpty) {
      return interesting.take(4).join(' | ');
    }
    return lines.take(3).join(' | ');
  }

  /// The pixel size of the media at [path], for the UI to scale its
  /// preview. Returns null when it cannot be read.
  static Future<(int, int)?> dimensionsOf(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final bytes = await file.readAsBytes();
      if (mk.looksLikeGif(bytes)) {
        final info = gr.GifReader.parse(bytes);
        if (info.width > 0 && info.height > 0) return (info.width, info.height);
        return null;
      }
      final info = ir.ImageReader.parse(bytes);
      if (info.isValid) return (info.width, info.height);
    } catch (_) {
      return null;
    }
    return null;
  }
}
