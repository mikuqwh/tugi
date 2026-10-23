// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - GIF to Video screen.
///
///   `The above selection is resolution width, height will be auto-calculated
///   `Chosen video exceeds 30MB, please lower the resolution, recommended
///
/// So the previous implementation lets the user either keep the source resolution or type a
/// width, and warns when the result would be too large. There is no hidden
/// no `iw*` string in this path at all).
// SPDX-License-Identifier: GPL-3.0-or-later

library gif_to_video_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'package:format_core/format_core.dart';

import '../services/export_service.dart';
import '../services/gif_to_video_service.dart';
import '../services/ffmpeg_progress.dart';
import '../ui/output_format_picker.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/export_progress.dart';
import '../ui/rainbow_glow.dart';
import '../utils/gif_reader.dart';
import '../utils/mp4_reader.dart';

class GifToVideoScreen extends StatefulWidget {
  const GifToVideoScreen({super.key, this.initialGifPath});

  /// Pre-load a GIF instead of waiting for the picker (tests/screenshots).
  final String? initialGifPath;

  @override
  State<GifToVideoScreen> createState() => _GifToVideoScreenState();
}

class _GifToVideoScreenState extends State<GifToVideoScreen> {
  static const _accent = FeatureColors.gifToVideo;
  static const _on = FeatureColors.gifToVideoOn;

  /// `fps` presets. Note this re-times the GIF, which changes the frame COUNT:
  /// a 77-frame / 5.14 s GIF yields 62 frames at 12 fps and all 77 at 15 fps.
  static const _fpsOptions = <int>[10, 12, 15, 20, 24, 30];

  /// null = keep the source resolution (the previous implementation's `keep_resolution`).
  static const _widthOptions = <int?>[null, 1080, 720, 480, 240];

  XFile? _gif;
  int _inputBytes = 0;
  GifInfo? _inputInfo;
  int _fps = 12;
  int? _outputWidth;

  /// Container/codec. Defaults to this app's H.264 MP4; the picker
  /// below offers the rest behind "更多格式".
  FormatSpec _format = formatById('mp4_h264')!;

  bool _converting = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  String? _outputPath;
  int? _outputBytes;
  Mp4Info? _outputInfo;

  @override
  void initState() {
    super.initState();
    final preset = widget.initialGifPath;
    if (preset != null && preset.isNotEmpty) {
      // Deferred: the file is read on the event loop and the first frame must
      // not be built before initState returns.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadGif(preset));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  void _clearResult() {
    _outputPath = null;
    _outputBytes = null;
    _outputInfo = null;
  }

  Future<void> _pickGif() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _loadGif(picked.path);
    } catch (e) {
      setState(() => _error = '选择 GIF 失败: $e');
    }
  }

  /// Test seam: load [path] through the production path.
  @visibleForTesting
  Future<void> loadGifForTest(String path) => _loadGif(path);

  Future<void> _loadGif(String path) async {
    try {
      {
        final bytes = File(path).readAsBytesSync();
        setState(() {
          _gif = XFile(path);
          _inputBytes = bytes.length;
          // Read the source up front so the frame-count warning below is real
          // rather than a guess from the file size.
          try {
            _inputInfo = GifReader.parse(bytes);
          } catch (_) {
            _inputInfo = null;
          }
          _error = null;
          _clearResult();
        });
      }
    } catch (e) {
      setState(() => _error = '选择 GIF 失败: $e');
    }
  }

  Future<void> _convert() async {
    final gif = _gif;
    if (gif == null) return;
    setState(() {
      _converting = true;
      _progress = 0;
      _job = null;
      _error = null;
      _clearResult();
    });

    try {
      final service = GifToVideoService(
        workDir: Directory.systemTemp.path,
        format: _format,
      );
      final ms = (_inputInfo?.seconds ?? 0) * 1000;
      final path = await service.convert(
        gifPath: gif.path,
        fps: _fps,
        outputWidth: _outputWidth,
        totalMs: ms > 0 ? ms.round() : null,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
      );
      if (!mounted) return;
      setState(() {
        _outputPath = path;
        _outputBytes = File(path).lengthSync();
        // Mp4Info parses the mp4 box structure; a WebM/MKV output has none.
        _outputInfo = _format.extension == 'mp4' ? Mp4Info.probe(path) : null;
      });
    } on FfmpegCancelled {
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
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

  /// Stop the running conversion.
  void _cancelConvert() => _job?.cancel();

  Future<void> _saveToGallery() async {
    final path = _outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    // The container can be WebM/MKV now; the shared service routes by type and
    // falls back to the system save dialog if the gallery refuses it.
    final outcome = await ExportService().save(path, album: 'Tugi');
    if (!mounted) {
      setState(() => _saving = false);
      return;
    }
    setState(() => _saving = false);
    if (outcome.isSuccess) {
      await WorksService.instance.record(
        originPath: path,
        featureId: 'gif_to_video',
        sourcePath: _gif?.path,
      );
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (outcome.status) {
        ExportStatus.savedToGallery => '已存到相册',
        ExportStatus.savedToFile => outcome.message ?? '已保存到文件',
        ExportStatus.cancelled => '已取消',
        ExportStatus.failed => outcome.message ?? '保存失败',
      }),
    ));
  }

  Future<void> _share() async {
    final path = _outputPath;
    if (path == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'Tugi'),
    );
  }

  void _reset() {
    setState(() {
      _gif = null;
      _inputBytes = 0;
      _inputInfo = null;
      _error = null;
      _clearResult();
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
            accent: FeaturePalette.gifToVideo,
          ),
          title: const Text('GIF to Video'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching the other screens.
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
                        foregroundColor: Colors.white,
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
                    label: '帧率',
                    options: _fpsOptions,
                    current: _fps,
                    format: (v) => '$v fps',
                    onSelected: (v) => setState(() {
                      _fps = v;
                      _clearResult();
                    }),
                  ),
                  const SizedBox(height: 12),
                  _buildParamRow(
                    label: '输出宽度',
                    options: _widthOptions,
                    current: _outputWidth,
                    format: (v) => v == null ? '原始' : '$v px',
                    onSelected: (v) => setState(() {
                      _outputWidth = v;
                      _clearResult();
                    }),
                  ),
                  if (_fpsWarning != null) ...[
                    const SizedBox(height: 10),
                    Text(_fpsWarning!,
                        style: const TextStyle(
                            color: Colors.orange, fontSize: 12)),
                  ],
                  const SizedBox(height: 12),
                  OutputFormatPicker(
                    key: const Key('gif2video_format'),
                    // Video containers only: a GIF has no audio, so offering
                    // MP3/WAV here would be a menu of broken promises.
                    formats: formatsFor(MediaKind.video)
                        .where((f) => f.kind == MediaKind.video)
                        .toList(),
                    selected: _format,
                    common: const ['mp4_h264', 'mp4_h265', 'webm_vp9'],
                    onSelected: (f) => setState(() {
                      _format = f;
                      _clearResult();
                    }),
                  ),
                  const SizedBox(height: 24),
                  if (_converting)
                    ExportProgress(
                      progress: _progress,
                      label: '正在转换…',
                      accent: _accent,
                      onColor: _on,
                      onCancel: _cancelConvert,
                    )
                  else if (_outputPath == null)
                    RainbowGlow(
                        child: ElevatedButton.icon(
                      key: const Key('gif_to_video_run'),
                      onPressed: _gif == null ? null : _convert,
                      icon: const Icon(Icons.movie_outlined),
                      label: const Text('转换为视频'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
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
                            onPressed: _saving ? null : _saveToGallery,
                            icon: const Icon(Icons.save_alt),
                            label: Text(_saving ? '保存中…' : '存到相册'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white,
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
                            onPressed: _share,
                            icon: const Icon(Icons.share),
                            label: const Text('分享'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                            onPressed: _reset, child: const Text('重选')),
                      ],
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12)),
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

  /// `fps` resamples rather than just retiming, so a low value silently drops
  /// frames. Say so instead of letting the user wonder.
  String? get _fpsWarning {
    final info = _inputInfo;
    if (info == null || info.seconds <= 0) return null;
    final sourceFps = info.frames / info.seconds;
    if (sourceFps <= _fps + 0.5) return null;
    return '源 GIF 约 ${sourceFps.toStringAsFixed(1)} fps，'
        '选 $_fps fps 会丢帧（预计输出约 '
        '${(info.seconds * _fps).round()} 帧 / ${info.frames} 帧）';
  }

  Widget _buildSelectedCard() {
    final info = _inputInfo;
    final subtitle = StringBuffer(_formatBytes(_inputBytes));
    if (info != null && info.isValidFrames) {
      subtitle.write(' · ${info.width}×${info.height} · '
          '${info.frames} 帧 · ${info.seconds.toStringAsFixed(1)} 秒');
    }
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
                  Text(subtitle.toString(),
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            TextButton(
              onPressed: _pickGif,
              child: const Text('重选'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult() {
    final info = _outputInfo;
    final parts = <String>[
      if (info != null && info.isValid) '${info.width}×${info.height}',
      if (info != null && info.seconds > 0)
        '${info.seconds.toStringAsFixed(1)} 秒',
      '$_fps fps',
      'H.264',
    ];
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
          child: Row(
            children: [
              const Icon(Icons.play_circle_outline, size: 40, color: _accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${_formatBytes(_outputBytes ?? 0)} · ${parts.join(' · ')}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ],
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
}
