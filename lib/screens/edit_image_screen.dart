// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:math' as math;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, PlatformException;
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../ffmpeg/commands.dart'
    show
        EditImageAdjust,
        EditImageCropRect,
        EditImageGeometry,
        ImageCompressionMode,
        ImageCompressionPlan,
        ImageCompressionResult,
        compressionTargetPending,
        editImagePresetPreviewMatrix;
import '../services/edit_image_service.dart';
import '../services/ffmpeg_progress.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/export_progress.dart';
import '../ui/zoomable_image.dart';
import '../ui/rainbow_glow.dart';
import '../utils/image_reader.dart' as ir;

/// One committed (or initial) edit state plus the files that realize it.
///
/// Every apply runs the WHOLE state against the previous implementation file and produces
/// a fresh output + 1080-wide preview, so undo/redo only ever swaps files --
/// no incremental re-processing, no JPEG generation loss.
class _Snapshot {
  _Snapshot({
    required this.state,
    required this.previewPath,
    required this.previewInfo,
  });

  final _EditState state;
  final String previewPath;
  final ir.ImageInfo? previewInfo;
  String? outputPath;
  int? outputBytes;
  ir.ImageInfo? outputInfo;

  /// Set when this output came from a compression run, so the result card can
  /// report the quality/width that was accepted and whether the target was hit.
  ImageCompressionResult? compression;
}

/// Accumulated edit state, expressed against the ORIGINAL image.
class _EditState {
  _EditState({
    this.quarterTurns = 0,
    this.flipH = false,
    this.flipV = false,
    this.crop,
    this.scaleWidth,
    this.adjust = const EditImageAdjust(),
    this.preset = 'none',
    this.presetStrength = 100,
  });

  /// Total clockwise 90-degree steps (0..3).
  int quarterTurns;
  bool flipH;
  bool flipV;

  /// Crop window in ORIGINAL-image pixels.
  EditImageCropRect? crop;

  /// Output width in px (post-crop frame); null keeps the size.
  int? scaleWidth;

  /// Color/detail adjustments, expressed against the ORIGINAL image.
  EditImageAdjust adjust;

  /// Style preset code ('none' or one of the builder's preset ids) and the
  /// strength it runs at (0..100).
  String preset;
  int presetStrength;

  _EditState copy() => _EditState(
        quarterTurns: quarterTurns,
        flipH: flipH,
        flipV: flipV,
        crop: crop,
        scaleWidth: scaleWidth,
        adjust: adjust,
        preset: preset,
        presetStrength: presetStrength,
      );

  bool sameGeometryAs(_EditState o) =>
      quarterTurns == o.quarterTurns &&
      flipH == o.flipH &&
      flipV == o.flipV &&
      scaleWidth == o.scaleWidth &&
      ((crop == null) == (o.crop == null)) &&
      (crop == null ||
          (crop!.x == o.crop!.x &&
              crop!.y == o.crop!.y &&
              crop!.width == o.crop!.width &&
              crop!.height == o.crop!.height));
}

class EditImageScreen extends StatefulWidget {
  /// [initialImagePath] is a test seam: it loads an image without going
  /// through the system photo picker, which is not drivable from a widget
  /// test. The app never passes it.
  const EditImageScreen({super.key, this.initialImagePath});

  /// Test-only: an image to load on first build.
  @visibleForTesting
  final String? initialImagePath;

  @override
  State<EditImageScreen> createState() => _EditImageScreenState();
}

class _EditImageScreenState extends State<EditImageScreen> {
  @override
  void initState() {
    super.initState();
    final path = widget.initialImagePath;
    if (path != null) {
      // Test seam: load the image directly instead of through the picker.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadImage(path));
    }
  }

  static const _accent = FeatureColors.editImage;
  static const _on = FeatureColors.editImageOn;
  static const _bg = Neutrals.bg;
  static const _historyCap = 30;
  static const _scalePresets = <int?>[null, 1920, 1280, 1080, 800, 640, 320];
  static const _ratioPresets = <String, double?>{
    '自由': null,
    '1:1': 1,
    '4:3': 4 / 3,
    '3:4': 3 / 4,
    '16:9': 16 / 9,
    '9:16': 9 / 16,
  };

  final _service = EditImageService(workDir: Directory.systemTemp.path);

  String? _origPath;
  ir.ImageInfo? _srcInfo;
  int _srcBytes = 0;

  final List<_Snapshot> _history = [];
  int _index = -1;
  _EditState _draft = _EditState();

  // Format selection. 'auto' keeps the source format.
  String _format = 'auto';
  int _jpegQuality = 2;

  // Compression: 0 = off. Otherwise a target byte count the apply step hunts
  // for by re-encoding at lower quality (and, if allowed, narrower widths).
  int _compressTarget = 0;
  bool _compressAllowScale = true;
  String _compressNote = '';
  int _compressAttempt = 0;
  int _compressMax = 0;
  int _compressBytes = 0;

  /// Free-form target in KB, used by the "自定义" chip. The preset chips cover
  /// the everyday cases (100 KB .. 2 MB); this is for anything below them --
  /// which is also the only way to reach the width ladder, since q=31 at the
  /// source width still beats 100 KB on most photos.
  final TextEditingController _customKbController = TextEditingController();
  bool _customTargetActive = false;

  /// Target the current committed output was produced with, so changing only
  /// the compression target still counts as a pending edit.
  /// Target this image has already been compressed to; null = nothing has
  /// been applied to the current image yet. Must stay nullable: 0 is a real
  /// target ("不压缩"), so it cannot double as the "nothing applied" marker.
  int? _appliedCompressTarget;

  bool _applying = false;

  /// Stop the running apply.
  void _cancelApply() => _job?.cancel();

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  bool _showOriginal = false;
  String? _error;

  /// True while a slider is being dragged. While dragging, the control
  /// panel collapses so the pinned preview keeps the whole screen and
  /// the slider under the finger stays visible (see [build]).
  bool _dragging = false;

  /// Label of the slider currently being dragged, shown in the drag bar.
  String? _dragLabel;

  // Crop mode: rect normalized to the DISPLAYED (rotated/flipped) image.
  bool _cropping = false;
  Rect _cropRect = const Rect.fromLTWH(0, 0, 1, 1);
  double? _ratioLock;
  String? _cropLabel = '自由';
  _DragMode? _dragMode;
  _Corner? _dragCorner;
  Offset _dragStart = Offset.zero;
  Rect _rectStart = Rect.zero;

  // Displayed image pixel size inside the crop overlay, for aspect math.
  double _dispW = 1;
  double _dispH = 1;

  @override
  void dispose() {
    _customKbController.dispose();
    super.dispose();
  }

  /// Byte count the free-form KB field currently describes, or null when it is
  /// empty / not a usable number. Clamped to at least 1 KB: a 0-byte target
  /// would make the compressor walk every rung and every width for nothing.
  int? get _customTargetBytes {
    final kb = int.tryParse(_customKbController.text.trim());
    if (kb == null || kb <= 0) return null;
    return kb * 1024;
  }

  bool get _canUndo => _index > 0;
  bool get _canRedo => _index < _history.length - 1;
  bool get _dirty =>
      !_draft.sameGeometryAs(
          _history.isEmpty ? _EditState() : _history[_index].state) ||
      !_sameAdjust(_draft.adjust, _snap.state.adjust) ||
      _draft.preset != _snap.state.preset ||
      _draft.presetStrength != _snap.state.presetStrength ||
      compressionTargetPending(_compressTarget, _appliedCompressTarget);

  bool _sameAdjust(EditImageAdjust a, EditImageAdjust b) =>
      a.brightness == b.brightness &&
      a.contrast == b.contrast &&
      a.saturation == b.saturation &&
      a.hue == b.hue &&
      a.sharpen == b.sharpen &&
      a.blur == b.blur &&
      a.temperature == b.temperature &&
      a.shadows == b.shadows &&
      a.midtones == b.midtones &&
      a.highlights == b.highlights;

  _Snapshot get _snap => _history[_index];

  String get _resolvedFormat {
    if (_format == 'auto') {
      return (_srcInfo?.format == 'png') ? 'png' : 'jpg';
    }
    return _format;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _loadImage(picked.path);
    } on PlatformException catch (e) {
      // The Android side fails with `no_valid_image_uri` when
      // ContentResolver cannot serve the picked item (see FileUtils
      // .getPathFromUri, which returns null on a null stream / IOException /
      // SecurityException). Say so instead of dumping a raw PlatformException.
      final hint = e.code == 'no_valid_image_uri'
          ? '系统相册返回的图像无法读取，可能是云端照片尚未下载完成，或该图片已被删除'
              '（可先在相册中打开并下载该图片后重试）'
          : e.message ?? e.code;
      setState(() => _error = '选择图片失败: $hint');
    } catch (e) {
      setState(() => _error = '选择图片失败: $e');
    }
  }

  /// Load [path] as the working image: read its metadata, build the preview
  /// and reset every editing control to the state a fresh pick means.
  ///
  /// Shared by the picker path and the test seam, so a test exercises the
  /// same code the app runs.
  Future<void> _loadImage(String path) async {
    try {
      // image_picker resolves the gallery Uri to a real path in Java before
      // handing it over, and answers `no_valid_image_uri` when it cannot.
      // Surface what we actually got so a failure is diagnosable instead of
      // just "选择图片失败".
      final pickedFile = File(path);
      if (!pickedFile.existsSync()) {
        setState(() => _error = '图片无法读取（路径不存在）: $path');
        return;
      }
      final bytes = await pickedFile.readAsBytes();
      final info = ir.ImageReader.parse(bytes);
      final preview = await _service.makePreview(path);
      final previewInfo =
          ir.ImageReader.parse(await File(preview).readAsBytes());
      if (!mounted) return;
      setState(() {
        _origPath = path;
        _srcInfo = info;
        _srcBytes = bytes.length;
        _history
          ..clear()
          ..add(_Snapshot(
            state: _EditState(),
            previewPath: preview,
            previewInfo: previewInfo,
          ));
        _index = 0;
        _draft = _EditState();
        _cropping = false;
        _error = null;
        _compressNote = '';
        // Nothing has been applied to the new image yet. Critically this does
        // NOT inherit _compressTarget: the target persists across picks, so
        // copying it would mark the fresh image as already-compressed and grey
        // out the apply button -- the exact flow compression exists for (pick
        // a big photo, change nothing, hit compress).
        _appliedCompressTarget = null;
        // The custom KB field describes the previous image's intent; drop it so
        // a stale number cannot silently drive the next compression.
        _customKbController.clear();
        _customTargetActive = false;
      });
    } on ir.ImageParseException catch (e) {
      // The reader only understands PNG and JPEG. HEIC/HEIF is the common case
      // here: Android's picker hands over an iPhone photo quite happily, and
      // the raw failure ("Not a PNG or JPEG stream") tells a user nothing about
      // what to do next. Name the likely formats and the way out.
      setState(() => _error = '暂不支持该图片格式，请先转换为 JPG 或 PNG 再试'
          '（iPhone 的 HEIC/HEIF、WebP、BMP 等暂不支持）\n$e');
    } catch (e) {
      setState(() => _error = '选择图片失败: $e');
    }
  }

  // ---- geometry buttons: mutate the draft; display shows the delta ----

  int get _displayQuarter {
    final d = _draft.quarterTurns - _snap.state.quarterTurns;
    return (d % 4 + 4) % 4;
  }

  bool get _displayFlipH => _draft.flipH != _snap.state.flipH;
  bool get _displayFlipV => _draft.flipV != _snap.state.flipV;

  void _rotate(int delta) {
    setState(() {
      _draft.quarterTurns = (_draft.quarterTurns + delta) % 4;
      if (_draft.quarterTurns < 0) _draft.quarterTurns += 4;
    });
  }

  void _toggleFlip({required bool horizontal}) {
    setState(() {
      if (horizontal) {
        _draft.flipH = !_draft.flipH;
      } else {
        _draft.flipV = !_draft.flipV;
      }
    });
  }

  // ---- adjust sliders: mutate draft; preview shows draft-vs-committed ----

  void _setAdjust({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
    double? sharpen,
    double? blur,
    double? temperature,
    double? shadows,
    double? midtones,
    double? highlights,
  }) {
    final a = _draft.adjust;
    setState(() {
      _draft.adjust = EditImageAdjust(
        brightness: brightness?.roundToDouble() ?? a.brightness,
        contrast: contrast?.roundToDouble() ?? a.contrast,
        saturation: saturation?.roundToDouble() ?? a.saturation,
        hue: hue?.roundToDouble() ?? a.hue,
        sharpen:
            sharpen != null ? (sharpen * 10).roundToDouble() / 10 : a.sharpen,
        blur: blur != null ? (blur * 10).roundToDouble() / 10 : a.blur,
        temperature: temperature?.roundToDouble() ?? a.temperature,
        shadows: shadows?.roundToDouble() ?? a.shadows,
        midtones: midtones?.roundToDouble() ?? a.midtones,
        highlights: highlights?.roundToDouble() ?? a.highlights,
      );
    });
  }

  /// GPU preview color filter for the PENDING delta (draft minus committed).
  ///
  /// The committed adjustments are already baked into the preview file, so the
  /// live filter only has to realize the remaining difference: hue rotations
  /// compose additively, saturation ratios multiply, and contrast/brightness
  /// collapse to one scale + translation. Built in ColorFilter.matrix's
  /// 0..255 space with sRGB luminance coefficients; approximate by design --
  /// the ffmpeg output is authoritative.
  ColorFilter? _previewColorFilter() {
    final a = _draft.adjust;
    final c = _snap.state.adjust;
    final presets = _previewPresetMatrices();
    final sameColor = a.brightness == c.brightness &&
        a.contrast == c.contrast &&
        a.saturation == c.saturation &&
        a.hue == c.hue &&
        a.temperature == c.temperature;
    if (sameColor && presets == null) return null;

    // Compose the draft-side and committed-side transforms separately, then
    // emit the matrix that maps the already-committed preview file to the
    // draft look: (D - I) applied on top of the committed pixels is what
    // ColorFilter can express, so we build D * C^-1 for the linear part and
    // carry the translation through the same way.
    final kC = 1 + c.contrast / 100;
    final kD = 1 + a.contrast / 100;
    final tC = 255 * c.brightness / 100 + 128 * (1 - kC);
    final tD = 255 * a.brightness / 100 + 128 * (1 - kD);
    final kRatio = kC <= 0.01 ? kD : kD / kC;
    final vRatio = c.saturation <= 0
        ? a.saturation / 100
        : a.saturation / 100 / (c.saturation / 100);

    var m = _hueMatrix((a.hue - c.hue) * math.pi / 180);
    m = _mat3Mul(m, _saturationMatrix(vRatio));
    m = _mat3Scale(m, kRatio);
    // ffmpeg temperature is per-channel gamma (non-linear); a linear R/B
    // gain is the closest 4x5-matrix stand-in.
    final dt = (a.temperature - c.temperature) / 100;
    m = _mat3Mul(m, [
      [1 + 0.25 * dt, 0, 0],
      [0, 1, 0],
      [0, 0, 1 - 0.25 * dt],
    ]);
    var t = tD - kRatio * tC;

    // Style preset sits AFTER hue in the ffmpeg chain
    // (editImageTransform: eq -> hue -> preset filters -> colorbalance), so it
    // multiplies on the left. Both sides go through the same composition; what
    // reaches ColorFilter is the draft preset relative to the committed one.
    if (presets != null) {
      const identity3 = <List<double>>[
        [1, 0, 0],
        [0, 1, 0],
        [0, 0, 1],
      ];
      final inv = _invert3(presets.committed) ?? identity3;
      m = _mat3Mul(presets.draft, _mat3Mul(inv, m));
      t = t + presets.draftPivot - presets.committedPivot;
    }

    return ColorFilter.matrix(<double>[
      m[0][0],
      m[0][1],
      m[0][2],
      0,
      t,
      m[1][0],
      m[1][1],
      m[1][2],
      0,
      t,
      m[2][0],
      m[2][1],
      m[2][2],
      0,
      t,
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  /// Inverse of a 3x3 matrix, or null when it is singular (which happens when a
  /// preset is driven to full strength, e.g. bw's saturation collapses to a
  /// zero row). The caller falls back to identity in that case -- the preview
  /// then shows the draft preset's own matrix rather than nothing.
  static List<List<double>>? _invert3(List<List<double>> m) {
    final a = m[0][0], b = m[0][1], c = m[0][2];
    final d = m[1][0], e = m[1][1], f = m[1][2];
    final g = m[2][0], h = m[2][1], i = m[2][2];
    final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (det.abs() < 1e-9) return null;
    final inv = 1 / det;
    return [
      [(e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv],
      [(f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv],
      [(d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv],
    ];
  }

  /// Gaussian blur is representable on the GPU, but not invertible -- extra
  /// sigma on top of what the committed file already has is the closest
  /// approximation.
  double _previewBlurSigma() {
    final delta = _draft.adjust.blur - _snap.state.adjust.blur;
    return delta > 0 ? delta : 0;
  }

  static const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

  List<List<double>> _saturationMatrix(double v) {
    final r = (1 - v) * _lr, g = (1 - v) * _lg, b = (1 - v) * _lb;
    return [
      [r + v, g, b],
      [r, g + v, b],
      [r, g, b + v],
    ];
  }

  /// Rotation about the grey axis that preserves the sRGB luma of each pixel.
  List<List<double>> _hueMatrix(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    final u = 1 / math.sqrt(3);
    const lr = _lr, lg = _lg, lb = _lb;
    return [
      [
        lr * (1 - c) + c - u * s * (lg - lb),
        lg * (1 - c) - u * s * (1 + lb - lr),
        lb * (1 - c) + u * s * (1 - lr + lg),
      ],
      [
        lr * (1 - c) + u * s * (1 - lg + lb),
        lg * (1 - c) + c - u * s * (lb - lr),
        lb * (1 - c) - u * s * (1 + lr - lg),
      ],
      [
        lr * (1 - c) - u * s * (1 + lg - lb),
        lg * (1 - c) + u * s * (1 - lb + lr),
        lb * (1 - c) + c - u * s * (lr - lg),
      ],
    ];
  }

  List<List<double>> _mat3Mul(List<List<double>> a, List<List<double>> b) {
    return [
      for (var i = 0; i < 3; i++)
        [
          for (var j = 0; j < 3; j++)
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j]
        ],
    ];
  }

  List<List<double>> _mat3Scale(List<List<double>> m, double k) => [
        for (final row in m) [for (final v in row) v * k]
      ];

  /// 3x3 block of a 4x5 Flutter color matrix, as a nested list.
  static List<List<double>> _mat3From44(List<double> m) => [
        [m[0], m[1], m[2]],
        [m[5], m[6], m[7]],
        [m[10], m[11], m[12]],
      ];

  /// Translation column of a 4x5 matrix, in 0..255 space.
  static List<double> _transFrom44(List<double> m) => [m[4], m[9], m[14]];

  /// GPU-preview stand-in for the style preset, or null when the preset has no
  /// matrix equivalent (see commands.dart editImagePresetPreviewMatrix).
  ///
  /// Both sides are returned because the preview file already has the COMMITTED
  /// look baked in: what reaches ColorFilter is draft relative to committed.
  ({
    List<List<double>> draft,
    List<List<double>> committed,
    double draftPivot,
    double committedPivot
  })? _previewPresetMatrices() {
    final draftRaw =
        editImagePresetPreviewMatrix(_draft.preset, _draft.presetStrength);
    final committedRaw = editImagePresetPreviewMatrix(
        _snap.state.preset, _snap.state.presetStrength);
    if (draftRaw == null && committedRaw == null) return null;
    const identity = <List<double>>[
      [1.0, 0, 0],
      [0, 1.0, 0],
      [0, 0, 1.0],
    ];
    final List<List<double>> draftMat =
        draftRaw == null ? identity : _mat3From44(draftRaw);
    final List<List<double>> committedMat =
        committedRaw == null ? identity : _mat3From44(committedRaw);
    return (
      draft: draftMat,
      committed: committedMat,
      // A preset's contrast arm pivots around 128; carry that offset out of the
      // 4x5 so it can be applied to the shared translation column.
      draftPivot: draftRaw == null ? 0 : _transFrom44(draftRaw)[0],
      committedPivot: committedRaw == null ? 0 : _transFrom44(committedRaw)[0],
    );
  }

  // ---- undo / redo / reset ----

  void _undo() {
    if (!_canUndo) return;
    setState(() {
      _index--;
      _draft = _snap.state.copy();
      _cropping = false;
    });
  }

  void _redo() {
    if (!_canRedo) return;
    setState(() {
      _index++;
      _draft = _snap.state.copy();
      _cropping = false;
    });
  }

  void _resetAll() {
    if (_history.isEmpty) return;
    setState(() {
      _index = 0;
      _draft = _EditState();
      _cropping = false;
    });
  }

  // ---- crop mode ----

  void _enterCrop() {
    setState(() {
      _cropping = true;
      _cropRect = const Rect.fromLTWH(0, 0, 1, 1);
      _ratioLock = null;
      _cropLabel = '自由';
    });
  }

  void _cancelCrop() => setState(() => _cropping = false);

  void _setRatio(String label) {
    final r = _ratioPresets[label];
    setState(() {
      _cropLabel = label;
      _ratioLock = r;
      if (r != null) {
        // Re-fit the current rect to the ratio, keeping its center.
        var w = _cropRect.width;
        var h = w * _dispW / (r * _dispH);
        if (h > 1) {
          h = 1;
          w = h * r * _dispH / _dispW;
        }
        final c = _cropRect.center;
        _cropRect = Rect.fromCenter(
          center: c,
          width: w.clamp(0.05, 1),
          height: h.clamp(0.05, 1),
        );
      }
    });
  }

  /// Map a display-space normalized rect back to ORIGINAL-image pixels:
  /// undo the pending delta (rot+flip), undo the committed rotation/flip,
  /// then lift through the committed crop window.
  EditImageCropRect? _cropRectToOriginal() {
    final src = _srcInfo;
    if (src == null || !_cropRect.isValidCrop()) return null;

    var rect = _cropRect;
    rect = _inverseFlipTransform(rect, _displayFlipH, _displayFlipV);
    rect = _inverseRotate(rect, _displayQuarter);

    final committed = _snap.state;
    rect = _inverseFlipTransform(rect, committed.flipH, committed.flipV);
    rect = _inverseRotate(rect, committed.quarterTurns);

    final crop = committed.crop;
    if (crop != null) {
      rect = Rect.fromLTRB(
        crop.x + rect.left * crop.width,
        crop.y + rect.top * crop.height,
        crop.x + rect.right * crop.width,
        crop.y + rect.bottom * crop.height,
      );
      // Back to normalized within the ORIGINAL image.
      rect = Rect.fromLTRB(
        rect.left / src.width,
        rect.top / src.height,
        rect.right / src.width,
        rect.bottom / src.height,
      );
    }

    final left = (rect.left.clamp(0, 1) * src.width).round();
    final top = (rect.top.clamp(0, 1) * src.height).round();
    final right = (rect.right.clamp(0, 1) * src.width).round();
    final bottom = (rect.bottom.clamp(0, 1) * src.height).round();
    final w = right - left;
    final h = bottom - top;
    if (w < 8 || h < 8) return null;
    return EditImageCropRect(x: left, y: top, width: w, height: h);
  }

  Rect _inverseRotate(Rect r, int quarterTurns) {
    // Forward (u,v) -> q=1: (1-v,u); q=2: (1-u,1-v); q=3: (v,1-u).
    switch (quarterTurns) {
      case 1:
        return Rect.fromLTRB(1 - r.bottom, r.left, 1 - r.top, r.right);
      case 2:
        return Rect.fromLTRB(1 - r.right, 1 - r.bottom, 1 - r.left, 1 - r.top);
      case 3:
        return Rect.fromLTRB(r.top, 1 - r.right, r.bottom, 1 - r.left);
      default:
        return r;
    }
  }

  Rect _inverseFlipTransform(Rect r, bool flipH, bool flipV) {
    var left = r.left;
    var right = r.right;
    var top = r.top;
    var bottom = r.bottom;
    if (flipH) {
      final nl = 1 - right;
      right = 1 - left;
      left = nl;
    }
    if (flipV) {
      final nt = 1 - bottom;
      bottom = 1 - top;
      top = nt;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Future<void> _finishCrop() async {
    final crop = _cropRectToOriginal();
    if (crop == null) {
      setState(() {
        _cropping = false;
        _draft.crop = null;
      });
      return;
    }
    setState(() {
      _cropping = false;
      _draft.crop = crop;
    });
    await _apply();
  }

  // ---- apply / save / share ----

  Future<void> _apply() async {
    final orig = _origPath;
    if (orig == null || _applying) return;
    setState(() {
      _applying = true;
      _progress = 0;
      _job = null;
      _error = null;
    });
    try {
      final state = _draft.copy();
      final geometry = EditImageGeometry(
        quarterTurns: state.quarterTurns,
        flipH: state.flipH,
        flipV: state.flipV,
        scaleWidth: state.scaleWidth,
        crop: state.crop,
      );
      final String out;
      final String preview;
      ImageCompressionResult? comp;
      setState(() {
        _compressNote = '';
        _compressAttempt = 0;
        _compressMax = 0;
        _compressBytes = 0;
      });
      if (_compressTarget > 0 && _resolvedFormat == 'jpg') {
        // Compression replaces the plain encode: each attempt re-runs the whole
        // chain against the previous implementation, so this never stacks JPEG generations.
        // Every attempt is a separate encode by definition (the size IS the
        // measurement), so this path cannot use the combined builder.
        final r = await _service.compress(
          inputPath: orig,
          plan: ImageCompressionPlan(
            targetBytes: _compressTarget,
            quality: _jpegQuality,
            maxWidth: state.scaleWidth,
            mode: _compressAllowScale
                ? ImageCompressionMode.qualityThenScale
                : ImageCompressionMode.qualityOnly,
          ),
          geometry: geometry,
          adjust: state.adjust,
          preset: state.preset,
          presetStrength: state.presetStrength,
          format: _resolvedFormat,
          onProgress: (i, max, bytes) {
            if (!mounted) return;
            setState(() {
              _compressAttempt = i;
              _compressMax = max;
              _compressBytes = bytes;
            });
          },
        );
        out = r.path;
        comp = r;
        preview = await _service.makePreview(out);
      } else {
        // No size target: the result and the display copy come out of ONE
        // ffmpeg pass. This is the common path (plain edits, format flips) and
        // it is where the second decode used to double the apply time.
        final r = await _service.transformWithPreview(
          inputPath: orig,
          geometry: geometry,
          adjust: state.adjust,
          preset: state.preset,
          presetStrength: state.presetStrength,
          format: _resolvedFormat,
          jpegQuality: _jpegQuality,
          onProgress: (v) {
            if (mounted) setState(() => _progress = v);
          },
          onJob: (job) => _job = job,
        );
        out = r.outputPath;
        preview = r.previewPath;
      }
      final outBytes = await File(out).length();
      final outInfo = ir.ImageReader.parse(await File(out).readAsBytes());
      final previewInfo =
          ir.ImageReader.parse(await File(preview).readAsBytes());
      setState(() {
        _history.removeRange(_index + 1, _history.length);
        // A COPY goes into history: the draft must stay an independent
        // object, or mutating it later would rewrite the committed snapshot
        // too and _dirty would never turn true again.
        _history.add(_Snapshot(
          state: state.copy(),
          previewPath: preview,
          previewInfo: previewInfo,
        ));
        while (_history.length > _historyCap) {
          _history.removeAt(0);
        }
        _index = _history.length - 1;
        _snap
          ..outputPath = out
          ..outputBytes = outBytes
          ..outputInfo = outInfo
          ..compression = comp;
        _draft = state;
        _appliedCompressTarget = _compressTarget;
      });
      if (comp != null) {
        final r = comp;
        final hit = r.fits(_compressTarget);
        setState(() {
          _compressNote = hit
              ? '已压到目标以内：质量档 ${r.quality}'
                  '${r.width == null ? '' : ' · 宽度 ${r.width}px'}'
              : '已压到质量/尺寸下限，仍为 ${_formatBytes(r.bytes)}'
                  '（目标 ${_formatBytes(_compressTarget)}）';
        });
      }
    } on FfmpegCancelled {
      // Cancelled: no error, no new snapshot.
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = '$e');
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

  Future<void> _saveToGallery() async {
    final path = _snap.outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    try {
      await Gal.putImage(path, album: 'Tugi');
      if (mounted) {
        await WorksService.instance.record(
          originPath: path,
          featureId: 'edit_image',
          sourcePath: _origPath,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已存到相册')),
        );
      }
    } catch (e) {
      setState(() => _error = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    final path = _snap.outputPath;
    if (path == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'Tugi'),
    );
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.indigo),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: const AccentGradientBackground(
            accent: FeaturePalette.editImage,
          ),
          title: const Text('Edit Image'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // The preview is PINNED above the scrolling control panel instead of
        // living inside it. When it was a ListView child, dragging a slider
        // near the bottom of a long panel scrolled the image out of view, so
        // the live preview could not be seen while adjusting. Now it is always
        // on screen; while a drag is in flight the panel collapses to one line
        // (_buildDragBar) so the image gets the rest of the height.
        // A Listener sits above the sliders and clears the drag state on
        // pointer-up. It has to be an ancestor: while a drag is in flight the
        // control panel is collapsed (the sliders are laid out at zero size,
        // NOT removed), so the gesture is never cancelled by the widget that
        // started it disappearing from the tree.
        body: Listener(
          onPointerUp: (_) => _endDrag(),
          onPointerCancel: (_) => _endDrag(),
          child: _origPath == null
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  children: [
                    // The empty state is the first thing anyone sees here, so
                    // it says what the screen does instead of being one bare
                    // button next to a lot of white.
                    // Align, not a bare Container: a ListView hands its
                    // children tight cross-axis constraints, so a 64-wide
                    // Container would stretch the full width.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: const [
                              FeatureColors.editImage,
                              FeatureColors.editImageTail,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: _accent.withValues(alpha: 0.28),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.image, color: _on, size: 32),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Edit Image',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Neutrals.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '裁剪、旋转、调色一步到位；改完可以直接换个格式再导出。'
                      '所有处理都在本机完成，图片不会离开设备。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.55,
                        color: Neutrals.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final (icon, text) in const [
                      (Icons.crop_free, '裁剪与旋转：自由比例，或锁定 1:1 / 4:3 / 16:9'),
                      (Icons.tune, '调色与预设：亮度、对比度、饱和度，一键风格预设'),
                      (
                        Icons.photo_size_select_large,
                        '缩放与压缩：按边长缩放，或按体积压到某个大小以下'
                      ),
                      (Icons.ios_share, '格式与导出：PNG / JPEG / WebP，存相册或直接分享'),
                    ]) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(icon, size: 17, color: _accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                text,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  height: 1.45,
                                  color: Neutrals.inkSoft,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 10),
                    RainbowGlow(
                      child: RainbowGlow(
                          child: ElevatedButton.icon(
                        key: const Key('edit_image_pick'),
                        onPressed: _pickImage,
                        icon: const Icon(Icons.image),
                        label: const Text('选择图片'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: _on,
                          disabledBackgroundColor:
                              _accent.withValues(alpha: 0.16),
                          disabledForegroundColor:
                              _accent.withValues(alpha: 0.55),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      )),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                  ],
                )
              : Column(
                  children: [
                    // The preview is a HEADER, not an overlay: it never
                    // covers the controls, so nothing under it is
                    // un-tappable. It grows while a drag is in flight.
                    _buildPinnedPreview(),
                    // The control panel. The ListView is NEVER removed from
                    // the tree: taking the Slider that owns the drag out of
                    // the tree would cancel the gesture and lose the scroll
                    // position (the view snapped back to the top).
                    Expanded(
                      child: Stack(
                        children: [
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            children: [
                              _buildSelectedCard(),
                              const SizedBox(height: 12),
                              if (_cropping) ...[
                                _buildCropControls(),
                              ] else ...[
                                _buildGeometryRow(),
                                const SizedBox(height: 8),
                                _buildScaleRow(),
                                const SizedBox(height: 8),
                                _buildAdjustSection(),
                                const SizedBox(height: 8),
                                _buildPresetSection(),
                                const SizedBox(height: 8),
                                _buildHistoryRow(),
                                const SizedBox(height: 8),
                                _buildFormatSection(),
                                const SizedBox(height: 12),
                                _buildApplyButton(),
                                if (_snap.outputPath != null) ...[
                                  const SizedBox(height: 12),
                                  _buildResultCard(),
                                ],
                              ],
                              if (_error != null) ...[
                                const SizedBox(height: 12),
                                Text(_error!,
                                    style: const TextStyle(color: Colors.red)),
                              ],
                            ],
                          ),
                          // While a drag is in flight this opaque sheet
                          // covers the panel: the sliders are out of the
                          // way and the image gets the room. The panel
                          // underneath stays alive, so the gesture is never
                          // interrupted.
                          if (_dragging)
                            const Positioned.fill(
                              child: ColoredBox(color: _bg),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// Pinned preview: never scrolls away, and while a slider drag is in
  /// flight it takes every pixel the column can spare (the control panel
  /// has collapsed to the drag bar by then).
  Widget _buildPinnedPreview() {
    // The preview is a header above the control panel, so it never covers
    // the controls and nothing under it is un-tappable. It grows while a
    // drag is in flight, and the drag bar sits right under it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPreviewArea(height: _dragging ? 420 : 300),
          if (_dragging) _buildDragBar(),
        ],
      ),
    );
  }

  /// Shown only while a slider is being dragged: names the control under the
  /// finger so the collapsed panel is not a mystery.
  /// Clear the drag state. Called from the ancestor Listener on pointer-up
  /// as well as from the Slider, because either may report the end first.
  /// The live value of the control being dragged, shown in the drag bar.
  String? _dragValue;

  /// The format the dragged slider uses for its own readout, kept so the
  /// drag bar shows exactly the same text as the slider label it belongs to.
  String Function(double)? _dragFormatter;

  /// Wrapper around a slider's onChanged that keeps the drag bar's value
  /// readout in step with the finger.
  void _onSliderChanged(ValueChanged<double> onChanged, double newValue) {
    if (_dragging) {
      _dragValue = (_dragFormatter ?? _formatSliderValue)(newValue);
    }
    onChanged(newValue);
  }

  /// The drag bar's fallback number format.
  String _formatSliderValue(double value) => value.round().toString();

  void _endDrag() {
    if (!_dragging) return;
    setState(() {
      _dragging = false;
      _dragLabel = null;
    });
  }

  Widget _buildDragBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Neutrals.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accent.withValues(alpha: 0.35), width: 1.2),
      ),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 16, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _dragLabel ?? '松开手指查看效果',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: Neutrals.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_dragValue != null) ...[
            const SizedBox(width: 10),
            Text(
              _dragValue!,
              style: const TextStyle(
                fontSize: 14,
                color: _accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(width: 8),
          const Text('松手收起',
              style: TextStyle(fontSize: 11, color: Neutrals.inkSoft)),
        ],
      ),
    );
  }

  /// The preview surface. [height] is the stage's pixel height.
  Widget _buildSelectedCard() {
    final info = _srcInfo;
    final alpha = info?.hasAlpha ?? false;
    return Card(
      color: Colors.white,
      elevation: 0,
      child: ListTile(
        leading: const Icon(Icons.image, color: Color(0xFFE17055)),
        title:
            const Text('已选图片', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${_formatBytes(_srcBytes)} · ${info?.width}×${info?.height}'
          ' · ${(info?.format ?? '?').toUpperCase()}'
          '${alpha ? ' · 含透明通道' : ''}',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        trailing: TextButton(onPressed: _pickImage, child: const Text('重选')),
      ),
    );
  }

  /// The preview surface. [height] is the pixel height of the stage; it must
  /// be explicit, because a LayoutBuilder inside a Column has an unbounded
  /// maxHeight and the stage would then never size itself.
  Widget _buildPreviewArea({required double height}) {
    final preview = File(_snap.previewPath);
    final quarter = _displayQuarter;
    return LayoutBuilder(builder: (context, box) {
      final info = _snap.previewInfo;
      final aspect =
          info == null || info.height == 0 ? 4 / 3 : info.width / info.height;
      final dispAspect = (quarter.isOdd) ? (1 / aspect) : aspect;
      var w = box.maxWidth;
      var h = w / dispAspect;
      if (h > height) {
        h = height;
        w = h * dispAspect;
      }
      _dispW = w;
      _dispH = h;
      final originalShown = _showOriginal && _history.isNotEmpty && _index > 0;
      final originalQuarter = originalShown ? 0 : quarter;
      final image = ClipRect(
        child: Transform.flip(
          flipX: originalShown ? false : _displayFlipH,
          flipY: originalShown ? false : _displayFlipV,
          child: Image.file(
            originalShown ? File(_history[0].previewPath) : preview,
            width: w,
            height: h,
            fit: BoxFit.fill,
            cacheWidth: 1080,
            gaplessPlayback: true,
          ),
        ),
      );
      Widget stage = image;
      if (!originalShown) {
        final cf = _previewColorFilter();
        final sigma = _previewBlurSigma();
        if (cf != null) {
          stage = ColorFiltered(colorFilter: cf, child: stage);
        }
        if (sigma > 0) {
          stage = ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: stage,
          );
        }
      }
      stage = RepaintBoundary(child: stage);
      final rotated = originalQuarter == 0
          ? stage
          : RotatedBox(quarterTurns: originalQuarter, child: stage);
      // Cropping keeps the old fitted layout (the overlay maps 1:1 onto the
      // image); everywhere else the preview becomes a SQUARE frame and the
      // photo zooms INSIDE it, clamped so no empty edge shows.
      if (!_cropping) {
        final side = math.min(box.maxWidth, height);
        return Container(
          width: box.maxWidth,
          height: height,
          alignment: Alignment.center,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: side,
              height: side,
              child: ColoredBox(
                color: const Color(0xFF2D3436),
                child: ZoomableImage(
                  key: const Key('edit_image_zoom'),
                  // Hold-to-compare is handled by the zoom widget itself: its
                  // eager recogniser would swallow a GestureDetector's
                  // long-press.
                  onLongPressStart: () => setState(() => _showOriginal = true),
                  onLongPressEnd: () => setState(() => _showOriginal = false),
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(width: w, height: h, child: rotated),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      Widget content = GestureDetector(
        onLongPressStart: (_) => setState(() => _showOriginal = true),
        onLongPressEnd: (_) => setState(() => _showOriginal = false),
        onLongPressCancel: () => setState(() => _showOriginal = false),
        child: Center(child: rotated),
      );
      if (_cropping) {
        content = Stack(
          alignment: Alignment.center,
          children: [
            content,
            Positioned(
              left: (box.maxWidth - w) / 2,
              top: (height - h) / 2,
              width: w,
              height: h,
              child: _buildCropOverlay(),
            ),
          ],
        );
      }
      return Container(
        width: double.infinity,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF2D3436),
          borderRadius: BorderRadius.circular(12),
        ),
        child: content,
      );
    });
  }

  Widget _buildCropOverlay() {
    final r = _cropRect;
    return GestureDetector(
      onPanStart: (d) => _onCropPanStart(d.localPosition),
      onPanUpdate: (d) => _onCropPanUpdate(d.localPosition),
      onPanEnd: (_) => _dragMode = null,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CropDimPainter(rect: r),
            ),
          ),
          Positioned(
            left: r.left * _dispW,
            top: r.top * _dispH,
            width: r.width * _dispW,
            height: r.height * _dispH,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: _accent, width: 2),
              ),
            ),
          ),
          for (final c in _Corner.values)
            Positioned(
              left: c.x(r) * _dispW - 14,
              top: c.y(r) * _dispH - 14,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _accent.withValues(alpha: 0.9),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _onCropPanStart(Offset local) {
    final u = local.dx / _dispW;
    final v = local.dy / _dispH;
    for (final c in _Corner.values) {
      final dx = c.x(_cropRect) - u;
      final dy = c.y(_cropRect) - v;
      if (dx * dx + dy * dy < 0.02) {
        _dragMode = _DragMode.resize;
        _dragCorner = c;
        _dragStart = Offset(u, v);
        _rectStart = _cropRect;
        return;
      }
    }
    if (_cropRect.contains(Offset(u, v))) {
      _dragMode = _DragMode.move;
      _dragStart = Offset(u, v);
      _rectStart = _cropRect;
    }
  }

  void _onCropPanUpdate(Offset local) {
    final u = (local.dx / _dispW).clamp(0.0, 1.0);
    final v = (local.dy / _dispH).clamp(0.0, 1.0);
    if (_dragMode == _DragMode.move) {
      final du = u - _dragStart.dx;
      final dv = v - _dragStart.dy;
      var left = (_rectStart.left + du).clamp(0.0, 1 - _rectStart.width);
      var top = (_rectStart.top + dv).clamp(0.0, 1 - _rectStart.height);
      setState(() {
        _cropRect =
            Rect.fromLTWH(left, top, _rectStart.width, _rectStart.height);
      });
    } else if (_dragMode == _DragMode.resize && _dragCorner != null) {
      final anchor = Offset(
        _dragCorner!.x(_rectStart) == 0 ? _rectStart.right : _rectStart.left,
        _dragCorner!.y(_rectStart) == 0 ? _rectStart.bottom : _rectStart.top,
      );
      var w = (u - anchor.dx).abs();
      var h = (v - anchor.dy).abs();
      if (_ratioLock != null && _ratioLock! > 0) {
        h = w * _dispW / (_ratioLock! * _dispH);
        if (h > 1) {
          h = 1;
          w = h * _ratioLock! * _dispH / _dispW;
        }
      }
      w = w.clamp(0.05, 1);
      h = h.clamp(0.05, 1);
      final left = anchor.dx == 0 ? anchor.dx : (anchor.dx - w).clamp(0.0, 1.0);
      final top = anchor.dy == 0 ? anchor.dy : (anchor.dy - h).clamp(0.0, 1.0);
      w = math.min(w, 1 - left);
      h = math.min(h, 1 - top);
      setState(() {
        _cropRect = Rect.fromLTWH(left, top, w, h);
      });
    }
  }

  Widget _buildCropControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final label in _ratioPresets.keys)
              ChoiceChip(
                label: Text(label),
                selected: _cropLabel == label,
                selectedColor: _accent,
                onSelected: (_) => _setRatio(label),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancelCrop,
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: RainbowGlow(
                  child: ElevatedButton.icon(
                onPressed: _applying ? null : _finishCrop,
                icon: _applying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_applying ? '处理中…' : '确认裁剪'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: _on,
                  disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                  disabledForegroundColor: _accent.withValues(alpha: 0.55),
                ),
              )),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGeometryRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: '左转 90°',
          onPressed: () => _rotate(-1),
          icon: const Icon(Icons.rotate_left),
          color: const Color(0xFFE17055),
        ),
        IconButton(
          tooltip: '右转 90°',
          onPressed: () => _rotate(1),
          icon: const Icon(Icons.rotate_right),
          color: const Color(0xFFE17055),
        ),
        IconButton(
          tooltip: '左右翻转',
          onPressed: () => _toggleFlip(horizontal: true),
          icon: const Icon(Icons.flip),
          color: const Color(0xFFE17055),
        ),
        IconButton(
          tooltip: '上下翻转',
          onPressed: () => _toggleFlip(horizontal: false),
          icon: const Icon(Icons.flip_camera_android),
          color: const Color(0xFFE17055),
        ),
        OutlinedButton.icon(
          onPressed: _enterCrop,
          icon: const Icon(Icons.crop, size: 18),
          label: const Text('裁剪'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.black87),
        ),
      ],
    );
  }

  Widget _buildScaleRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('输出宽度',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final p in _scalePresets)
              ChoiceChip(
                label: Text(p == null ? '原始' : '${p}px'),
                selected: _draft.scaleWidth == p,
                selectedColor: _accent,
                onSelected: (_) => setState(() => _draft.scaleWidth = p),
              ),
          ],
        ),
      ],
    );
  }

  static const _presets = <String, String>{
    'none': '原图',
    'bw': '黑白',
    'vintage': '复古',
    'cool': '冷调',
    'warm': '暖调',
    'contrast': '高对比',
    'lowsat': '低饱和',
    'cine': '电影感',
    'soft': '柔光',
  };

  Widget _buildAdjustSection() {
    final a = _draft.adjust;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('调色',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 2),
        _buildSlider(
          '亮度',
          a.brightness,
          -100,
          100,
          200,
          (v) => _setAdjust(brightness: v),
        ),
        _buildSlider(
          '对比度',
          a.contrast,
          -100,
          100,
          200,
          (v) => _setAdjust(contrast: v),
        ),
        _buildSlider(
          '饱和度',
          a.saturation,
          0,
          200,
          200,
          (v) => _setAdjust(saturation: v),
        ),
        _buildSlider(
          '色相',
          a.hue,
          -180,
          180,
          360,
          (v) => _setAdjust(hue: v),
          format: (v) => '${v.round() > 0 ? '+' : ''}${v.round()}°',
        ),
        _buildSlider(
          '色温',
          a.temperature,
          -100,
          100,
          200,
          (v) => _setAdjust(temperature: v),
        ),
        _buildSlider(
          '阴影',
          a.shadows,
          -30,
          30,
          60,
          (v) => _setAdjust(shadows: v),
          note: '阴影/中间调/高光无实时预览，应用后生效',
        ),
        _buildSlider(
          '中间调',
          a.midtones,
          -30,
          30,
          60,
          (v) => _setAdjust(midtones: v),
        ),
        _buildSlider(
          '高光',
          a.highlights,
          -30,
          30,
          60,
          (v) => _setAdjust(highlights: v),
        ),
        _buildSlider(
          '锐化',
          a.sharpen,
          0,
          300,
          600,
          (v) => _setAdjust(sharpen: v),
          format: (v) => v.toStringAsFixed(1),
          note: '锐化无实时预览，应用后生效',
        ),
        _buildSlider(
          '模糊',
          a.blur,
          0,
          30,
          60,
          (v) => _setAdjust(blur: v),
          format: (v) => v.toStringAsFixed(1),
        ),
      ],
    );
  }

  /// Whether the current preset has a GPU-preview stand-in (see
  /// [editImagePresetPreviewMatrix], which returns null for `soft` and for
  /// strength 0). Drives which hint the strength slider shows.
  bool get _presetPreviewSupported =>
      editImagePresetPreviewMatrix(_draft.preset, _draft.presetStrength) !=
      null;

  Widget _buildPresetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('风格预设',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _presets.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: _draft.preset == entry.key,
                selectedColor: _accent,
                onSelected: (_) => setState(() {
                  _draft.preset = entry.key;
                  if (entry.key == 'none') _draft.presetStrength = 100;
                }),
              ),
          ],
        ),
        if (_draft.preset != 'none') ...[
          const SizedBox(height: 2),
          _buildSlider(
            '强度',
            _draft.presetStrength.toDouble(),
            0,
            100,
            100,
            (v) =>
                setState(() => _draft.presetStrength = v.round().clamp(0, 100)),
            format: (v) => '${v.round()}',
          ),
          if (_presetPreviewSupported)
            const Padding(
              padding: EdgeInsets.only(left: 50, top: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('预览为实时近似值，保存后的实际效果以处理结果为准',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(left: 50, top: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('该预设靠卷积/分档调色实现，无法实时预览，应用后生效',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> onChanged, {
    String Function(double)? format,
    String? note,
  }) {
    final text = format?.call(value) ?? '${value.round()}';
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Colors.black87)),
            ),
            Expanded(
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                label: text,
                // Slider still has no activeThumbColor in this SDK; the
                // Switch below uses it.
                activeColor: _accent,
                onChanged:
                    _applying ? null : (v) => _onSliderChanged(onChanged, v),
                // The panel collapses for the duration of the drag (see
                // build): the preview keeps the screen, and the drag bar
                // names the control so the collapsed panel is not a mystery.
                onChangeStart: (_) => setState(() {
                  _dragFormatter = format;
                  _dragging = true;
                  _dragLabel = label;
                }),
                onChangeEnd: (_) => _endDrag(),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(text,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      fontWeight: FontWeight.w500)),
            ),
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(left: 50),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(note,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ),
          ),
      ],
    );
  }

  Widget _buildHistoryRow() {
    return Row(
      children: [
        IconButton(
          onPressed: _canUndo ? _undo : null,
          icon: const Icon(Icons.undo),
          tooltip: '撤销',
        ),
        IconButton(
          onPressed: _canRedo ? _redo : null,
          icon: const Icon(Icons.redo),
          tooltip: '重做',
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: _history.isNotEmpty ? _resetAll : null,
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('重置全部'),
        ),
      ],
    );
  }

  Widget _buildFormatSection() {
    final resolved = _resolvedFormat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('输出格式',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final f in const ['auto', 'jpg', 'png', 'webp'])
              ChoiceChip(
                label: Text(f == 'auto' ? '原始' : f.toUpperCase()),
                selected: _format == f,
                selectedColor: _accent,
                onSelected: (_) => setState(() => _format = f),
              ),
          ],
        ),
        if (resolved == 'jpg' || resolved == 'webp') ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final q in const [2, 5, 10])
                ChoiceChip(
                  label: Text(q == 2
                      ? '质量 最佳'
                      : q == 5
                          ? '质量 标准'
                          : '质量 高压缩'),
                  selected: _jpegQuality == q,
                  selectedColor: _accent,
                  onSelected: (_) => setState(() => _jpegQuality = q),
                ),
            ],
          ),
        ],
        if (resolved == 'jpg')
          _buildCompressSection()
        else ...[
          const SizedBox(height: 8),
          Text('${resolved.toUpperCase()} 不支持按体积压缩',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ],
    );
  }

  /// Target-size compression. ffmpeg has no "hit N bytes" mode, so the apply
  /// step searches the quality ladder (and, if allowed, narrower widths) until
  /// the file fits. Target choices are the sizes people actually want: small
  /// enough to send over chat, small enough to email, share-a-photo limits.
  Widget _buildCompressSection() {
    const targets = <int, String>{
      0: '不压缩',
      100 * 1024: '100 KB',
      300 * 1024: '300 KB',
      500 * 1024: '500 KB',
      1024 * 1024: '1 MB',
      2 * 1024 * 1024: '2 MB',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('压缩到目标体积',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 2),
        Text(
          _compressTarget > 0
              ? '反复降质量编码，达标即停；每次都从原图重跑整条滤镜链，不会叠加损失。'
              : '按目标体积自动搜索质量档。',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final e in targets.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: !_customTargetActive && _compressTarget == e.key,
                selectedColor: _accent,
                onSelected: (_) => setState(() {
                  _customTargetActive = false;
                  _compressTarget = e.key;
                  _compressNote = '';
                }),
              ),
            ChoiceChip(
              label: const Text('自定义'),
              selected: _customTargetActive,
              selectedColor: _accent,
              onSelected: (_) => setState(() {
                _customTargetActive = true;
                _compressTarget = _customTargetBytes ?? 0;
                _compressNote = '';
              }),
            ),
          ],
        ),
        if (_customTargetActive) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 110,
                // A bare TextField in a Row stretches to whatever height the
                // decoration asks for (274px here), which pushed the apply
                // button off-screen. Pin it to a single dense line.
                height: 40,
                child: TextField(
                  controller: _customKbController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    labelText: 'KB',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() {
                    _compressTarget = _customTargetBytes ?? 0;
                    _compressNote = '';
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _customTargetBytes == null
                      ? '填一个正整数（KB）'
                      : '目标 ${_formatBytes(_compressTarget)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
        ],
        if (_compressTarget > 0) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _compressAllowScale,
            activeThumbColor: _accent,
            title: const Text('允许缩小尺寸',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text(
              _compressAllowScale
                  ? '质量到底仍超标时，逐级降到 2560 → 320 px'
                  : '只降质量，不改像素尺寸（更激进，画质损失更大）',
              style: const TextStyle(fontSize: 11),
            ),
            onChanged: (v) => setState(() => _compressAllowScale = v),
          ),
          if (_srcInfo != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '原图 ${_srcInfo!.width}×${_srcInfo!.height} · '
                '${_formatBytes(_srcBytes)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          if (_compressNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _compressNote,
                style: const TextStyle(fontSize: 12, color: Colors.teal),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildApplyButton() {
    final busy = _applying && _compressTarget > 0 && _compressMax > 0;
    return Column(
      children: [
        if (_applying) const LinearProgressIndicator(minHeight: 3),
        if (busy)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '压缩中 $_compressAttempt/$_compressMax · 当前 '
              '${_formatBytes(_compressBytes)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        const SizedBox(height: 8),
        if (_applying)
          ExportProgress(
            progress: _progress,
            label: '正在处理…',
            accent: _accent,
            onColor: _on,
            onCancel: _cancelApply,
          )
        else
          SizedBox(
            width: double.infinity,
            child: RainbowGlow(
                child: ElevatedButton.icon(
              onPressed: _dirty ? _apply : null,
              icon: const Icon(Icons.auto_fix_high),
              label: Text(
                _compressTarget > 0
                    ? '应用并压缩到 ${_formatBytes(_compressTarget)}'
                    : '应用并处理',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: _on,
                disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                disabledForegroundColor: _accent.withValues(alpha: 0.55),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            )),
          ),
      ],
    );
  }

  Widget _buildResultCard() {
    final info = _snap.outputInfo;
    final bytes = _snap.outputBytes;
    final crop = _draft.crop != null || _snap.state.crop != null;
    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                const Text('转换结果',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: _pickImage,
                  child: const Text('重选'),
                ),
              ],
            ),
            Text(
              '${_formatBytes(bytes ?? 0)} · ${info?.width}×${info?.height}'
              ' · ${(info?.format ?? '?').toUpperCase()}',
              style: TextStyle(fontSize: 13, color: Colors.grey[700]),
            ),
            const SizedBox(height: 10),
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
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.share),
                    label: const Text('分享'),
                  ),
                ),
              ],
            ),
            if (crop)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('已裁剪',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ),
            if (_snap.compression != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '压缩：质量档 ${_snap.compression!.quality}'
                  '${_snap.compression!.width == null ? '' : ' · 宽度 ${_snap.compression!.width}px'}'
                  '${_snap.compression!.fits(_compressTarget) ? ' · 已达目标' : ' · 未达目标'}',
                  style: const TextStyle(fontSize: 11, color: Colors.teal),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _DragMode { move, resize }

enum _Corner {
  tl,
  tr,
  bl,
  br;

  double x(Rect r) =>
      this == _Corner.tl || this == _Corner.bl ? r.left : r.right;
  double y(Rect r) =>
      this == _Corner.tl || this == _Corner.tr ? r.top : r.bottom;
}

extension _CropRectX on Rect {
  bool isValidCrop() => width > 0.02 && height > 0.02;
}

/// Dim everything outside the crop rect.
class _CropDimPainter extends CustomPainter {
  _CropDimPainter({required this.rect});
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final full = Offset.zero & size;
    canvas.drawPath(
      Path()
        ..addRect(full)
        ..addRect(Rect.fromLTWH(rect.left * size.width, rect.top * size.height,
            rect.width * size.width, rect.height * size.height))
        ..fillType = PathFillType.evenOdd,
      paint,
    );
  }

  @override
  bool shouldRepaint(_CropDimPainter old) => old.rect != rect;
}
