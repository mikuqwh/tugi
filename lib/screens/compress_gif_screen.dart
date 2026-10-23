/// Tugi - Compress GIFs screen.
///
/// Two modes, matching this app's `compress_mode`:
///
///  * **Reduce Resolution** (default): pick a ratio (80% / 50% / 20% / custom)
///    and the picture is scaled down.
///  * **Extract Frames**: keep one frame in every N, at the SAME resolution.
///    The previous implementation's strings (`extract_way`, `extract_2_1`, `extract_3_1`,
///    `extract_5_1`, `enter_extract_way`) and fragments (` -r 12`,
///    `-vf 'fps=`) describe a frame-rate reduction; see
///    [compressGifByFrames] for why the pipeline is `fps=` and not `select`.
///
/// Both modes show an ESTIMATED output size before running, from bands
/// measured by `tool/wmprobe/calibrate_compress.sh`.
// SPDX-License-Identifier: GPL-3.0-or-later

library compress_gif_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gal/gal.dart';

import '../services/compress_gif_service.dart';
import '../services/ffmpeg_progress.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/export_progress.dart';
import '../ui/rainbow_glow.dart';
import '../utils/gif_reader.dart' as gr;
import '../utils/size_estimate.dart';

enum _CompressMode { resolution, frames }

class CompressGifScreen extends StatefulWidget {
  const CompressGifScreen({super.key, this.initialGifPath});

  /// Pre-load a GIF instead of waiting for the picker. The picker cannot be
  /// driven by a test, so this is the seam the widget test uses.
  final String? initialGifPath;

  @override
  State<CompressGifScreen> createState() => _CompressGifScreenState();
}

class _CompressGifScreenState extends State<CompressGifScreen> {
  XFile? _gif;
  int _inputBytes = 0;
  double _ratio = 0.5;
  bool _compressing = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  String? _outputPath;
  int? _outputBytes;

  _CompressMode _mode = _CompressMode.resolution;

  /// Keep one frame in every [_frameStep].
  int _frameStep = 2;

  /// The source's frame count and average rate, for the Extract Frames mode
  /// and for its size estimate. Parsed once on pick.
  int _sourceFrames = 0;
  double _sourceFps = 0;

  static const _presets = <double>[0.8, 0.5, 0.2];
  static const _stepPresets = <int>[2, 3, 5];
  static const _accent = FeatureColors.compressGif;
  static const _on = FeatureColors.compressGifOn;

  @override
  void initState() {
    super.initState();
    final preset = widget.initialGifPath;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadGif(preset));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String get _ratioLabel => '${(_ratio * 100).round()}%';

  /// The estimate for whatever the current mode will run.
  SizeRange get _estimate {
    switch (_mode) {
      case _CompressMode.resolution:
        return estimateCompressedGif(_inputBytes, _ratio);
      case _CompressMode.frames:
        return estimateFrameStepGif(_inputBytes, _sourceFrames, _frameStep);
    }
  }

  Future<void> _pickGif() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked != null) await _loadGif(picked.path);
    } catch (e) {
      setState(() => _error = '选择 GIF 失败: $e');
    }
  }

  /// Test seam: load [path] through the production path.
  ///
  /// The load reads the file, so a widget test has to call this from inside
  /// `tester.runAsync` -- real I/O started in the fake async zone of
  /// `testWidgets` never completes.
  @visibleForTesting
  Future<void> loadGifForTest(String path) => _loadGif(path);

  Future<void> _loadGif(String path) async {
    try {
      final bytes = File(path).lengthSync();
      // Frame count and average rate drive both the Extract Frames mode and
      // its size estimate. A GIF that cannot be parsed leaves them at zero,
      // which the UI treats as "no estimate" rather than guessing.
      var frames = 0;
      var fps = 0.0;
      try {
        final info = gr.GifReader.parse(File(path).readAsBytesSync());
        if (info.frames > 0 && info.durationMs > 0) {
          frames = info.frames;
          fps = info.frames * 1000 / info.durationMs;
        }
      } catch (_) {
        // Fall through with no estimate.
      }
      setState(() {
        _gif = XFile(path);
        _inputBytes = bytes;
        _sourceFrames = frames;
        _sourceFps = fps;
        _outputPath = null;
        _outputBytes = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '选择 GIF 失败: $e');
    }
  }

  Future<void> _pickCustomRatio() async {
    final controller = TextEditingController(text: '${(_ratio * 100).round()}');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final typed = int.tryParse(controller.text.trim()) ?? 0;
          final preview = (typed >= 1 && typed <= 99)
              ? estimateCompressedGif(_inputBytes, typed / 100)
              : null;
          return AlertDialog(
            title: const Text('自定义压缩比例'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(
                    suffixText: '%',
                    hintText: '1 - 99',
                    helperText: '输出宽度 = 原宽度 × 比例',
                  ),
                ),
                const SizedBox(height: 12),
                // The estimate follows the number as it is typed: choosing a
                // ratio without knowing what it buys is the problem this
                // screen is trying to solve.
                Text(
                  preview == null
                      ? '输入 1 - 99 查看预计大小'
                      : '预计输出 ≈ ${_formatBytes(preview.lowBytes)} – '
                          '${_formatBytes(preview.highBytes)}',
                  style: TextStyle(
                    color: preview == null ? Colors.grey : Colors.black87,
                    fontWeight:
                        preview == null ? FontWeight.normal : FontWeight.w600,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  final v = int.tryParse(controller.text.trim());
                  if (v == null || v < 1 || v > 99) {
                    Navigator.pop(context, -1);
                  } else {
                    Navigator.pop(context, v);
                  }
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    if (result == -1) {
      setState(() => _error = '比例必须在 1 - 99 之间');
    } else if (result != null) {
      setState(() => _ratio = result / 100);
    }
  }

  /// Ask for a custom frame stride. Same live-estimate idea as the ratio
  /// dialog, because "每 7 帧抽 1 张" means nothing without a size.
  Future<void> _pickCustomStep() async {
    final controller = TextEditingController(text: '$_frameStep');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final value = int.tryParse(controller.text.trim()) ?? 0;
          final valid =
              value >= 2 && (_sourceFrames == 0 || value <= _sourceFrames);
          final preview = valid
              ? estimateFrameStepGif(_inputBytes, _sourceFrames, value)
              : null;
          return AlertDialog(
            title: const Text('自定义抽帧间隔'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    suffixText: '帧',
                    hintText: '2 - ${_sourceFrames > 0 ? _sourceFrames : 99}',
                    helperText: '每隔 N 帧保留 1 帧，时长不变',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  preview == null
                      ? '输入 2 及以上的间隔查看预计大小'
                      : '保留 ${(_sourceFrames / value).ceil()} 帧 · '
                          '预计 ≈ ${_formatBytes(preview.lowBytes)} – '
                          '${_formatBytes(preview.highBytes)}',
                  style: TextStyle(
                    color: preview == null ? Colors.grey : Colors.black87,
                    fontWeight:
                        preview == null ? FontWeight.normal : FontWeight.w600,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  final v = int.tryParse(controller.text.trim());
                  if (v == null ||
                      v < 2 ||
                      (_sourceFrames > 0 && v > _sourceFrames)) {
                    Navigator.pop(context, -1);
                  } else {
                    Navigator.pop(context, v);
                  }
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    if (result == -1) {
      setState(() => _error = '抽帧间隔必须在 2 到源帧数之间');
    } else if (result != null) {
      setState(() => _frameStep = result);
    }
    controller.dispose();
  }

  Future<void> _compress() async {
    final gif = _gif;
    if (gif == null) return;
    setState(() {
      _compressing = true;
      _progress = 0;
      _job = null;
      _error = null;
    });

    try {
      final dir = Directory.systemTemp;
      final service = CompressGifService(workDir: dir.path);
      final path = switch (_mode) {
        _CompressMode.resolution => await service.compress(
            inputPath: gif.path,
            ratio: _ratio,
            totalMs: _totalMs,
            onProgress: (v) {
              if (mounted) setState(() => _progress = v);
            },
            onJob: (job) => _job = job,
          ),
        _CompressMode.frames => await service.compressByFrameStep(
            inputPath: gif.path,
            frameStep: _frameStep,
            sourceFps: _sourceFps > 0 ? _sourceFps : 10,
            totalMs: _totalMs,
            onProgress: (v) {
              if (mounted) setState(() => _progress = v);
            },
            onJob: (job) => _job = job,
          ),
      };
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
          _compressing = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Total length of the selection, for the progress estimate.
  int? get _totalMs {
    if (_sourceFrames <= 0 || _sourceFps <= 0) return null;
    return ((_sourceFrames / _sourceFps) * 1000).round();
  }

  /// Stop the running compression.
  void _cancelCompress() => _job?.cancel();

  Future<void> _saveToGallery() async {
    final path = _outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    try {
      await Gal.putImage(path, album: 'Tugi');
      if (!mounted) return;
      await WorksService.instance.record(
        originPath: path,
        featureId: 'compress_gif',
        sourcePath: _gif?.path,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已存到相册')),
      );
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
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      setState(() => _error = '分享失败: $e');
    }
  }

  void _reset() {
    setState(() {
      _gif = null;
      _outputPath = null;
      _outputBytes = null;
      _error = null;
      _ratio = 0.5;
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
            accent: FeaturePalette.compressGif,
          ),
          title: const Text('Compress GIFs'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching the other screens: the
        // selected-GIF card stays put while the mode and ratio rows scroll
        // beneath it.
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
                  _buildModeRow(),
                  const SizedBox(height: 16),
                  Text(
                    _mode == _CompressMode.resolution ? 'Reduce to' : '抽帧间隔',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  if (_mode == _CompressMode.resolution)
                    _buildRatioRow()
                  else
                    _buildFrameStepRow(),
                  if (_gif != null) _buildEstimateLine(),
                  const SizedBox(height: 24),
                  if (_compressing)
                    ExportProgress(
                      progress: _progress,
                      label: '正在压缩…',
                      accent: _accent,
                      onColor: _on,
                      onCancel: _cancelCompress,
                    )
                  else
                    RainbowGlow(
                      child: ElevatedButton.icon(
                        key: const Key('compress_run'),
                        onPressed: _gif == null ? null : _compress,
                        icon: const Icon(Icons.compress),
                        label: const Text('Compress'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: _on,
                          disabledBackgroundColor:
                              _accent.withValues(alpha: 0.16),
                          disabledForegroundColor:
                              _accent.withValues(alpha: 0.55),
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
                  const Text('Selected GIF',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(_formatBytes(_inputBytes),
                      style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
            TextButton(onPressed: _pickGif, child: const Text('Reselect')),
          ],
        ),
      ),
    );
  }

  Widget _buildModeRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Compress mode',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _buildModeOption(
          title: 'Reduce Resolution',
          subtitle: '按比例缩小画面，帧数不变',
          selected: _mode == _CompressMode.resolution,
          onTap: () => setState(() => _mode = _CompressMode.resolution),
        ),
        _buildModeOption(
          title: 'Extract Frames',
          subtitle: '每隔 N 帧保留 1 帧，分辨率不变',
          selected: _mode == _CompressMode.frames,
          onTap: () => setState(() => _mode = _CompressMode.frames),
        ),
      ],
    );
  }

  Widget _buildModeOption({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final color = enabled ? Colors.black87 : Colors.grey;
    return ListTile(
      key: Key('compress_mode_${title.replaceAll(' ', '_')}'),
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? _accent : Colors.grey,
      ),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.grey)),
      onTap: onTap,
    );
  }

  Widget _buildRatioRow() {
    return Wrap(
      spacing: 8,
      children: [
        for (final p in _presets)
          ChoiceChip(
            label: Text('${(p * 100).round()}%'),
            selected: _ratio == p,
            onSelected: (_) => setState(() => _ratio = p),
            selectedColor: _accent.withValues(alpha: 0.3),
            checkmarkColor: Colors.black87,
          ),
        ChoiceChip(
          label:
              Text(_presets.contains(_ratio) ? 'Custom' : '$_ratioLabel（自定义）'),
          selected: !_presets.contains(_ratio),
          onSelected: (_) => _pickCustomRatio(),
          selectedColor: _accent.withValues(alpha: 0.3),
          checkmarkColor: Colors.black87,
        ),
      ],
    );
  }

  /// Keep one frame in every N: the previous implementation's `extract_2_1` / `3_1` / `5_1`.
  Widget _buildFrameStepRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final n in _stepPresets)
              ChoiceChip(
                key: Key('compress_step_$n'),
                label: Text('每 $n 帧'),
                selected: _frameStep == n,
                onSelected: (_) => setState(() => _frameStep = n),
                selectedColor: _accent.withValues(alpha: 0.3),
                checkmarkColor: Colors.black87,
              ),
            ChoiceChip(
              key: const Key('compress_step_custom'),
              label: Text(_stepPresets.contains(_frameStep)
                  ? 'Custom'
                  : '每 $_frameStep 帧（自定义）'),
              selected: !_stepPresets.contains(_frameStep),
              onSelected: (_) => _pickCustomStep(),
              selectedColor: _accent.withValues(alpha: 0.3),
              checkmarkColor: Colors.black87,
            ),
          ],
        ),
        if (_sourceFrames > 0) ...[
          const SizedBox(height: 8),
          Text(
            '源：$_sourceFrames 帧 · ${_sourceFps.toStringAsFixed(1)} fps'
            ' → 约 ${(_sourceFrames / _frameStep).ceil()} 帧 · '
            '${(_sourceFps / _frameStep).toStringAsFixed(1)} fps',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// "What will I get?" — the point of showing this at all is that only one
  /// of the two knobs (ratio or stride) is a real unit: a ratio means a
  /// percentage of pixels, not of bytes.
  Widget _buildEstimateLine() {
    final estimate = _estimate;
    if (!estimate.isValid) {
      return const SizedBox.shrink();
    }
    final savings = estimate.savingsPercent(_inputBytes);
    final saved = savings >= 0 ? '省 ${savings.round()}%' : '反而增加';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.insights, size: 16, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '预计输出 ≈ ${_formatBytes(estimate.lowBytes)} – '
              '${_formatBytes(estimate.highBytes)}（$saved）',
              key: const Key('compress_estimate'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final saved = (_inputBytes > 0 && _outputBytes != null)
        ? (100 - _outputBytes! * 100 / _inputBytes).round()
        : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Text('压缩结果', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(_outputPath!),
                      height: 72, width: 72, fit: BoxFit.cover),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$_ratioLabel · 节省 $saved%',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatBytes(_inputBytes)} → ${_formatBytes(_outputBytes ?? 0)}',
                        style: const TextStyle(color: Colors.grey),
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
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _reset, child: const Text('再压一个')),
          ],
        ),
      ],
    );
  }
}
