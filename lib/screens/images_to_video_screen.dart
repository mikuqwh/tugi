/// Tugi - Images to Video screen (roadmap 4.4).
///
/// Flow: pick N images -> thumbnails -> per-image duration + output width
/// -> concat + libx264 mp4 -> preview -> save to gallery / share.
///
/// Reuses the multi-image picker pattern from Images to GIF. Two behaviours are
/// deliberately different from that screen:
///
///  1. **Letterbox canvas.** concat + libx264 need uniform dimensions and real
///     photo albums mix landscape and portrait freely. Each image is
///     scaled-to-fit and padded onto a canvas sized from the FIRST image's
///     aspect ratio, so nothing is stretched and nothing is cropped away.
///
///  2. **Duration and frame rate are separate controls.** How long an image
///     stays is the concat `duration`; the frame rate is stream smoothness.
///     They are not the same knob (measuring the mp4 muxer settled that:
///     see `ffmpeg.imagesToVideo`).
// SPDX-License-Identifier: GPL-3.0-or-later

library images_to_video_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../ffmpeg/commands.dart' show imagesToVideoSettleFps;
import '../services/export_service.dart';
import 'package:format_core/format_core.dart';

import '../services/images_to_video_service.dart';
import '../services/ffmpeg_progress.dart';
import '../ui/output_format_picker.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/export_progress.dart';
import '../ui/rainbow_glow.dart';

class ImagesToVideoScreen extends StatefulWidget {
  const ImagesToVideoScreen({super.key, this.initialImagePaths});

  /// Pre-load images instead of waiting for the picker (works shelf).
  final List<String>? initialImagePaths;

  @override
  State<ImagesToVideoScreen> createState() => _ImagesToVideoScreenState();
}

class _ImagesToVideoScreenState extends State<ImagesToVideoScreen> {
  @override
  void initState() {
    super.initState();
    final preset = widget.initialImagePaths;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _images.addAll(preset.map(XFile.new)));
      });
    }
  }

  static const _accent = FeatureColors.imagesToVideo;
  static const _on = FeatureColors.imagesToVideoOn;

  /// Per-image seconds. Short values are the ones that can silently drop
  /// images, so the low end stops at 0.2 s rather than going lower.
  static const _durationOptions = <double>[0.2, 0.5, 1.0, 2.0, 3.0];

  /// Canvas width. There is deliberately no "原始 / original" entry: combining
  /// images at their native sizes only works when they happen to match, and
  /// when they do not, the concat demuxer silently drops everything after the
  /// first resolution change. A plausible-looking video missing most of its
  /// images is worse than not offering the option at all.
  static const _widthOptions = <int>[1080, 1920, 720, 480];

  /// Requested stream frame rate. The service may raise it; see _settledFps.
  static const _fpsOptions = <int>[12, 24, 30];

  final List<XFile> _images = [];
  bool _converting = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  ImagesToVideoResult? _result;

  /// Container/codec. Defaults to the previous implementation H.264 MP4; the segments are
  /// encoded with it, so switching means the whole run re-encodes.
  FormatSpec _outputFormat = formatById('mp4_h264')!;

  double _secondsPerImage = 1.0;
  int _canvasWidth = 1080;
  int _fps = 12;

  /// The rate actually used, after the no-dropped-image clamp.
  ///
  /// Surfaced in the UI so the user can see why the video is smoother than the
  /// 12fps they asked for, instead of it happening invisibly.
  int get _settledFps => imagesToVideoSettleFps(
        secondsPerImage: _secondsPerImage,
        requestedFps: _fps,
      );

  bool get _wasClamped => _settledFps != _fps;

  Future<void> _pickImages() async {
    try {
      final picked = await ImagePicker().pickMultiImage();
      if (picked.isNotEmpty) {
        setState(() {
          _images.addAll(picked);
          _error = null;
          _result = null;
        });
      }
    } catch (e) {
      setState(() => _error = '选择图片失败: $e');
    }
  }

  void _removeImage(int index) {
    setState(() {
      _images.removeAt(index);
      _result = null;
    });
  }

  void _clearAll() {
    setState(() {
      _images.clear();
      _result = null;
      _error = null;
    });
  }

  Future<void> _convert() async {
    if (_images.isEmpty) return;
    setState(() {
      _converting = true;
      _progress = 0;
      _job = null;
      _error = null;
      _result = null;
    });

    ImagesToVideoService? service;
    try {
      service = ImagesToVideoService(
        workDir: Directory.systemTemp.path,
        format: _outputFormat,
      );
      final out =
          '${Directory.systemTemp.path}/itv_${DateTime.now().millisecondsSinceEpoch}'
          '.${_outputFormat.extension}';
      final r = await service.convertImagesToVideo(
        imagePaths: _images.map((f) => f.path).toList(),
        outputPath: out,
        secondsPerImage: _secondsPerImage,
        fps: _fps,
        canvasWidth: _canvasWidth,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
      );
      setState(() => _result = r);
    } on FfmpegCancelled {
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      // The staged copies are only needed for the encode; the OUTPUT lives
      // outside workDir, so clearing the staging area cannot delete the result.
      service?.cleanup();
      if (mounted) {
        setState(() {
          _converting = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Stop the running encode.
  void _cancelConvert() => _job?.cancel();

  Future<void> _saveToGallery() async {
    final path = _result?.outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    final outcome = await ExportService().save(path, album: 'Tugi');
    if (!mounted) {
      setState(() => _saving = false);
      return;
    }
    setState(() => _saving = false);
    if (outcome.isSuccess) {
      await WorksService.instance.record(
        originPath: path,
        featureId: 'images_to_video',
        sourcePath: _images.isEmpty ? null : _images.first.path,
      );
      if (!mounted) return;
    }
    _toast(switch (outcome.status) {
      ExportStatus.savedToGallery => '已存到相册',
      ExportStatus.savedToFile => outcome.message ?? '已保存到文件',
      ExportStatus.cancelled => '已取消',
      ExportStatus.failed => outcome.message ?? '保存失败',
    });
  }

  Future<void> _share() async {
    final path = _result?.outputPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      setState(() => _error = '分享失败: $e');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatSeconds(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}';
    return s.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.cyan),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.imagesToVideo,
          ),
          title: const Text('Images to Video'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching the other screens: the
        // picked-image thumbnails stay on screen while duration / canvas / fps
        // scroll beneath them, so the selection is always visible.
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: RainbowGlow(
                        child: ElevatedButton.icon(
                      onPressed: _converting ? null : _pickImages,
                      icon: const Icon(Icons.photo_library),
                      label: Text(
                        _images.isEmpty
                            ? '选择图片'
                            : '添加更多（已选 ${_images.length} 张）',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            _accent.withValues(alpha: 0.16),
                        disabledForegroundColor:
                            _accent.withValues(alpha: 0.55),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    )),
                  ),
                  if (_images.isNotEmpty)
                    IconButton(
                      tooltip: '清空',
                      onPressed: _converting ? null : _clearAll,
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
            ),
            if (_images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _buildThumbnails(),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  _buildDurationRow(),
                  const SizedBox(height: 12),
                  _buildCanvasRow(),
                  const SizedBox(height: 12),
                  _buildFpsRow(),
                  const SizedBox(height: 12),
                  _buildTimingNote(),
                  const SizedBox(height: 16),
                  OutputFormatPicker(
                    key: const Key('itv_format'),
                    formats: formatsFor(MediaKind.video)
                        .where((f) => f.kind == MediaKind.video)
                        .where((f) => f.extension != 'avi')
                        .toList(),
                    selected: _outputFormat,
                    common: const ['mp4_h264', 'mp4_h265', 'webm_vp9'],
                    onSelected: (f) => setState(() {
                      _outputFormat = f;
                      _result = null;
                      _error = null;
                    }),
                  ),
                  const SizedBox(height: 20),
                  if (_converting)
                    ExportProgress(
                      progress: _progress,
                      label: '正在生成视频（${_images.length} 张）…',
                      accent: _accent,
                      onColor: _on,
                      onCancel: _cancelConvert,
                    )
                  else
                    _buildConvertButton(),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  if (_result != null) _buildResult(_result!),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConvertButton() {
    final settled = _settledFps;
    final eta = _images.length * _secondsPerImage;
    return RainbowGlow(
        child: ElevatedButton.icon(
      onPressed: (_images.isEmpty || _converting) ? null : _convert,
      icon: const Icon(Icons.movie_creation),
      label: Text(
        _converting
            ? '生成中…'
            : '生成视频（约 ${eta.toStringAsFixed(1)} 秒 · ${settled}fps）',
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: _accent.withValues(alpha: 0.16),
        disabledForegroundColor: _accent.withValues(alpha: 0.55),
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
    ));
  }

  Widget _buildDurationRow() {
    return _paramRow<double>(
      '每张时长',
      _durationOptions,
      _secondsPerImage,
      (v) => setState(() => _secondsPerImage = v),
      (v) => '${_formatSeconds(v)} 秒',
    );
  }

  Widget _buildCanvasRow() {
    return _paramRow<int>(
      '画面尺寸',
      _widthOptions,
      _canvasWidth,
      (v) => setState(() => _canvasWidth = v),
      (v) => '$v px',
    );
  }

  Widget _buildFpsRow() {
    return _paramRow<int>(
      '帧率',
      _fpsOptions,
      _fps,
      (v) => setState(() => _fps = v),
      (v) => '$v',
    );
  }

  /// Explain the canvas choice and any frame-rate clamp, in the user's terms.
  ///
  /// There is no "this combination may drop frames" warning here on purpose.
  /// The clamp in [_settledFps] always raises the rate until every image spans
  /// at least [imagesToVideoMinFramesPerImage] frames, so a warning keyed on
  /// the settled rate would be dead code that merely looked like a safeguard.
  /// [_wasClamped] is the honest signal: it fires exactly when the rate the
  /// user picked was not the rate that will be used.
  Widget _buildTimingNote() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '画面尺寸 $_canvasWidth px：横竖图混选时按第一张的比例加黑边，'
            '不拉伸、不裁切。',
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
          if (_wasClamped) ...[
            const SizedBox(height: 6),
            Text(
              '帧率已自动提到 ${_settledFps}fps：每张 ${_formatSeconds(_secondsPerImage)} 秒时，'
              '低于这个帧率会有图片整张丢失（不是变短）。',
              style: const TextStyle(fontSize: 12, color: Color(0xFFE17055)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _paramRow<T>(
    String label,
    List<T> options,
    T current,
    ValueChanged<T> onSelected,
    String Function(T) format,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final opt in options)
                ChoiceChip(
                  label: Text(format(opt)),
                  selected: current == opt,
                  onSelected: (_) => onSelected(opt),
                  selectedColor: _accent.withValues(alpha: 0.2),
                  checkmarkColor: _accent,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThumbnails() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _images.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemBuilder: (context, i) => Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(_images[i].path), fit: BoxFit.cover),
          ),
          Positioned(
            left: 2,
            top: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${i + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: _converting ? null : () => _removeImage(i),
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(3),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(ImagesToVideoResult r) {
    final canvasLabel = '${r.width}×${r.height}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Text('转换结果', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.movie, size: 18, color: _accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_formatBytes(r.bytes)} · $canvasLabel · '
                      '${r.imageCount} 张 · ${_formatSeconds(r.secondsPerImage)} 秒/张',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '预计时长 ${r.expectedSeconds.toStringAsFixed(1)} 秒 · ${r.fps}fps'
                '${r.fps != _fps ? '（已从 ${_fps}fps 提升，避免丢图）' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
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
                  foregroundColor: Colors.white,
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
      ],
    );
  }
}
