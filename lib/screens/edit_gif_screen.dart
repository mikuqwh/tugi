// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi - Edit GIF screen (play speed + reverse).
///
///
/// The previous implementation takes a free numeric speed with a 0.1 floor (the validation
/// strings above); preset chips are added on top for reachability. The number
/// is the setpts multiplier: < 1 plays faster, > 1 plays slower (measured, see
/// commands.editGifSpeed). Result stats are parsed from the OUTPUT file with
/// GifReader, never extrapolated from duration * fps.
// SPDX-License-Identifier: GPL-3.0-or-later

library edit_gif_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'package:format_core/format_core.dart';

import '../models/crop_rect.dart';
import '../models/encode_preset.dart';
import '../models/trim.dart';
import 'crop_screen.dart';
import '../services/filmstrip_service.dart';
import '../services/edit_gif_service.dart';
import '../services/ffmpeg_progress.dart';
import '../ui/encode_preset_picker.dart';
import '../ui/export_progress.dart';
import '../ui/trim_timeline.dart';
import '../ui/output_format_picker.dart';
import '../services/works_service.dart';
import '../ui/page_transitions.dart';
import '../ui/app_palette.dart';
import '../ui/empty_state.dart';
import '../ui/rainbow_glow.dart';
import '../utils/gif_reader.dart';

class EditGifScreen extends StatefulWidget {
  const EditGifScreen({super.key, this.initialGifPath, this.filmstrip});

  /// Pre-load a GIF instead of waiting for the picker (works shelf).
  final String? initialGifPath;

  /// Test seam: the strip needs ffmpeg, which the host test binding lacks.
  final FilmstripService? filmstrip;

  @override
  State<EditGifScreen> createState() => _EditGifScreenState();
}

class _EditGifScreenState extends State<EditGifScreen> {
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
    final bytes = File(path).readAsBytesSync();
    setState(() {
      _gif = XFile(path);
      _inputBytes = bytes.length;
      try {
        _inputInfo = GifReader.parse(bytes);
      } catch (_) {
        _inputInfo = null;
      }
      final seconds = _inputInfo?.seconds ?? 0;
      _total = seconds;
      _trim = TrimRange.whole(seconds);
      _strip = const [];
      _error = null;
      _outputPath = null;
      _outputBytes = null;
      _outputInfo = null;
    });
    _loadStrip(path);
  }

  /// Filmstrip for the timeline; a failure only hides the thumbnails.
  Future<void> _loadStrip(String path) async {
    final seconds = _total;
    if (seconds <= 0) return;
    final strip = await (widget.filmstrip ?? FilmstripService())
        .frames(path: path, seconds: seconds);
    if (!mounted) return;
    setState(() => _strip = strip);
  }

  /// Source length in seconds (0 until the GIF parses).
  double _total = 0;

  /// Segment to keep; the whole GIF until a handle moves.
  TrimRange _trim = const TrimRange(start: 0, end: 0);

  /// Timeline thumbnails, possibly empty (see [TrimTimeline.frames]).
  List<String> _strip = const [];

  /// The selected crop; [CropRect.whole] means "keep the whole frame".
  CropRect _crop = CropRect.whole;

  /// Frames per second for the preview: the GIF's own average rate, clamped so
  /// a 100-frame 10 s GIF does not try to play at 10 fps in real time and cost
  /// a big extraction.
  double get _playbackFps {
    final info = _inputInfo;
    if (info == null || info.seconds <= 0) return 10;
    return (info.frames / info.seconds).clamp(5.0, 20.0);
  }

  static const _accent = FeatureColors.editGif;
  static const _on = FeatureColors.editGifOn;

  /// Measured setpts presets (params.setptsSpeeds) plus the 2.0 slow-motion
  /// end of the range.
  static const _speedPresets = <double>[0.2, 0.5, 0.8, 1.0, 1.1, 2.0];

  final _speedController = TextEditingController(text: '1.0');

  XFile? _gif;
  int _inputBytes = 0;
  GifInfo? _inputInfo;
  bool _reverse = false;

  bool _editing = false;

  /// 0..1 while ffmpeg runs; null means "working, no estimate yet".
  double? _progress;

  /// The running job, so the cancel button has something to cancel.
  FfmpegJob? _job;
  bool _saving = false;
  String? _error;
  String? _outputPath;
  int? _outputBytes;
  GifInfo? _outputInfo;

  @override
  void dispose() {
    _speedController.dispose();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// null when the text is not a number or is below the previous implementation's 0.1 floor.
  double? get _parsedSpeed {
    final v = double.tryParse(_speedController.text.trim());
    if (v == null || v < 0.1) return null;
    return v;
  }

  String? get _speedError {
    final text = _speedController.text.trim();
    if (text.isEmpty) return '请输入播放速度';
    final v = double.tryParse(text);
    if (v == null) return '播放速度必须是数字';
    if (v < 0.1) return '播放速度不能小于 0.1';
    return null;
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

  /// The scrub bar: keep only the segment between the handles.
  Widget _buildTrimSection() {
    return Column(
      key: const Key('gif_trim_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '保留片段',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const Spacer(),
            Text(
              '总长 ${formatSeconds(_total)}',
              style: const TextStyle(fontSize: 11.5, color: Neutrals.inkSoft),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: const Key('gif_crop'),
              tooltip: _crop.isWhole ? '裁剪画面' : '已裁剪（点击修改）',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: _openCrop,
              icon: Icon(
                _crop.isWhole ? Icons.crop : Icons.crop_free,
                size: 18,
                color: _crop.isWhole ? Neutrals.inkSoft : _accent,
              ),
            ),
            if (!_crop.isWhole)
              IconButton(
                key: const Key('gif_crop_clear'),
                tooltip: '取消裁剪',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() {
                  _crop = CropRect.whole;
                  _outputPath = null;
                  _outputBytes = null;
                  _outputInfo = null;
                }),
                icon:
                    const Icon(Icons.close, size: 16, color: Neutrals.inkSoft),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TrimTimeline(
          key: const Key('gif_trim'),
          total: _total,
          range: _trim,
          frames: _strip,
          fps: _inputInfo == null || _inputInfo!.seconds <= 0
              ? null
              : _inputInfo!.frames / _inputInfo!.seconds,
          accent: _accent,
          onColor: _on,
          onChanged: (r) => setState(() {
            _trim = r;
            _outputPath = null;
            _outputBytes = null;
            _outputInfo = null;
          }),
        ),
      ],
    );
  }

  /// Open the crop editor on the GIF's first frame.
  Future<void> _openCrop() async {
    final gif = _gif;
    final info = _inputInfo;
    if (gif == null || info == null || info.width <= 0) return;
    final service = widget.filmstrip ?? FilmstripService();
    final poster = await service.posterFull(path: gif.path, at: 0);
    if (!mounted) return;
    final result = await Navigator.push<CropRect?>(
      context,
      tugiRoute(
        (_) => CropScreen(
          imagePath: poster ?? gif.path,
          sourceWidth: info.width,
          sourceHeight: info.height,
          initial: _crop,
          accent: _accent,
          onColor: _on,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _crop = result;
        _outputPath = null;
        _outputBytes = null;
        _outputInfo = null;
      });
    }
  }

  /// GIF by default; APNG keeps full colour and alpha at the cost of size.
  FormatSpec _outputFormat = formatById('gif')!;

  /// How hard the encoder works (fast / balanced / high).
  EncodePreset _preset = EncodePreset.balanced;

  Future<void> _convert() async {
    final gif = _gif;
    if (gif == null) return;
    final speed = _parsedSpeed;
    if (speed == null) {
      setState(() => _error = _speedError);
      return;
    }
    setState(() {
      _editing = true;
      _progress = 0;
      _job = null;
      _error = null;
      _outputPath = null;
      _outputBytes = null;
      _outputInfo = null;
    });

    try {
      final service = EditGifService(workDir: Directory.systemTemp.path);
      final trimmed = _total > 0 && !(_trim.start <= 0 && _trim.end >= _total);
      final width = _inputInfo?.width ?? 0;
      final height = _inputInfo?.height ?? 0;
      final cropFilter = _crop.toFilter(width, height);
      final path = await service.edit(
        gifPath: gif.path,
        speedMultiplier: speed,
        reverse: _reverse,
        format: _outputFormat,
        start: trimmed ? _trim.start : null,
        end: trimmed ? _trim.end : null,
        crop: cropFilter.isEmpty ? null : cropFilter,
        // trim/end bound what gets decoded, so it is the span ffmpeg walks.
        totalMs: (_trim.end > 0 ? _trim.end : _total) * 1000 ~/ 1,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
        preset: _preset,
      );
      if (!mounted) return;
      setState(() {
        _outputPath = path;
        _outputBytes = File(path).lengthSync();
        _outputInfo = _outputFormat.id == 'apng'
            ? null
            : GifReader.parse(File(path).readAsBytesSync());
      });
    } on FfmpegCancelled {
      // The user stopped it: no error, no result.
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _editing = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Stop the running edit; the file is discarded.
  void _cancelEdit() {
    _job?.cancel();
  }

  Future<void> _saveToGallery() async {
    final path = _outputPath;
    if (path == null) return;
    setState(() => _saving = true);
    try {
      await Gal.putImage(path, album: 'Tugi');
      if (!mounted) return;
      await WorksService.instance.record(
        originPath: path,
        featureId: 'edit_gif',
        sourcePath: _gif?.path,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已存到相册')));
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    final path = _outputPath;
    if (path == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'Tugi'),
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
            accent: FeaturePalette.editGif,
          ),
          title: const Text('Edit GIF'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching the other screens:
        // the selected-GIF card (with its thumbnail) stays on screen while
        // the speed and reverse controls scroll beneath it.
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
                  if (_total > 0) ...[
                    _buildTrimSection(),
                    const SizedBox(height: 16),
                  ],
                  _buildSpeedSection(),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('反转播放（倒放）',
                        style: TextStyle(
                            fontWeight: FontWeight.w500, fontSize: 14)),
                    subtitle: const Text('帧顺序倒序，每帧时长保持不变',
                        style: TextStyle(fontSize: 12)),
                    value: _reverse,
                    activeThumbColor: _accent,
                    onChanged: (v) => setState(() {
                      _reverse = v;
                      _outputPath = null;
                      _outputBytes = null;
                      _outputInfo = null;
                    }),
                  ),
                  const SizedBox(height: 16),
                  EncodePresetPicker(
                    key: const Key('gif_preset'),
                    value: _preset,
                    accent: _accent,
                    enabled: !_editing,
                    onChanged: (p) => setState(() {
                      _preset = p;
                      _outputPath = null;
                      _outputBytes = null;
                      _outputInfo = null;
                    }),
                  ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    key: const Key('gif_more'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text(
                      '更多设置',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${_outputFormat.label} · ${_preset.label}',
                      style: const TextStyle(
                          fontSize: 11, color: Neutrals.inkSoft),
                    ),
                    children: [
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
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                  ResultReveal(
                    visible: _outputPath != null,
                    // Built lazily: _buildResult dereferences the output path.
                    child: _outputPath == null
                        ? const SizedBox.shrink()
                        : _buildResult(),
                  ),
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  /// Bottom-docked action: progress while running, CTA or result actions after.
  Widget _buildBottomBar() {
    if (_editing) {
      return SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: ExportProgress(
          progress: _progress,
          label: '正在处理…',
          accent: _accent,
          onColor: _on,
          onCancel: _cancelEdit,
        ),
      );
    }
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: _outputPath == null
          ? RainbowGlow(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  key: const Key('gif_export'),
                  onPressed: _gif == null ? null : _convert,
                  icon: const Icon(Icons.speed),
                  label: const Text('应用并转换'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                    disabledForegroundColor: _accent.withValues(alpha: 0.55),
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
            )
          : Row(
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
    );
  }

  Widget _buildSpeedSection() {
    final speed = _parsedSpeed;
    final error = _speedError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('播放速度',
            style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
        const SizedBox(height: 4),
        TextField(
          controller: _speedController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
          ],
          decoration: InputDecoration(
            isDense: true,
            suffixText: 'setpts 倍数',
            suffixStyle: const TextStyle(fontSize: 11, color: Colors.grey),
            errorText: error,
            border:
                const OutlineInputBorder(borderSide: BorderSide(width: 0.6)),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final opt in _speedPresets)
              ChoiceChip(
                label: Text('${opt}x'),
                selected: speed != null && speed == opt,
                onSelected: (_) =>
                    setState(() => _speedController.text = opt.toString()),
                selectedColor: _accent.withValues(alpha: 0.2),
                checkmarkColor: _accent,
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '小于 1 变快，大于 1 变慢（如 0.5 约 2 倍速，2.0 为半速慢放）',
          style: TextStyle(color: Colors.grey[600], fontSize: 12),
        ),
      ],
    );
  }

  /// The source file's preview frame: the same square, zoomable, clamped
  /// frame Edit Image uses.
  Widget _buildSelectedCard() {
    final info = _inputInfo;
    final subtitle = StringBuffer(_formatBytes(_inputBytes));
    if (info != null && info.isValidFrames) {
      subtitle.write(' · ${info.width}×${info.height} · '
          '${info.frames} 帧 · ${info.seconds.toStringAsFixed(1)} 秒');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Neutrals.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Neutrals.line),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.gif_box_outlined, color: _accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '已选 GIF',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle.toString(),
                  style:
                      const TextStyle(fontSize: 11.5, color: Neutrals.inkSoft),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('gif_repick'),
            onPressed: _pickGif,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            child: const Text('重选'),
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final info = _outputInfo;
    final speed = _parsedSpeed;
    final parts = <String>[
      if (info != null && info.isValidFrames) '${info.width}×${info.height}',
      if (info != null && info.isValidFrames) '${info.frames} 帧',
      if (info != null && info.seconds > 0)
        '${info.seconds.toStringAsFixed(2)} 秒',
      if (speed != null) '${speed}x',
      if (_reverse) '已反转',
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
              const Icon(Icons.edit_note, size: 40, color: _accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${_formatBytes(_outputBytes ?? 0)}'
                  '${parts.isNotEmpty ? ' · ${parts.join(' · ')}' : ''}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
