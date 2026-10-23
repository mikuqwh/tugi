/// Tugi - GIFs to Images screen (frame extraction).
///
/// Original-app behavior observed on device 2026-10-15:
///   home card "GIFs to Images" -> in-app picker (album chips + multi-select)
///   -> animated preview with "N/M" pager -> Confirm -> extraction screen
///   -> "Confirm to save all frames?" before writing to the gallery.
///
/// The in-app picker is not reproduced here (the system PhotoPicker is used
/// instead, same as Compress GIFs); everything downstream of Confirm is.
///
// SPDX-License-Identifier: GPL-3.0-or-later

library gif_to_images_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'package:format_core/format_core.dart';

import '../services/ffmpeg_progress.dart';
import '../services/gif_to_images_service.dart';
import '../ui/output_format_picker.dart';
import '../services/works_service.dart';
import '../ui/export_progress.dart';
import '../ui/app_palette.dart';
import '../ui/rainbow_glow.dart';

class GifToImagesScreen extends StatefulWidget {
  const GifToImagesScreen({super.key, this.initialGifPath});

  /// Pre-load a GIF instead of waiting for the picker (works shelf).
  final String? initialGifPath;

  @override
  State<GifToImagesScreen> createState() => _GifToImagesScreenState();
}

class _GifToImagesScreenState extends State<GifToImagesScreen> {
  @override
  void initState() {
    super.initState();
    final preset = widget.initialGifPath;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyGif(preset));
    }
  }

  /// Set the source without going through the picker (works shelf).
  void _applyGif(String path) {
    if (!mounted) return;
    _service?.cleanup();
    setState(() {
      _gif = XFile(path);
      _inputBytes = File(path).lengthSync();
      _frames = const [];
      _error = null;
    });
  }

  static const _accent = FeatureColors.gifToImages;
  static const _on = FeatureColors.gifToImagesOn;

  /// An every-Nth-frame selector (`framestep=`).
  static const _framesteps = <int>[1, 2, 3, 5, 10];

  /// Also offered: `original_resolution` plus aspect presets.
  static const _widths = <int?>[null, 1080, 720, 480];

  GifToImagesService? _service;
  XFile? _gif;
  int _inputBytes = 0;
  int _framestep = 1;

  /// Frames are PNG by default. JPEG/WebP are the common "smaller" choices;
  /// BMP hides behind 更多格式. All four can be re-decoded by Flutter, which
  /// matters because this screen renders the frames in a grid.
  FormatSpec _format = formatById('png')!;
  int? _outputWidth;

  bool _extracting = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  List<String> _frames = const [];

  @override
  void dispose() {
    _service?.cleanup();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _pickGif() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      _applyGif(picked.path);
    } catch (e) {
      setState(() => _error = '选择 GIF 失败: $e');
    }
  }

  Future<void> _extract() async {
    final gif = _gif;
    if (gif == null) return;
    setState(() {
      _extracting = true;
      _progress = 0;
      _job = null;
      _error = null;
    });

    try {
      final service = GifToImagesService(workDir: Directory.systemTemp.path);
      final ms = 0;
      final frames = await service.extractFrames(
        gif.path,
        framestep: _framestep,
        outputWidth: _outputWidth,
        totalMs: ms > 0 ? ms : null,
        onFfmpegProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
        format: _format,
      );
      if (!mounted) {
        service.cleanup();
        return;
      }
      setState(() {
        _service = service;
        _frames = frames;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _extracting = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Stop the running extraction.
  void _cancelExtract() => _job?.cancel();

  /// Ask "save all frames?" before touching the gallery.
  Future<void> _saveAll() async {
    if (_frames.isEmpty || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('保存全部 ${_frames.length} 帧？'),
        content: Text('所有帧将以 ${_format.label} 存入系统相册。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Gal has no batch API, so save one by one. Frames are small PNGs; a
      // few hundred sequential writes is acceptable and reports real errors.
      for (final frame in _frames) {
        await Gal.putImage(frame, album: 'Tugi');
      }
      // The shelf keeps the whole frame sequence, so a run can be found again
      // later without hunting through the gallery.
      for (final frame in _frames) {
        await WorksService.instance.record(
          originPath: frame,
          featureId: 'gif_to_images',
          sourcePath: _gif?.path,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 ${_frames.length} 张 ${_format.label} 到相册')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _shareAll() async {
    if (_frames.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: _frames.map((f) => XFile(f)).toList()),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '分享失败: $e');
    }
  }

  void _reset() {
    _service?.cleanup();
    setState(() {
      _service = null;
      _frames = const [];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.rose),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.gifToImages,
          ),
          title: const Text('GIFs to Images'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching the other screens.
        // The extracted-frame grid is the result the user is here for, so it
        // stays at the bottom of the scroll view instead of being pushed
        // out of reach by the parameter rows.
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _gif == null
                  ? RainbowGlow(
                      child: ElevatedButton.icon(
                      onPressed: _pickGif,
                      icon: const Icon(Icons.gif),
                      label: const Text('选择 GIF'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: _on,
                        disabledBackgroundColor:
                            _accent.withValues(alpha: 0.16),
                        disabledForegroundColor:
                            _accent.withValues(alpha: 0.55),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ))
                  : _buildSelectedCard(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  _buildParamRow(
                    label: '抽帧间隔',
                    options: _framesteps,
                    current: _framestep,
                    format: (v) => v == 1 ? '每帧' : '每 $v 帧',
                    onSelected: (v) => setState(() {
                      _framestep = v;
                      _frames = const [];
                    }),
                  ),
                  const SizedBox(height: 12),
                  _buildParamRow(
                    label: '输出宽度',
                    options: _widths,
                    current: _outputWidth,
                    format: (v) => v == null ? '原始' : '$v px',
                    onSelected: (v) => setState(() {
                      _outputWidth = v;
                      _frames = const [];
                    }),
                  ),
                  const SizedBox(height: 12),
                  OutputFormatPicker(
                    key: const Key('gif2img_format'),
                    formats: [
                      formatById('png')!,
                      formatById('jpg')!,
                      formatById('webp')!,
                      formatById('bmp')!,
                    ],
                    selected: _format,
                    common: const ['png', 'jpg', 'webp'],
                    onSelected: (f) => setState(() {
                      _format = f;
                      _frames = const [];
                    }),
                  ),
                  const SizedBox(height: 24),
                  if (_frames.isEmpty)
                    RainbowGlow(
                        child: ElevatedButton.icon(
                      onPressed:
                          (_gif == null || _extracting) ? null : _extract,
                      icon: const Icon(Icons.crop_free),
                      label: Text(_extracting ? '抽取中…' : '抽取帧'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: _on,
                        disabledBackgroundColor:
                            _accent.withValues(alpha: 0.16),
                        disabledForegroundColor:
                            _accent.withValues(alpha: 0.55),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ))
                  else
                    Row(
                      children: [
                        Expanded(
                          child: RainbowGlow(
                              child: ElevatedButton.icon(
                            onPressed: _saving ? null : _saveAll,
                            icon: const Icon(Icons.save_alt),
                            label: Text(_saving ? '保存中…' : '存到相册'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: _on,
                              disabledBackgroundColor:
                                  _accent.withValues(alpha: 0.16),
                              disabledForegroundColor:
                                  _accent.withValues(alpha: 0.55),
                            ),
                          )),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _shareAll,
                            icon: const Icon(Icons.share),
                            label: const Text('分享'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                            onPressed: _reset, child: const Text('重抽')),
                      ],
                    ),
                  if (_extracting) ...[
                    const SizedBox(height: 12),
                    ExportProgress(
                      progress: _progress,
                      label: '正在抽帧…',
                      accent: _accent,
                      onColor: _on,
                      onCancel: _cancelExtract,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  if (_frames.isNotEmpty) _buildFrameGrid(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(_gif!.path),
                  height: 64, width: 64, fit: BoxFit.cover),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('已选 GIF',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(_formatBytes(_inputBytes),
                      style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
            TextButton(onPressed: _pickGif, child: const Text('重选')),
          ],
        ),
      ),
    );
  }

  Widget _buildParamRow<T>({
    required String label,
    required List<T> options,
    required T current,
    required String Function(T) format,
    required ValueChanged<T> onSelected,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(label,
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
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
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFrameGrid() {
    final totalBytes =
        _frames.fold<int>(0, (sum, p) => sum + File(p).lengthSync());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text('抽取结果 · ${_frames.length} 帧 · ${_formatBytes(totalBytes)}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _frames.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemBuilder: (context, i) => Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(_frames[i]), fit: BoxFit.cover),
              ),
              Positioned(
                left: 2,
                top: 2,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${i + 1}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
