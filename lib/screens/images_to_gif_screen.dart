// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - Images to GIF screen (multi-image picker).
///
/// Rebuilt 2026-10-15 after the previous in-main.dart implementation was lost
/// to an overwrite (never committed). Service layer survived intact:
/// ImagesToGifService.convertImagesToGifMulti.
///
/// Flow: pick N images -> thumbnails -> per-frame duration + output width
/// -> convert -> preview -> save to gallery / share.
// SPDX-License-Identifier: GPL-3.0-or-later

library images_to_gif_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gal/gal.dart';

import 'package:format_core/format_core.dart';

import '../services/ffmpeg_progress.dart';
import '../services/images_to_gif_service.dart';
import '../ui/output_format_picker.dart';
import '../services/works_service.dart';
import '../ui/export_progress.dart';
import '../ui/app_palette.dart';
import '../ui/rainbow_glow.dart';

class ImagesToGifScreen extends StatefulWidget {
  const ImagesToGifScreen({super.key, this.initialImagePaths});

  /// Pre-load images instead of waiting for the picker (works shelf).
  final List<String>? initialImagePaths;

  @override
  State<ImagesToGifScreen> createState() => _ImagesToGifScreenState();
}

class _ImagesToGifScreenState extends State<ImagesToGifScreen> {
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

  final List<XFile> _images = [];
  bool _converting = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  String? _outputPath;
  int? _outputBytes;
  int? _frameCount;
  double _secondsPerFrame = 1.0;
  double? _outputWidth;

  static const _accent = FeatureColors.imagesToGif;
  static const _on = FeatureColors.imagesToGifOn;
  static const _durationOptions = <double>[0.5, 1.0, 2.0];
  static const _widthOptions = <double?>[null, 1080, 720, 480];

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _pickImages() async {
    try {
      final picked = await ImagePicker().pickMultiImage();
      if (picked.isNotEmpty) {
        setState(() => _images.addAll(picked));
      }
    } catch (e) {
      setState(() => _error = '选择图片失败: $e');
    }
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  /// GIF by default; APNG keeps full colour and alpha at the cost of size.
  FormatSpec _outputFormat = formatById('gif')!;

  /// Stop the running encode.
  void _cancelConvert() => _job?.cancel();

  Future<void> _convert() async {
    if (_images.isEmpty) return;
    setState(() {
      _converting = true;
      _progress = 0;
      _job = null;
      _error = null;
      _outputPath = null;
      _outputBytes = null;
      _frameCount = null;
    });

    try {
      final dir = Directory.systemTemp;
      final service = ImagesToGifService(
        workDir: dir.path,
        format: _outputFormat,
      );
      final path = await service.convertImagesToGifMulti(
        _images.map((f) => f.path).toList(),
        secondsPerFrame: _secondsPerFrame,
        outputWidth: _outputWidth,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
      );
      service.cleanup();
      setState(() {
        _outputPath = path;
        _outputBytes = File(path).lengthSync();
        _frameCount = _images.length;
      });
    } on FfmpegCancelled {
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _converting = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  Future<void> _saveToGallery() async {
    final path = _outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    try {
      await Gal.putImage(path, album: 'Tugi');
      await WorksService.instance.record(
        originPath: path,
        featureId: 'images_to_gif',
        sourcePath: _images.isEmpty ? null : _images.first.path,
      );
      if (!mounted) return;
      _toast('已存到相册');
    } catch (e) {
      setState(() => _error = '保存失败: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    final path = _outputPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)]),
      );
    } catch (e) {
      setState(() => _error = '分享失败: $e');
    }
  }

  void _reset() {
    setState(() {
      _images.clear();
      _outputPath = null;
      _outputBytes = null;
      _frameCount = null;
      _error = null;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.rose),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.imagesToGif,
          ),
          title: const Text('Images to GIF'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching the other screens: the
        // picked-image thumbnails stay on screen while the parameter rows
        // scroll beneath them, so the selection is always visible.
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: RainbowGlow(
                  child: ElevatedButton.icon(
                onPressed: _converting ? null : _pickImages,
                icon: const Icon(Icons.photo_library),
                label: Text(
                    _images.isEmpty ? '选择图片' : '添加更多（已选 ${_images.length} 张）'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: _on,
                  disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                  disabledForegroundColor: _accent.withValues(alpha: 0.55),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              )),
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
                  _buildParamRow('每张时长', _durationOptions, _secondsPerFrame,
                      (v) {
                    setState(() => _secondsPerFrame = v ?? 1.0);
                  }, (v) => '$v 秒'),
                  const SizedBox(height: 12),
                  _buildParamRow('输出宽度', _widthOptions, _outputWidth, (v) {
                    setState(() => _outputWidth = v);
                  }, (v) => v == null ? '原始' : '$v px'),
                  const SizedBox(height: 16),
                  OutputFormatPicker(
                    key: const Key('anim_format'),
                    formats: [formatById('gif')!, formatById('apng')!],
                    selected: _outputFormat,
                    common: const ['gif', 'apng'],
                    onSelected: (f) => setState(() {
                      _outputFormat = f;
                      _outputPath = null;
                      _outputBytes = null;
                    }),
                  ),
                  const SizedBox(height: 16),
                  RainbowGlow(
                      child: ElevatedButton.icon(
                    onPressed:
                        (_images.isEmpty || _converting) ? null : _convert,
                    icon: const Icon(Icons.gif),
                    label: Text(_converting ? '转换中…' : '转换为 GIF'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: _on,
                      disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                      disabledForegroundColor: _accent.withValues(alpha: 0.55),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  )),
                  if (_converting) ...[
                    const SizedBox(height: 24),
                    ExportProgress(
                      progress: _progress,
                      label: '正在合成 GIF…',
                      accent: _accent,
                      onColor: _on,
                      onCancel: _cancelConvert,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  if (_outputPath != null) _buildResult(),
                ],
              ),
            ),
          ],
        ),
      ),
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

  Widget _buildParamRow(
    String label,
    List<double?> options,
    double? current,
    ValueChanged<double?> onSelected,
    String Function(double?) format,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child:
              Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
        for (final opt in options) ...[
          ChoiceChip(
            label: Text(format(opt)),
            selected: current == opt,
            onSelected: (_) => onSelected(opt),
            selectedColor: CategoryColors.gif.withValues(alpha: 0.2),
            checkmarkColor: _accent,
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildResult() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Text('转换结果', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child:
              Image.file(File(_outputPath!), height: 200, fit: BoxFit.contain),
        ),
        const SizedBox(height: 8),
        Text(
          '${_formatBytes(_outputBytes ?? 0)} · $_frameCount 帧 · '
          '$_secondsPerFrame 秒/帧 · 循环播放',
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
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _reset, child: const Text('再转一个')),
          ],
        ),
      ],
    );
  }
}
