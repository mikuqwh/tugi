// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - Add watermark screen.
///
/// the parameters this screen exposes:
///
///
/// ## The preview is drawn by Flutter, not by ffmpeg
///
/// The watermark has to be draggable, and a drag has to be answered at
/// frame rate. An ffmpeg pass per drag event is hundreds of milliseconds,
/// so the preview composites the watermark natively instead: the source is
/// an `Image.file` (Flutter decodes animated GIFs itself), and the
/// watermark is a `Text` or an `Image` positioned by an `Align`.
///
/// The consequence is that the preview and the encoder agree by
/// CONSTRUCTION rather than by measurement: the position is stored as the
/// watermark's centre as a fraction of the frame, which means the same
/// thing at preview resolution and at source resolution, and the builder
/// emits `x = fx*main_w - text_w/2` so ffmpeg does the subtraction with the
/// real watermark size. Nothing has to be measured in Dart, so nothing can
/// disagree.
// SPDX-License-Identifier: GPL-3.0-or-later

library add_watermark_screen;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../ffmpeg/commands.dart'
    show
        WatermarkLayerKind,
        WatermarkMediaKind,
        WatermarkPlacement,
        WatermarkPosition;
import '../models/watermark_placement.dart';
import '../services/add_watermark_service.dart';
import '../services/ffmpeg_progress.dart';
import '../services/export_service.dart';
import 'package:format_core/format_core.dart';

import '../services/color_presets.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/export_progress.dart';
import '../ui/color_picker_dialog.dart';
import '../ui/color_wheel.dart';
import '../ui/eager_pan.dart';
import '../ui/eager_scale.dart';
import '../ui/output_format_picker.dart';
import '../ui/rainbow_glow.dart';
import '../utils/gif_reader.dart';
import '../utils/watermark_fonts.dart';

/// Which kind of watermark the user is adding.
enum _WatermarkType {
  text,
  image,
  gif,
}

/// The palette the user can pick a text colour from.
///
/// The previous implementation lets the user choose any colour and even enter a hex value
/// free-form picker is a second screen's worth of work; the preset swatches
/// cover the cases that matter on a video frame.
const List<(String, Color)> _textColors = [
  ('white', Colors.white),
  ('black', Colors.black),
  ('yellow', Color(0xFFFFD400)),
  ('red', Color(0xFFFF3B30)),
  ('orange', Color(0xFFFF9500)),
  ('green', Color(0xFF34C759)),
  ('cyan', Color(0xFF32ADE6)),
  ('blue', Color(0xFF007AFF)),
  ('purple', Color(0xFFAF52DE)),
  ('grey', Color(0xFF8E8E93)),
];

class AddWatermarkScreen extends StatefulWidget {
  const AddWatermarkScreen({
    super.key,
    this.initialSourcePath,
    this.initialGifWatermarkPath,
  });

  /// Pre-load a source file instead of waiting for the picker.
  ///
  /// The picker cannot be driven by a test, so this is the seam the device
  /// test uses to exercise the screen against a real file.
  final String? initialSourcePath;

  /// Same idea for the watermark file itself (a GIF or a still).
  final String? initialGifWatermarkPath;

  @override
  State<AddWatermarkScreen> createState() => AddWatermarkScreenState();
}

class AddWatermarkScreenState extends State<AddWatermarkScreen> {
  /// The source media.
  String? _inputPath;
  int _inputBytes = 0;

  /// Source length in seconds; 0 for stills and unknown files.
  double _sourceSeconds = 0;
  WatermarkMediaKind _kind = WatermarkMediaKind.gif;

  /// The source's pixel size, used to turn the relative size sliders into
  /// the absolute pixel values ffmpeg's `fontsize` and `scale` want.
  (int, int)? _sourceSize;

  /// A still of the source, for the kinds Flutter cannot draw directly.
  /// Only a video needs this; a GIF or a still image is shown as-is.
  String? _sourceFramePath;

  /// The watermark layers, painted in list order: later ones sit on top.
  ///
  /// One text layer is the starting point, which is exactly what this screen
  /// was before it could hold several -- so the single-watermark path is the
  /// N=1 case of the same code, not a separate mode.
  final List<_WatermarkLayer> _layers = [
    _WatermarkLayer(type: _WatermarkType.text),
  ];

  /// Which layer the panel edits and the preview drags.
  int _selected = 0;

  /// Six is the point where the panel gets longer than it is useful; the
  /// original has no multi-layer support at all, so this is our own limit.
  static const int _maxLayers = 6;

  _WatermarkLayer get _layer => _layers[_selected];

  // The selected layer's parameters. The panel and the preview read these
  // rather than reaching through [_layer] everywhere, so editing a layer
  // looks like editing a screen-level field -- and switching layers is one
  // index change instead of a state reload.

  _WatermarkType get _type => _layer.type;
  set _type(_WatermarkType value) => _layer.type = value;

  WatermarkFont get _font => _layer.font;
  set _font(WatermarkFont value) => _layer.font = value;

  TextEditingController get _textController => _layer.textController;

  int get _colorValue => _layer.colorValue;
  set _colorValue(int value) => _layer.colorValue = value;

  /// Font size as a PERCENTAGE of the source width.
  ///
  /// ffmpeg's `fontsize` is in source pixels, so an absolute number would
  /// mean something different on a 480 px GIF and a 4K video. A percentage
  /// keeps the watermark looking the same relative size on both, and the
  /// slider still shows the pixel value it works out to.
  double get _textSizePercent => _layer.textSizePercent;
  set _textSizePercent(double value) => _layer.textSizePercent = value;

  /// The watermark image's width as a percentage of the source width.
  double get _imageWidthPercent => _layer.imageWidthPercent;
  set _imageWidthPercent(double value) => _layer.imageWidthPercent = value;

  /// Opacity, 0.05..1.
  ///
  double get _opacity => _layer.opacity;
  set _opacity(double value) => _layer.opacity = value;

  /// Where the watermark sits. Starts as a preset anchor; becomes a free
  /// position the moment the preview is dragged.
  WatermarkPlacement get _placement => _layer.placement;
  set _placement(WatermarkPlacement value) => _layer.placement = value;

  String? get _watermarkImagePath => _layer.mediaPath;
  set _watermarkImagePath(String? value) => _layer.mediaPath = value;

  // Output state.
  bool _applying = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  String? _outputPath;
  int? _outputBytes;

  /// Measures the preview frame itself.
  final GlobalKey _frameKey = GlobalKey();

  /// The preview area's size, in pixels.
  Size _previewSize = Size.zero;

  /// Preview zoom: two fingers scale the stage, one finger still places the
  /// watermark. The drag maths divides by [_stageScale] so the mark follows
  /// the finger exactly when zoomed in.
  double _stageScale = 1;
  Offset _stageOffset = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// True while a watermark is under the finger; grows the preview stage so
  /// a tall source can still be placed accurately.
  bool _draggingWatermark = false;

  /// The output container, when the source kind allows a choice. Null means
  /// "the historical default for this kind" (PNG for stills, MP4 for videos,
  /// GIF for animations).
  FormatSpec? _outputFormat;

  static const _accent = FeatureColors.addWatermark;
  static const _on = FeatureColors.addWatermarkOn;

  AddWatermarkService get _service => AddWatermarkService(
        workDir: Directory.systemTemp.path,
      );

  @override
  void initState() {
    super.initState();
    _loadFonts();
    final preset = widget.initialSourcePath;
    if (preset != null && preset.isNotEmpty) {
      // Deferred: the file has to be read off the event loop, and the
      // first frame must not be built before initState returns.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSource(preset));
    }
    final gifWatermark = widget.initialGifWatermarkPath;
    if (gifWatermark != null && gifWatermark.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          // A text layer renders nothing, so the clamp's measurement would
          // stay null and the drag would be unbounded.
          _layers[0].type = _WatermarkType.gif;
          _layer.mediaPath = gifWatermark;
        });
        // The new file has a size now; the clamp must see it before the first
        // drag rather than one frame later.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _measure();
        });
      });
    }
  }

  @override
  void dispose() {
    for (final layer in _layers) {
      layer.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Layers
  // ---------------------------------------------------------------------

  /// Add a layer of the same kind as the selected one.
  ///
  /// Same kind because that is the common case: someone adding a second GIF
  /// watermark is not asking to switch to text. The new layer starts empty
  /// (no text, no file) and is selected, so the panel immediately points at
  /// what still needs filling in.
  void _addLayer() {
    if (_layers.length >= _maxLayers) {
      setState(() => _error = '最多支持 $_maxLayers 个水印');
      return;
    }
    setState(() {
      final type = _layer.type;
      _layers.add(_WatermarkLayer(
        type: type,
        // Copy the size/opacity settings: they describe how the user wants
        // watermarks to look, not what this particular one contains.
        opacity: _layer.opacity,
        textSizePercent: _layer.textSizePercent,
        imageWidthPercent: _layer.imageWidthPercent,
        font: _layer.font,
        colorValue: _layer.colorValue,
      ));
      _selected = _layers.length - 1;
      _error = null;
      // The new layer has nothing to show yet; the drag handle must not
      // point at a stale measurement.
      _draggingWatermark = false;
    });
  }

  void _removeLayer(int index) {
    if (_layers.length <= 1) {
      setState(() => _error = '至少保留一个水印');
      return;
    }
    setState(() {
      final removed = _layers.removeAt(index);
      removed.dispose();
      if (_selected >= _layers.length) _selected = _layers.length - 1;
      _draggingWatermark = false;
    });
  }

  void _selectLayer(int index) {
    if (index == _selected) return;
    setState(() {
      _selected = index;
      _draggingWatermark = false;
    });
  }

  /// Test seam: run the normal load path from outside a frame.
  ///
  /// A widget test cannot use [initialSourcePath] for this, because the load
  /// it triggers starts inside a post-frame callback, and real file I/O
  /// started in the fake async zone of `testWidgets` never completes. Calling
  /// this from inside `tester.runAsync` puts the same code on a real event
  /// loop, so the test drives the production path rather than a copy of it.
  @visibleForTesting
  Future<void> loadSourceForTest(String path) => _loadSource(path);

  /// Register every bundled font as a Flutter family.
  ///
  /// The preview draws with these; without them a `fontFamily` that does
  /// not exist silently falls back to the default face and the preview
  /// would stop matching the output.
  Future<void> _loadFonts() async {
    for (final font in watermarkFonts) {
      final loader = FontLoader(font.flutterFamily);
      loader.addFont(rootBundle.load(font.assetPath));
      await loader.load();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// The source width in pixels, or a sane default when it is unknown.
  int get _sourceWidth => _sourceSize?.$1 ?? 720;

  /// The scale from source pixels to preview pixels.
  double get _previewScale {
    if (_sourceWidth == 0 || _previewSize.width == 0) return 1;
    return _previewSize.width / _sourceWidth;
  }

  /// The font size in source pixels, for the current percentage.
  int _fontSizePxFor(_WatermarkLayer layer) =>
      (_sourceWidth * layer.textSizePercent / 100).round().clamp(8, 400);

  int get _fontSizePx => _fontSizePxFor(_layer);

  /// The watermark image's width in source pixels.
  int _watermarkWidthPxFor(_WatermarkLayer layer) =>
      (_sourceWidth * layer.imageWidthPercent / 100).round().clamp(16, 4000);

  int get _watermarkWidthPx => _watermarkWidthPxFor(_layer);

  Color _textColorFor(_WatermarkLayer layer) => Color(layer.colorValue);

  /// The ffmpeg colour name for the picked swatch.
  ///
  /// ffmpeg's `fontcolor` takes a colour NAME or a hex value. The hex
  /// form is used so the swatch and the rendered watermark cannot drift
  /// apart: a name like `orange` is not the same orange in every ffmpeg
  /// build.
  String _fontColorNameFor(_WatermarkLayer layer) {
    final c = _textColorFor(layer);
    if (c == Colors.white) return 'white';
    if (c == Colors.black) return 'black';
    // `toARGB32` rather than the deprecated `value`; the leading alpha byte
    // is dropped so ffmpeg gets a plain #RRGGBB.
    final argb = c.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${argb.substring(2).toUpperCase()}';
  }

  /// Load [path] as the source, detecting its kind and size.
  Future<void> _loadSource(String path) async {
    try {
      final kind = await AddWatermarkService.detectKind(path);
      final size = await AddWatermarkService.dimensionsOf(path);
      // A video needs a decoder the preview has no business owning, so its
      // first frame is extracted once, here.
      String? frame;
      if (kind == WatermarkMediaKind.video) {
        frame = await _service.sourceFrame(path);
      }
      // Length is only used for the progress estimate; a failure just leaves
      // the bar indeterminate.
      final seconds = await _sourceSecondsOf(path, kind);
      if (!mounted) return;
      setState(() {
        _inputPath = path;
        _inputBytes = File(path).lengthSync();
        _kind = kind;
        _sourceSize = size;
        _sourceFramePath = frame;
        _sourceSeconds = seconds;
        _outputPath = null;
        _outputBytes = null;
        _error = null;
        _stageScale = 1;
        _stageOffset = Offset.zero;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取文件失败: $e');
    }
  }

  /// Duration of the source in seconds (0 when unknown).
  Future<double> _sourceSecondsOf(
    String path,
    WatermarkMediaKind kind,
  ) async {
    try {
      if (kind == WatermarkMediaKind.gif) {
        return GifReader.parse(File(path).readAsBytesSync()).seconds;
      }
      if (kind == WatermarkMediaKind.video) {
        final session = await FFprobeKit.getMediaInformation(path);
        final info = await session.getMediaInformation();
        return double.tryParse(info?.getDuration() ?? '') ?? 0;
      }
    } catch (_) {
      // Unknown length: the bar stays indeterminate.
    }
    return 0;
  }

  Future<void> _pickMedia() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _loadSource(picked.path);
    } catch (e) {
      setState(() => _error = '选择文件失败: $e');
    }
  }

  Future<void> _pickWatermarkImage() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      setState(() {
        _watermarkImagePath = picked.path;
        _error = null;
        // The layer's measured size is now stale (the previous file, or null
        // for the first pick). Without this the clamp would use a size that
        // no longer matches what is on screen.
        _layer.size = null;
      });
      // One frame later the new image has a size, and the drag clamp gets it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measure();
      });
    } catch (e) {
      setState(() => _error = '选择水印图片失败: $e');
    }
  }

  /// Any parameter change that affects the preview.
  ///
  /// The preview is native, so there is nothing to re-render -- this only
  /// rebuilds, which is free.
  void _onParametersChanged() {
    if (mounted) setState(() {});
    // Text, size and opacity all change the layer's measured box, and the drag
    // clamp reads that box. Re-measure so it is never one edit behind.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
  }

  bool get _canApply {
    if (_inputPath == null) return false;
    if (_layers.isEmpty) return false;
    return _layers.every((layer) => layer.hasContent);
  }

  /// What kind of file the output will be.
  ///
  /// The source decides it, with one exception: a still image whose
  /// watermarks include an animated GIF has to come out as a GIF, because
  /// the animation lives in a video stream. That is the same rule the
  /// single-watermark builder had, widened from "the one watermark" to
  /// "any watermark".
  WatermarkMediaKind get _outputKind {
    switch (_kind) {
      case WatermarkMediaKind.gif:
        return WatermarkMediaKind.gif;
      case WatermarkMediaKind.video:
        return WatermarkMediaKind.video;
      case WatermarkMediaKind.image:
        final animated =
            _layers.any((layer) => layer.type == _WatermarkType.gif);
        return animated ? WatermarkMediaKind.gif : WatermarkMediaKind.image;
    }
  }

  /// The layers as the service wants them, in paint order.
  List<WatermarkLayerRequest> _layerRequests() {
    return [
      for (final layer in _layers)
        WatermarkLayerRequest(
          kind: switch (layer.type) {
            _WatermarkType.text => WatermarkLayerKind.text,
            _WatermarkType.image => WatermarkLayerKind.image,
            _WatermarkType.gif => WatermarkLayerKind.gif,
          },
          placement: layer.placement,
          opacity: layer.opacity,
          text: layer.type == _WatermarkType.text
              ? layer.textController.text
              : null,
          font: layer.font,
          fontSize: _fontSizePxFor(layer),
          fontColor: _fontColorNameFor(layer),
          mediaPath: layer.type == _WatermarkType.text ? null : layer.mediaPath,
          width: layer.type == _WatermarkType.text
              ? null
              : _watermarkWidthPxFor(layer),
        ),
    ];
  }

  /// Formats worth offering for the CURRENT output kind.
  List<FormatSpec> get _formatChoices {
    switch (_outputKind) {
      case WatermarkMediaKind.gif:
        // APNG is true-colour and keeps alpha exactly; it skips the palette
        // tail in [addWatermarks] (see the `isApng` branch there).
        return [formatById('gif')!, formatById('apng')!];
      case WatermarkMediaKind.image:
        return [
          formatById('png')!,
          formatById('jpg')!,
          formatById('webp')!,
          formatById('avif')!,
          formatById('bmp')!,
          formatById('tiff')!,
        ];
      case WatermarkMediaKind.video:
        return formatsFor(MediaKind.video);
    }
  }

  /// The format actually used: the user's pick if it still fits the kind,
  /// otherwise the default for that kind.
  FormatSpec? get _activeFormat {
    final choices = _formatChoices;
    if (choices.isEmpty) return null;
    final picked = _outputFormat;
    if (picked != null && choices.any((f) => f.id == picked.id)) return picked;
    return switch (_outputKind) {
      WatermarkMediaKind.video => formatById('mp4_h264'),
      WatermarkMediaKind.gif => formatById('gif'),
      WatermarkMediaKind.image => formatById('png'),
    };
  }

  Future<void> _apply() async {
    final input = _inputPath;
    if (input == null || !_canApply) return;
    setState(() {
      _applying = true;
      _progress = 0;
      _job = null;
      _error = null;
    });

    try {
      // A still has no time axis: leaving totalMs null keeps the bar
      // indeterminate instead of finishing at 0%.
      final ms = _sourceDurationMs;
      final path = await _service.addLayers(
        inputPath: input,
        layers: _layerRequests(),
        kind: _outputKind,
        stillSource: _kind == WatermarkMediaKind.image,
        format: _activeFormat,
        totalMs: ms,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
      );
      setState(() {
        _outputPath = path;
        _outputBytes = File(path).lengthSync();
      });
    } on FfmpegCancelled {
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _applying = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Duration of the source when it has one (video/GIF); null for a still.
  int? get _sourceDurationMs {
    if (_sourceSeconds <= 0) return null;
    if (_kind == WatermarkMediaKind.image) return null;
    return (_sourceSeconds * 1000).round();
  }

  /// Stop the running job.
  void _cancelApply() => _job?.cancel();

  /// Batch: keep every watermark as configured and just swap the source.
  ///
  /// This is the "continue with the next file" half of batch processing. A
  /// reset would throw away the watermark the user just spent a minute
  /// getting right, which is exactly what the old "再来一个" did.
  Future<void> _continueWithNext() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _switchSource(picked.path);
    } catch (e) {
      setState(() => _error = '选择文件失败: $e');
    }
  }

  /// Point the screen at [path], keeping the layers.
  ///
  /// Split from the picker so a test can drive it: the picker cannot be
  /// automated, but "the watermark survives a source change" is the whole
  /// contract of the batch button.
  @visibleForTesting
  Future<void> switchSourceForTest(String path) => _switchSource(path);

  Future<void> _switchSource(String path) async {
    await _loadSource(path);
    if (!mounted) return;
    setState(() {
      _outputPath = null;
      _outputBytes = null;
      _error = null;
    });
  }

  Future<void> _saveToGallery() async {
    final path = _outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    // The output can be an image OR a video depending on the source, and the
    // service picks Gal.putImage / Gal.putVideo accordingly (this used to send
    // every result to putImage, which fails for an mp4).
    final outcome = await ExportService().save(path, album: 'Tugi');
    if (!mounted) {
      setState(() => _saving = false);
      return;
    }
    setState(() => _saving = false);
    final message = switch (outcome.status) {
      ExportStatus.savedToGallery => '已存到相册',
      ExportStatus.savedToFile => outcome.message ?? '已保存到文件',
      ExportStatus.cancelled => '已取消',
      ExportStatus.failed => outcome.message ?? '保存失败',
    };
    if (outcome.isSuccess) {
      await WorksService.instance.record(
        originPath: path,
        featureId: 'add_watermark',
        sourcePath: _inputPath,
      );
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share() async {
    final path = _outputPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      setState(() => _error = '分享失败: $e');
    }
  }

  void _reset() {
    setState(() {
      _inputPath = null;
      _inputBytes = 0;
      _sourceSize = null;
      _sourceFramePath = null;
      _outputPath = null;
      _outputBytes = null;
      _error = null;
      for (final layer in _layers) {
        layer.dispose();
      }
      _layers
        ..clear()
        ..add(_WatermarkLayer(type: _WatermarkType.text));
      _selected = 0;
      _draggingWatermark = false;
    });
  }

  String _kindLabel(WatermarkMediaKind kind) {
    switch (kind) {
      case WatermarkMediaKind.gif:
        return 'GIF';
      case WatermarkMediaKind.image:
        return '图片';
      case WatermarkMediaKind.video:
        return '视频';
    }
  }

  String get _typeLabel {
    switch (_type) {
      case _WatermarkType.text:
        return '文字';
      case _WatermarkType.image:
        return '图片';
      case _WatermarkType.gif:
        return 'GIF';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.indigo),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.addWatermark,
          ),
          title: const Text('Add watermark'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        body: _inputPath == null
            ? _buildEmptyState()
            : Column(
                children: [
                  _buildPinnedPreview(),
                  Expanded(child: _buildControlPanel()),
                ],
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.branding_watermark, size: 56, color: _accent),
        const SizedBox(height: 16),
        const Text(
          '给 GIF、图片或视频加上水印',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          '文字、图片或 GIF 都可以，拖动即可摆位',
          textAlign: TextAlign.center,
          style: TextStyle(color: Neutrals.inkSoft),
        ),
        const SizedBox(height: 24),
        RainbowGlow(
            child: ElevatedButton.icon(
          onPressed: _pickMedia,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('选择文件'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: _on,
            disabledBackgroundColor: _accent.withValues(alpha: 0.16),
            disabledForegroundColor: _accent.withValues(alpha: 0.55),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        )),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Preview
  // ---------------------------------------------------------------------

  /// The preview, pinned above the controls.
  ///
  /// Same contract as the Edit Image screen: the subject never scrolls
  /// away, so the user can see where the watermark lands while adjusting
  /// the parameters below. The stage is height-capped so tall sources
  /// leave room for the panel.
  Widget _buildPinnedPreview() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPreviewArea(),
          const SizedBox(height: 4),
          const Text(
            '拖动水印可自由摆位',
            style: TextStyle(fontSize: 11, color: Neutrals.inkSoft),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea() {
    final size = _sourceSize;
    final aspect = (size != null && size.$2 > 0) ? size.$1 / size.$2 : 16 / 9;

    // Measure after this frame so the drag maths has the real numbers. The
    // guard inside `_measure` is what keeps this from being a rebuild loop.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

    // Same height-capped stage as Edit Image: the frame keeps the source's
    // aspect ratio but never exceeds 300 logical px tall, so a tall source
    // (a phone screenshot is ~0.45 aspect) cannot push the control panel
    // off screen. The Stack still fills the frame box exactly, so a
    // fraction of the Stack IS a fraction of the frame at any size.
    //
    // The cap is also bounded by the screen: a landscape phone has only ~360
    // logical px of height, where a flat 300 would repeat the very overflow
    // this cap exists to prevent.
    //
    // While the watermark is being dragged the stage takes more of the
    // screen -- a 1080x2400 source is only ~120 px wide at the resting cap,
    // where a 6% watermark is a few pixels tall and impossible to place.
    // The panel gives that height up temporarily, exactly like Edit Image's
    // slider drag; it gets it back on release.
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxStage = _draggingWatermark
        ? math.min(420.0, screenHeight * 0.62)
        : math.min(300.0, screenHeight * 0.42);
    return LayoutBuilder(builder: (context, box) {
      // The cap is the animation's target, not a snapped value: growing and
      // shrinking the stage over ~200 ms reads as the preview making room,
      // where a jump cut looked like the layout breaking. `Tween` has no
      // begin on purpose -- TweenAnimationBuilder starts each animation from
      // the value on screen, so interrupting a grow with a release reverses
      // from wherever it got to instead of restarting.
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(end: maxStage),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        builder: (context, cap, _) {
          var w = box.maxWidth;
          var h = w / aspect;
          if (h > cap) {
            h = cap;
            w = h * aspect;
          }
          return Center(
            child: SizedBox(
              // Test handle for the stage size: the cap is a layout contract,
              // and asserting on the caption's position instead would only
              // catch it indirectly.
              key: const Key('wm_stage'),
              width: w,
              height: h,
              child: Container(
                key: _frameKey,
                decoration: BoxDecoration(
                  color: Neutrals.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Neutrals.line),
                ),
                clipBehavior: Clip.antiAlias,
                // The gesture surface wraps the whole frame rather than
                // sitting inside the transformed Stack: inside, the clip and
                // the transform made it miss touches in some layouts.
                child: Listener(
                  // Selection on pointer-down, independent of the gesture
                  // arena: the eager scale recogniser would otherwise eat a
                  // plain tap on a watermark before its onTap could fire.
                  onPointerDown: (e) => _selectLayerAt(e.position),
                  child: EagerScaleDetector(
                    onStart: _onStageStart,
                    onUpdate: _onStageUpdate,
                    onEnd: (_) => _setWatermarkDragging(false),
                    child: ClipRect(
                      child: Transform(
                        key: const Key('wm_stage_transform'),
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..translateByDouble(
                              _stageOffset.dx, _stageOffset.dy, 0, 1)
                          ..scaleByDouble(_stageScale, _stageScale, 1, 1),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _buildSourceLayer(),
                            _buildWatermarkLayers(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    });
  }

  /// Read the frame and every layer's size off the tree.
  ///
  /// Both are needed for the drag: the frame to turn a pixel delta into a
  /// fraction, and the layer to clamp it inside the frame. Only rebuilds when
  /// something actually changed -- an unconditional `setState` here would
  /// spin forever.
  void _measure() {
    if (!mounted) return;
    final frameBox = _frameKey.currentContext?.findRenderObject() as RenderBox?;
    final frame =
        (frameBox != null && frameBox.hasSize) ? frameBox.size : Size.zero;

    var changed = frame != _previewSize;
    for (final layer in _layers) {
      final box = layer.key.currentContext?.findRenderObject() as RenderBox?;
      final size = (box != null && box.hasSize) ? box.size : null;
      if (size != layer.size) {
        layer.size = size;
        changed = true;
      }
    }
    if (!changed) return;
    setState(() => _previewSize = frame);
  }

  /// The subject. Flutter draws GIFs and still images straight from the
  /// file; only a video needs a pre-extracted frame.
  Widget _buildSourceLayer() {
    final path = _inputPath;
    if (path == null) return const SizedBox.shrink();
    if (_kind == WatermarkMediaKind.video) {
      final frame = _sourceFramePath;
      if (frame == null) {
        return const Center(
          child: Icon(Icons.movie_outlined, color: Neutrals.inkSoft),
        );
      }
      return Image.file(File(frame), fit: BoxFit.fill, gaplessPlayback: true);
    }
    return Image.file(File(path), fit: BoxFit.fill, gaplessPlayback: true);
  }

  /// Every watermark layer, bottom to top.
  ///
  /// The full-size translucent drag catcher sits UNDER the layers: a drag
  /// that starts on empty preview still moves the selected watermark (on a
  /// tall source a watermark is only a few logical pixels tall, and making
  /// the finger land on it would turn placement into a precision exercise),
  /// while a tap on a layer itself still reaches that layer.
  Widget _buildWatermarkLayers() {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < _layers.length; i++) _buildLayer(i),
      ],
    );
  }

  /// One layer: tap selects it, pan drags it (and selects it first, so the
  /// panel never edits one watermark while the finger moves another).
  Widget _buildLayer(int index) {
    final layer = _layers[index];
    if (!layer.hasContent) return const SizedBox.shrink();
    final selected = index == _selected;

    final content = KeyedSubtree(
      key: layer.key,
      child: GestureDetector(
        onTap: () => _selectLayer(index),
        child: _buildWatermarkWidget(layer),
      ),
    );

    final positioned = layer.placement.isFree
        ? Align(
            alignment: Alignment(
              layer.placement.fx * 2 - 1,
              layer.placement.fy * 2 - 1,
            ),
            child: content,
          )
        : _buildAnchoredWatermark(layer);

    // No pan detector here on purpose: the stage-level scale detector owns
    // dragging, so a two-finger pinch that starts on the mark still zooms.
    // Dragging selects what is under the finger (_selectLayerAt).
    // The selection ring sits OUTSIDE the KeyedSubtree, so it does not
    // inflate the measured watermark size the clamp uses.
    return Container(
      decoration: selected
          ? BoxDecoration(
              border: Border.all(color: _accent, width: 1.2),
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      child: positioned,
    );
  }

  /// Follow the finger with the selected layer's centre.
  /// Test seam: what the clamp currently believes each layer measures.
  @visibleForTesting
  List<String> get debugLayerSizes => [
        for (final layer in _layers)
          layer.size == null
              ? 'null'
              : '${layer.size!.width.toStringAsFixed(1)}x'
                  '${layer.size!.height.toStringAsFixed(1)}',
      ];

  /// Test seam: the frame's size in pixels.
  @visibleForTesting
  Size get debugPreviewSize => _previewSize;

  /// Test seam: each layer's placement fractions.
  @visibleForTesting
  List<String> get debugPlacements => [
        for (final layer in _layers)
          '${layer.placement.fx.toStringAsFixed(3)},'
              '${layer.placement.fy.toStringAsFixed(3)}',
      ];

  void _onStageStart(ScaleStartDetails details) {
    _startScale = _stageScale;
    _startOffset = _stageOffset;
    _startFocal = details.focalPoint;
    if (details.pointerCount <= 1) _setWatermarkDragging(true);
  }

  /// Select the topmost watermark whose box is under [globalPoint].
  ///
  /// The stage detector is the only pan surface, so this is what makes
  /// "drag the mark I see" work without giving each layer its own recogniser
  /// (which would also swallow pinches that start on a mark).
  void _selectLayerAt(Offset globalPoint) {
    final box = _frameKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(globalPoint);
    final center = Offset(box.size.width / 2, box.size.height / 2);
    final p = center + (local - center - _stageOffset) / _stageScale;
    for (var i = _layers.length - 1; i >= 0; i--) {
      final layer = _layers[i];
      final size = layer.size;
      if (size == null) continue;
      final c = Offset(
        layer.placement.fx * box.size.width,
        layer.placement.fy * box.size.height,
      );
      final rect = Rect.fromCenter(
        center: c,
        width: size.width + 28,
        height: size.height + 28,
      );
      if (rect.contains(p)) {
        _selectLayer(i);
        return;
      }
    }
  }

  void _onStageUpdate(ScaleUpdateDetails details) {
    final frameBox = _frameKey.currentContext?.findRenderObject() as RenderBox?;
    if (frameBox == null || !frameBox.hasSize) return;
    final frame = frameBox.size;

    if (details.pointerCount >= 2) {
      // Pinch: zoom about the focal point, clamped so the image always fills
      // the frame and no empty edge appears.
      final next = (_startScale * details.scale).clamp(1.0, 4.0);
      final ratio = next / _startScale;
      final center = Offset(frame.width / 2, frame.height / 2);
      final focus = _startFocal -
          frameBox.localToGlobal(Offset.zero) -
          center -
          _startOffset;
      final raw = _startOffset +
          (details.focalPoint - _startFocal) -
          focus * (ratio - 1);
      final maxX = (frame.width * next - frame.width) / 2;
      final maxY = (frame.height * next - frame.height) / 2;
      setState(() {
        _stageScale = next;
        _stageOffset = Offset(
          raw.dx.clamp(-maxX, maxX),
          raw.dy.clamp(-maxY, maxY),
        );
      });
      return;
    }

    // One finger: place the watermark. Map the finger back through the zoom
    // before turning it into a fraction, so the mark lands under the finger.
    //
    // The stage grows on the first UPDATE as well as on start: a recogniser
    // may begin reporting updates before it reports a start, and the growth
    // is what gives a small mark room on a tall photo.
    _setWatermarkDragging(true);
    final local = frameBox.globalToLocal(details.focalPoint);
    final center = Offset(frame.width / 2, frame.height / 2);
    final unscaled = center + (local - center - _stageOffset) / _stageScale;
    _setFreePlacement(
      (unscaled.dx / frame.width).clamp(0.0, 1.0),
      (unscaled.dy / frame.height).clamp(0.0, 1.0),
    );
  }

  void _dragSelected(DragUpdateDetails details) {
    final box = _frameKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(details.globalPosition);
    // Undo the preview zoom: the mark must sit under the finger, not under
    // where the finger would be at 1x.
    final center = Offset(box.size.width / 2, box.size.height / 2);
    final unscaled = center + (local - center - _stageOffset) / _stageScale;
    _setFreePlacement(
      (unscaled.dx / box.size.width).clamp(0.0, 1.0),
      (unscaled.dy / box.size.height).clamp(0.0, 1.0),
    );
  }

  /// Grow the stage while a watermark is under the finger.
  ///
  /// The growth itself is animated by the stage (a `TweenAnimationBuilder`
  /// over the cap), not here: this only flips the target.
  /// A new picture starts un-zoomed: keeping the old zoom would open the
  /// preview cropped into the middle of a different image.
  void _resetStageZoom() {
    if (_stageScale == 1 && _stageOffset == Offset.zero) return;
    setState(() {
      _stageScale = 1;
      _stageOffset = Offset.zero;
    });
  }

  void _setWatermarkDragging(bool value) {
    if (_draggingWatermark == value || !mounted) return;
    setState(() => _draggingWatermark = value);
  }

  /// The watermark at a preset anchor.
  ///
  /// The anchor maths is duplicated here rather than shared with
  /// [commands.watermarkPositionParts] on purpose: that one produces an
  /// ffmpeg EXPRESSION string, and parsing a string back into numbers to
  /// place a widget would be a second source of truth. The table is small
  /// and both are covered by tests.
  Widget _buildAnchoredWatermark(_WatermarkLayer layer) {
    final anchor = layer.placement.anchor;
    if (anchor == null) return const SizedBox.shrink();
    const margin = 10.0;
    // Fractions of the frame, 0..1, for the watermark's centre.
    double fx;
    double fy;
    switch (anchor) {
      case WatermarkPosition.topLeft:
        fx = 0;
        fy = 0;
        break;
      case WatermarkPosition.topCenter:
        fx = 0.5;
        fy = 0;
        break;
      case WatermarkPosition.topRight:
        fx = 1;
        fy = 0;
        break;
      case WatermarkPosition.centerLeft:
        fx = 0;
        fy = 0.5;
        break;
      case WatermarkPosition.center:
        fx = 0.5;
        fy = 0.5;
        break;
      case WatermarkPosition.centerRight:
        fx = 1;
        fy = 0.5;
        break;
      case WatermarkPosition.bottomLeft:
        fx = 0;
        fy = 1;
        break;
      case WatermarkPosition.bottomCenter:
        fx = 0.5;
        fy = 1;
        break;
      case WatermarkPosition.bottomRight:
        fx = 1;
        fy = 1;
        break;
    }
    // Anchors describe the watermark's EDGE, so the centre is inset by the
    // margin and by half the watermark's own size.
    final wmSize = layer.size;
    final frameW = _previewSize.width;
    final frameH = _previewSize.height;
    if (wmSize != null && frameW > 0 && frameH > 0) {
      final insetX = (margin + wmSize.width / 2) / frameW;
      final insetY = (margin + wmSize.height / 2) / frameH;
      fx = fx == 0 ? insetX : (fx == 1 ? 1 - insetX : fx);
      fy = fy == 0 ? insetY : (fy == 1 ? 1 - insetY : fy);
    }
    return Align(
      alignment: Alignment(fx * 2 - 1, fy * 2 - 1),
      child: KeyedSubtree(key: layer.key, child: _buildWatermarkWidget(layer)),
    );
  }

  /// Move the selected watermark to a new centre fraction, clamped so it
  /// stays inside the frame.
  void _setFreePlacement(double fx, double fy) {
    final p = clampWatermarkCenter(fx, fy, _layer.size, _previewSize);
    setState(() {
      _placement = WatermarkPlacement.free(p.dx, p.dy);
    });
  }

  /// One watermark at PREVIEW resolution.
  Widget _buildWatermarkWidget(_WatermarkLayer layer) {
    switch (layer.type) {
      case _WatermarkType.text:
        final text = layer.textController.text;
        if (text.trim().isEmpty) return const SizedBox.shrink();
        return Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: layer.font.flutterFamily,
            fontSize: _fontSizePxFor(layer) * _previewScale,
            color: _textColorFor(layer).withValues(alpha: layer.opacity),
            height: 1.2,
          ),
        );
      case _WatermarkType.image:
      case _WatermarkType.gif:
        final path = layer.mediaPath;
        if (path == null) return const SizedBox.shrink();
        return Image.file(
          File(path),
          width: _watermarkWidthPxFor(layer) * _previewScale,
          opacity: AlwaysStoppedAnimation(layer.opacity),
          errorBuilder: (context, error, stack) =>
              const Icon(Icons.broken_image_outlined),
        );
    }
  }

  // ---------------------------------------------------------------------
  // Controls
  // ---------------------------------------------------------------------

  Widget _buildControlPanel() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _buildSourceCard(),
        const SizedBox(height: 16),
        _buildLayerList(),
        const SizedBox(height: 16),
        _buildTypeRow(),
        const SizedBox(height: 16),
        if (_type == _WatermarkType.text) ...[
          _buildTextSection(),
          const SizedBox(height: 16),
        ] else ...[
          _buildImageSection(),
          const SizedBox(height: 16),
        ],
        _buildPositionSection(),
        const SizedBox(height: 16),
        _buildOpacitySection(),
        if (_formatChoices.isNotEmpty) ...[
          const SizedBox(height: 16),
          OutputFormatPicker(
            key: const Key('wm_format'),
            formats: _formatChoices,
            selected: _activeFormat!,
            common: switch (_outputKind) {
              WatermarkMediaKind.video => const [
                  'mp4_h264',
                  'mp4_h265',
                  'webm_vp9'
                ],
              WatermarkMediaKind.gif => const ['gif', 'apng'],
              WatermarkMediaKind.image => const ['png', 'jpg', 'webp'],
            },
            onSelected: (f) => setState(() => _outputFormat = f),
          ),
        ],
        const SizedBox(height: 20),
        if (_applying)
          ExportProgress(
            progress: _progress,
            label: '正在处理…',
            accent: _accent,
            onColor: _on,
            onCancel: _cancelApply,
          )
        else
          RainbowGlow(
            child: ElevatedButton.icon(
              key: const Key('wm_apply'),
              onPressed: _canApply ? _apply : null,
              icon: const Icon(Icons.branding_watermark),
              label: const Text('添加水印'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: _on,
                disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                disabledForegroundColor: _accent.withValues(alpha: 0.55),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
        if (_outputPath != null) _buildResult(),
      ],
    );
  }

  /// The layer list: what is on the picture, and what the panel below edits.
  ///
  /// This is where "add another one" lives. The old screen could only ever
  /// hold one watermark, so the only action left after picking a file was
  /// 「更换」 -- there was nowhere for a second one to go.
  Widget _buildLayerList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('水印', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text(
              '${_layers.length}/$_maxLayers',
              style: const TextStyle(color: Neutrals.inkSoft, fontSize: 12),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('wm_add_layer'),
              onPressed: _layers.length >= _maxLayers ? null : _addLayer,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('继续添加'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _layers.length; i++) _buildLayerChip(i),
          ],
        ),
      ],
    );
  }

  Widget _buildLayerChip(int index) {
    final layer = _layers[index];
    final selected = index == _selected;
    final label = layer.chipLabel(_typeLabelFor(layer.type));
    return Material(
      color: selected ? _accent.withValues(alpha: 0.12) : Neutrals.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: Key('wm_layer_chip_$index'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _selectLayer(index),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? _accent : Neutrals.line,
              width: selected ? 1.6 : 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                switch (layer.type) {
                  _WatermarkType.text => Icons.text_fields,
                  _WatermarkType.image => Icons.image_outlined,
                  _WatermarkType.gif => Icons.gif,
                },
                size: 15,
                color: selected ? _accent : Neutrals.inkSoft,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 108),
                child: Text(
                  '${_indexSuffix(index)} $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? _accent : Neutrals.ink,
                  ),
                ),
              ),
              if (_layers.length > 1)
                InkWell(
                  key: Key('wm_remove_layer_$index'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _removeLayer(index),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 14, color: Neutrals.inkSoft),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _indexSuffix(int index) =>
      String.fromCharCode(0x2460 + index.clamp(0, 9));

  String _typeLabelFor(_WatermarkType type) {
    switch (type) {
      case _WatermarkType.text:
        return '文字';
      case _WatermarkType.image:
        return '图片';
      case _WatermarkType.gif:
        return 'GIF';
    }
  }

  Widget _buildSourceCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _previewThumb(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _kindLabel(_kind),
                          style: const TextStyle(
                            color: _accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (_sourceSize != null)
                        Text(
                          '${_sourceSize!.$1}×${_sourceSize!.$2}',
                          style: const TextStyle(
                              color: Neutrals.inkSoft, fontSize: 11),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatBytes(_inputBytes),
                    style: const TextStyle(color: Neutrals.inkSoft),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: _pickMedia, child: const Text('更换')),
          ],
        ),
      ),
    );
  }

  Widget _previewThumb() {
    final path = _inputPath;
    if (path == null) return const SizedBox.shrink();
    if (_kind == WatermarkMediaKind.video && _sourceFramePath != null) {
      return Image.file(File(_sourceFramePath!),
          height: 56, width: 56, fit: BoxFit.cover);
    }
    return Image.file(File(path), height: 56, width: 56, fit: BoxFit.cover);
  }

  Widget _buildTypeRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('水印类型', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildTypeOption(
              icon: Icons.text_fields,
              label: '文字',
              selected: _type == _WatermarkType.text,
              onTap: () => setState(() => _type = _WatermarkType.text),
            ),
            const SizedBox(width: 8),
            _buildTypeOption(
              icon: Icons.image_outlined,
              label: '图片',
              selected: _type == _WatermarkType.image,
              onTap: () => setState(() => _type = _WatermarkType.image),
            ),
            const SizedBox(width: 8),
            _buildTypeOption(
              icon: Icons.gif,
              label: 'GIF',
              selected: _type == _WatermarkType.gif,
              onTap: () => setState(() => _type = _WatermarkType.gif),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTypeOption({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: selected ? _accent.withValues(alpha: 0.12) : Neutrals.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? _accent : Neutrals.line,
                width: selected ? 1.6 : 1.2,
              ),
            ),
            child: Column(
              children: [
                Icon(icon,
                    color: selected ? _accent : Neutrals.inkSoft, size: 20),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: selected ? _accent : Neutrals.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('水印文字', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          key: const Key('wm_text_field'),
          controller: _textController,
          // The controller belongs to the layer, not to this widget, so a
          // listener would have to be moved on every selection change; the
          // field's own callback is the simpler seam.
          onChanged: (_) => _onParametersChanged(),
          maxLines: 2,
          minLines: 1,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: '输入要叠加的文字',
            prefixIcon: Icon(Icons.edit_outlined),
          ),
        ),
        const SizedBox(height: 16),
        _buildFontRow(),
        const SizedBox(height: 12),
        _buildSlider(
          label: '文字大小',
          valueLabel: '${_textSizePercent.round()}%  ·  ${_fontSizePx}px',
          value: _textSizePercent,
          min: 2,
          max: 20,
          onChanged: (v) => setState(() => _textSizePercent = v),
        ),
        const SizedBox(height: 12),
        const Text('颜色', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _textColors.length; i++) _buildColorSwatch(i),
            _buildCustomColorSwatch(),
          ],
        ),
        if (ColorPresetStore.instance.colors.isNotEmpty) ...[
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: ColorPresetStore.instance,
            builder: (context, _) => SavedColorRow(
              colors: ColorPresetStore.instance.colors,
              current: _textColorFor(_layer),
              onPick: (c) => setState(() => _colorValue = c.toARGB32()),
            ),
          ),
        ],
      ],
    );
  }

  /// The font presets.
  ///
  /// RE: the previous implementation ships no font and makes the user import one
  /// works on first launch. Only OFL-licensed faces are bundled.
  /// Opens the colour wheel; the result also becomes a saveable preset.
  Widget _buildCustomColorSwatch() {
    final isCustom = !_textColors.any((e) => e.$2.toARGB32() == _colorValue);
    return GestureDetector(
      key: const Key('wm_custom_color'),
      onTap: () async {
        final picked = await showColorPickerDialog(
          context,
          initial: _textColorFor(_layer),
          title: '水印颜色',
        );
        if (picked == null || !mounted) return;
        setState(() => _colorValue = picked.toARGB32());
      },
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isCustom ? _accent : Neutrals.line,
            width: isCustom ? 3 : 1.2,
          ),
          gradient: const SweepGradient(
            colors: [
              Color(0xFFFF5252),
              Color(0xFFFFD740),
              Color(0xFF69F0AE),
              Color(0xFF40C4FF),
              Color(0xFF7C4DFF),
              Color(0xFFFF5252),
            ],
          ),
        ),
        child: isCustom
            ? null
            : const Icon(Icons.add, size: 16, color: Colors.white),
      ),
    );
  }

  Widget _buildFontRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('字体', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final font in watermarkFonts)
              ChoiceChip(
                label: Text(font.label),
                selected: _font.id == font.id,
                onSelected: (_) => setState(() => _font = font),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildColorSwatch(int index) {
    final (name, color) = _textColors[index];
    final selected = color.toARGB32() == _colorValue;
    return GestureDetector(
      onTap: () => setState(() => _colorValue = color.toARGB32()),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? _accent : Neutrals.line,
            width: selected ? 3 : 1.2,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 18,
                color: color.computeLuminance() > 0.5
                    ? Colors.black87
                    : Colors.white,
              )
            : null,
      ),
    );
  }

  Widget _buildImageSection() {
    final wm = _watermarkImagePath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_type == _WatermarkType.gif ? 'GIF 水印' : '水印图片',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (wm == null)
          OutlinedButton.icon(
            onPressed: _pickWatermarkImage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_type == _WatermarkType.gif ? '选择 GIF' : '选择图片'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(wm),
                        height: 48, width: 48, fit: BoxFit.contain),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      File(wm).uri.pathSegments.last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Neutrals.inkSoft),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickWatermarkImage,
                    child: const Text('更换'),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        _buildSlider(
          label: '水印宽度',
          valueLabel:
              '${_imageWidthPercent.round()}%  ·  ${_watermarkWidthPx}px',
          value: _imageWidthPercent,
          min: 5,
          max: 60,
          onChanged: (v) => setState(() => _imageWidthPercent = v),
        ),
      ],
    );
  }

  /// The nine position anchors.
  ///
  /// x/y fragments they are assembled from.
  ///
  /// Tapping one snaps the watermark there; dragging the preview switches
  /// to a free position, and no chip stays selected -- which is the honest
  /// signal that the watermark is no longer on a preset.
  Widget _buildPositionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('位置', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            if (_placement.isFree)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '自由',
                  style: TextStyle(
                      color: _accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _buildPositionRow([
          (WatermarkPosition.topLeft, Icons.keyboard_double_arrow_left),
          (WatermarkPosition.topCenter, Icons.keyboard_arrow_up),
          (WatermarkPosition.topRight, Icons.keyboard_double_arrow_right),
        ]),
        const SizedBox(height: 8),
        _buildPositionRow([
          (WatermarkPosition.centerLeft, Icons.keyboard_arrow_left),
          (WatermarkPosition.center, Icons.adjust),
          (WatermarkPosition.centerRight, Icons.keyboard_arrow_right),
        ]),
        const SizedBox(height: 8),
        _buildPositionRow([
          (WatermarkPosition.bottomLeft, Icons.keyboard_double_arrow_left),
          (WatermarkPosition.bottomCenter, Icons.keyboard_arrow_down),
          (WatermarkPosition.bottomRight, Icons.keyboard_double_arrow_right),
        ]),
      ],
    );
  }

  Widget _buildPositionRow(List<(WatermarkPosition, IconData)> cells) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Neutrals.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Neutrals.line),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final (position, icon) in cells)
            _buildPositionCell(position, icon),
        ],
      ),
    );
  }

  Widget _buildPositionCell(WatermarkPosition position, IconData icon) {
    final selected = !_placement.isFree && _placement.anchor == position;
    return Material(
      color: selected ? _accent : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          _placement = WatermarkPlacement.anchor(position);
        }),
        child: SizedBox(
          width: 52,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: selected ? _on : Neutrals.inkSoft,
          ),
        ),
      ),
    );
  }

  Widget _buildOpacitySection() {
    return _buildSlider(
      label: '透明度',
      valueLabel: '${(_opacity * 100).round()}%',
      value: _opacity,
      min: 0.05,
      max: 1.0,
      onChanged: (v) => setState(() => _opacity = v),
    );
  }

  Widget _buildSlider({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              valueLabel,
              style: const TextStyle(
                color: _accent,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildResult() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Text('完成', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _previewThumb(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _layers.length > 1
                            ? '水印已添加（${_layers.length} 层）'
                            : '$_typeLabel 水印已添加',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatBytes(_outputBytes ?? 0),
                        style: const TextStyle(color: Neutrals.inkSoft),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: RainbowGlow(
                  child: ElevatedButton.icon(
                onPressed: _saving ? null : _saveToGallery,
                icon: const Icon(Icons.save_alt),
                label: Text(_saving ? '保存中…' : '存到相册'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: _on,
                  disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                  disabledForegroundColor: _accent.withValues(alpha: 0.55),
                ),
              )),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.share),
                label: const Text('分享'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                key: const Key('wm_next_source'),
                onPressed: _applying ? null : _continueWithNext,
                icon: const Icon(Icons.skip_next),
                label: const Text('继续下一个（保留水印）'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _reset, child: const Text('清空重来')),
          ],
        ),
      ],
    );
  }
}

/// One watermark the user has assembled.
///
/// Owns its text controller and its measurement key, because both have to
/// survive the panel switching to another layer: the controller holds the
/// text and the cursor, the key is what [_measure] reads the preview size
/// from.
class _WatermarkLayer {
  _WatermarkLayer({
    required this.type,
    this.font = defaultWatermarkFont,
    this.colorValue = 0xFFFFFFFF,
    this.textSizePercent = 6,
    this.imageWidthPercent = 20,
    this.opacity = 1.0,
    String text = '',
  }) : textController = TextEditingController(text: text);

  _WatermarkType type;
  WatermarkFont font;

  /// ARGB value; the swatches write it, the picker can write anything.
  int colorValue;
  double textSizePercent;
  double imageWidthPercent;
  double opacity;

  /// Starts on a preset anchor; a drag turns it into a free position.
  WatermarkPlacement placement =
      const WatermarkPlacement.anchor(WatermarkPosition.bottomRight);

  String? mediaPath;
  final TextEditingController textController;

  /// Measures this layer's widget in the preview.
  final GlobalKey key = GlobalKey();

  /// This layer's size in the preview, in pixels; null until measured.
  Size? size;

  /// Whether this layer has anything to draw.
  bool get hasContent {
    switch (type) {
      case _WatermarkType.text:
        return textController.text.trim().isNotEmpty;
      case _WatermarkType.image:
      case _WatermarkType.gif:
        return mediaPath != null;
    }
  }

  /// A short name for the layer chip.
  String chipLabel(String typeLabel) {
    switch (type) {
      case _WatermarkType.text:
        final text = textController.text.trim();
        return text.isEmpty ? '$typeLabel（空）' : text;
      case _WatermarkType.image:
      case _WatermarkType.gif:
        final path = mediaPath;
        if (path == null) return '$typeLabel（未选）';
        return File(path).uri.pathSegments.last;
    }
  }

  void dispose() => textController.dispose();
}
