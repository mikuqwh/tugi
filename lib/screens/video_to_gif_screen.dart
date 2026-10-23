/// Tugi - Video to GIF screen.
///
/// Replaces the placeholder in main.dart that converted a hard-coded
/// `/sdcard/e2e_source.mp4`.
///
///   `-filter_complex [0:v]split[s1][s2];[s1]palettegen=stats_mode=single[p];
///   creations.db)
///
/// The previous implementation's in-app picker / video preview page could not be completed on
/// the emulator (its hardware video decoder never leaves the loading state
/// there), so the system picker is used instead, same as Compress GIFs.
/// Everything from the parameter page onwards follows the strings above.
// SPDX-License-Identifier: GPL-3.0-or-later

library video_to_gif_screen;

import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'package:format_core/format_core.dart';

import '../models/crop_rect.dart';
import '../models/encode_preset.dart';
import '../models/trim.dart';
import 'crop_screen.dart';
import '../services/filmstrip_service.dart';
import '../services/ffmpeg_progress.dart';
import '../services/video_to_gif_service.dart';
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

/// What the probe needs to know about the source: length and pixel size.
class VideoMeta {
  const VideoMeta({
    required this.seconds,
    required this.width,
    required this.height,
  });

  final double seconds;
  final int width;
  final int height;
}

class VideoToGifScreen extends StatefulWidget {
  const VideoToGifScreen({
    super.key,
    this.initialVideoPath,
    this.probeMedia,
    this.filmstrip,
  });

  /// Pre-load a video instead of waiting for the picker (works shelf).
  final String? initialVideoPath;

  /// Test seams: the host has no ffprobe channel and no ffmpeg for a strip.
  final Future<VideoMeta?> Function(String path)? probeMedia;
  final FilmstripService? filmstrip;

  /// ffprobe reports duration in seconds and size in pixels.
  static Future<VideoMeta?> probeVideoMeta(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = await session.getMediaInformation();
    if (info == null) return null;
    final seconds = double.tryParse(info.getDuration() ?? '') ?? 0;
    final streams = info.getStreams();
    final video = streams.where((s) => s.getType() == 'video').toList();
    final first = video.isEmpty ? null : video.first;
    return VideoMeta(
      seconds: seconds,
      width: (first?.getWidth() as num?)?.toInt() ??
          int.tryParse('${first?.getWidth() ?? 0}') ??
          0,
      height: (first?.getHeight() as num?)?.toInt() ??
          int.tryParse('${first?.getHeight() ?? 0}') ??
          0,
    );
  }

  @override
  State<VideoToGifScreen> createState() => _VideoToGifScreenState();
}

class _VideoToGifScreenState extends State<VideoToGifScreen> {
  @override
  void initState() {
    super.initState();
    final preset = widget.initialVideoPath;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyVideo(preset));
    }
  }

  /// Set the source without going through the picker (works shelf).
  void _applyVideo(String path) {
    if (!mounted) return;
    setState(() {
      _video = XFile(path);
      _inputBytes = File(path).lengthSync();
      _total = 0;
      _trim = const TrimRange(start: 0, end: 0);
      _strip = const [];
      _clearResult();
    });
    _loadMeta(path);
  }

  /// Duration and filmstrip, loaded after the file so the picker stays
  /// responsive. Both are optional: a probe failure just hides the timeline
  /// and the conversion runs on the whole file.
  Future<void> _loadMeta(String path) async {
    final meta =
        await (widget.probeMedia ?? VideoToGifScreen.probeVideoMeta)(path);
    if (!mounted || meta == null || meta.seconds <= 0) return;
    final strip = await (widget.filmstrip ?? FilmstripService())
        .frames(path: path, seconds: meta.seconds);
    if (!mounted) return;
    final poster = await (widget.filmstrip ?? FilmstripService())
        .posterFull(path: path, at: 0);
    if (!mounted) return;
    setState(() {
      _total = meta.seconds;
      _sourceWidth = meta.width;
      _sourceHeight = meta.height;
      _trim = TrimRange.whole(meta.seconds);
      _strip = strip;
    });
  }

  /// Open the crop editor on a still of the segment's first frame.
  Future<void> _openCrop() async {
    final video = _video;
    if (video == null || _sourceWidth <= 0 || _sourceHeight <= 0) return;
    final service = widget.filmstrip ?? FilmstripService();
    final poster = await service.posterFull(path: video.path, at: _trim.start);
    if (!mounted) return;
    final result = await Navigator.push<CropRect?>(
      context,
      tugiRoute(
        (_) => CropScreen(
          imagePath: poster ?? video.path,
          sourceWidth: _sourceWidth,
          sourceHeight: _sourceHeight,
          initial: _crop,
          accent: _accent,
          onColor: _on,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _crop = result;
        _clearResult();
      });
    }
  }

  static const _accent = FeatureColors.videoToGif;
  static const _on = FeatureColors.videoToGifOn;

  /// Output frame rates offered by the UI. 12 is the previous implementation's default
  static const _fpsOptions = <int>[6, 10, 12, 15, 20, 24];

  static const _widthOptions = <int?>[null, 1080, 720, 480, 240];

  XFile? _video;
  int _inputBytes = 0;
  int _fps = 12;
  int? _outputWidth;
  bool _dedup = false;
  bool _loop = true;

  /// Source length, 0 until the probe finishes.
  double _total = 0;

  /// The segment to convert; the whole file until the user drags a handle.
  TrimRange _trim = const TrimRange(start: 0, end: 0);

  /// Filmstrip thumbnails for the timeline (may be empty).
  List<String> _strip = const [];

  /// Source pixel size, for the crop editor (0 until the probe finishes).
  int _sourceWidth = 0;
  int _sourceHeight = 0;

  /// The selected crop; [CropRect.whole] means "keep the whole frame".
  CropRect _crop = CropRect.whole;

  bool _converting = false;
  bool _saving = false;

  /// 0..1 while ffmpeg runs; null means "working, no estimate yet".
  double? _progress;

  /// The running job, so the cancel button has something to cancel.
  FfmpegJob? _job;
  String? _error;
  String? _outputPath;
  int? _outputBytes;
  GifInfo? _outputInfo;

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await ImagePicker().pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 2),
      );
      if (picked == null) return;
      _applyVideo(picked.path);
    } catch (e) {
      setState(() => _error = '选择视频失败: $e');
    }
  }

  /// The scrub bar: pick the segment to convert.
  Widget _buildTrimSection() {
    return Column(
      key: const Key('video_trim_section'),
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
            // An icon instead of a full-width button: the row above the
            // timeline is where an editor puts crop, and it costs 32 px.
            IconButton(
              key: const Key('video_crop'),
              tooltip: _crop.isWhole ? '裁剪画面' : '已裁剪（点击修改）',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: _sourceWidth > 0 ? _openCrop : null,
              icon: Icon(
                _crop.isWhole ? Icons.crop : Icons.crop_free,
                size: 18,
                color: _crop.isWhole ? Neutrals.inkSoft : _accent,
              ),
            ),
            if (!_crop.isWhole)
              IconButton(
                key: const Key('video_crop_clear'),
                tooltip: '取消裁剪',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() {
                  _crop = CropRect.whole;
                  _clearResult();
                }),
                icon:
                    const Icon(Icons.close, size: 16, color: Neutrals.inkSoft),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TrimTimeline(
          key: const Key('video_trim'),
          total: _total,
          range: _trim,
          frames: _strip,
          fps: _fps.toDouble(),
          accent: _accent,
          onColor: _on,
          onChanged: (r) => setState(() {
            _trim = r;
            _clearResult();
          }),
        ),
      ],
    );
  }

  void _clearResult() {
    _outputPath = null;
    _outputBytes = null;
    _outputInfo = null;
  }

  /// GIF by default; APNG keeps full colour and alpha at the cost of size.
  FormatSpec _outputFormat = formatById('gif')!;

  /// How hard the encoder works (fast / balanced / high).
  EncodePreset _preset = EncodePreset.balanced;

  Future<void> _convert() async {
    final video = _video;
    if (video == null) return;
    setState(() {
      _converting = true;
      _progress = 0;
      _job = null;
      _error = null;
      _clearResult();
    });

    final service = VideoToGifService(
      workDir: Directory.systemTemp.path,
      format: _outputFormat,
    );
    try {
      final trimmed = _total > 0 && !(_trim.start <= 0 && _trim.end >= _total);
      final cropFilter = _crop.toFilter(_sourceWidth, _sourceHeight);
      // ffmpeg's time= counts the segment it encodes, not the whole file.
      final spanSeconds = trimmed ? _trim.duration : _total;
      final path = await service.convertDirect(
        videoPath: video.path,
        fps: _fps,
        outputWidth: _outputWidth,
        loop: _loop,
        dedup: _dedup,
        start: trimmed ? _trim.start : null,
        duration: trimmed ? _trim.duration : null,
        crop: cropFilter.isEmpty ? null : cropFilter,
        totalMs: spanSeconds > 0 ? (spanSeconds * 1000).round() : null,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        onJob: (job) => _job = job,
        preset: _preset,
      );
      final file = File(path);
      final info = _probeGif(file);
      service.cleanup();
      if (!mounted) return;
      setState(() {
        _outputPath = path;
        _outputBytes = file.lengthSync();
        _outputInfo = info;
      });
    } on FfmpegCancelled {
      service.cleanup();
      if (mounted) setState(() {});
    } catch (e) {
      service.cleanup();
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

  /// Stop the running conversion; the file is discarded.
  void _cancelConvert() {
    _job?.cancel();
  }

  /// Read frame count and total duration straight from the GIF bytes so the
  /// result card reports what was actually produced (which differs from
  /// `duration * fps` whenever [dedup] drops frames).
  ///
  /// This walks the GIF block chain instead of scanning for marker bytes: the
  /// LZW payload can legitimately contain `0x21 0xF9` / `0x21 0xFF` pairs,
  /// and a naive byte scan miscounts them as extra frames.
  GifInfo _probeGif(File file) {
    final bytes = file.readAsBytesSync();
    return GifReader.parse(bytes);
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
        featureId: 'video_to_gif',
        sourcePath: _video?.path,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已存到相册')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    final path = _outputPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      if (mounted) setState(() => _error = '分享失败: $e');
    }
  }

  void _reset() {
    setState(() {
      _video = null;
      _inputBytes = 0;
      _error = null;
      _clearResult();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Light surface, dark app theme: without this override the labels render
    // white-on-light (same fix as the GIFs to Images screen).
    return Theme(
      data: buildFeatureTheme(Accents.rose),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.videoToGif,
          ),
          title: const Text('Video to GIF'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Pinned subject / scrolling controls, matching Edit Image: the
        // selected-video card stays on screen while the parameters below
        // scroll, so the thing you are adjusting never scrolls away.
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _video == null
                  ? RainbowGlow(
                      child: ElevatedButton.icon(
                      onPressed: _pickVideo,
                      icon: const Icon(Icons.videocam),
                      label: const Text('选择视频'),
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
                  const SizedBox(height: 16),
                  EncodePresetPicker(
                    key: const Key('video_preset'),
                    value: _preset,
                    accent: _accent,
                    enabled: !_converting,
                    onChanged: (p) => setState(() {
                      _preset = p;
                      _clearResult();
                    }),
                  ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    key: const Key('video_more'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text(
                      '更多设置',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '宽度 ${_outputWidth == null ? '原始' : '${_outputWidth}px'}'
                      ' · ${_dedup ? '去重' : '保留全部帧'}'
                      ' · ${_loop ? '循环' : '播放一次'}'
                      ' · ${_outputFormat.label}',
                      style: const TextStyle(
                          fontSize: 11, color: Neutrals.inkSoft),
                    ),
                    children: [
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
                      const SizedBox(height: 8),
                      _buildToggles(),
                      const SizedBox(height: 12),
                      OutputFormatPicker(
                        key: const Key('anim_format'),
                        formats: [formatById('gif')!, formatById('apng')!],
                        selected: _outputFormat,
                        common: const ['gif', 'apng'],
                        onSelected: (f) => setState(() {
                          _outputFormat = f;
                          _clearResult();
                        }),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
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
            // The primary action never scrolls away: a thumb at the bottom of
            // a long parameter list had to scroll to export.
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  /// Bottom-docked export action: progress while running, the CTA otherwise.
  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: _converting
          ? ExportProgress(
              progress: _progress,
              label: '正在转换…',
              accent: _accent,
              onColor: _on,
              onCancel: _cancelConvert,
            )
          : RainbowGlow(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  key: const Key('video_export'),
                  onPressed: _video == null ? null : _convert,
                  icon: const Icon(Icons.gif),
                  label: const Text('转换为 GIF'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                    disabledForegroundColor: _accent.withValues(alpha: 0.55),
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
            ),
    );
  }

  /// The selected source, as a compact card.
  ///
  /// There used to be a square preview here with a frame-based player. It grew
  /// into a second editing surface that competed with the timeline and crop
  /// for attention (and screen space), so it is gone: the file name, size and
  /// length are what a trim screen actually needs above the strip.
  Widget _buildSelectedCard() {
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
            child: Icon(Icons.movie_outlined, color: _accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '已选视频',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatBytes(_inputBytes)}'
                  '${_total > 0 ? ' · ${formatSeconds(_total)}' : ''}',
                  style:
                      const TextStyle(fontSize: 11.5, color: Neutrals.inkSoft),
                ),
              ],
            ),
          ),
          _QuietButton(
            key: const Key('video_repick'),
            label: '重选',
            onPressed: _pickVideo,
          ),
        ],
      ),
    );
  }

  Widget _buildToggles() {
    return Wrap(
      spacing: 8,
      children: [
        FilterChip(
          label: const Text('循环播放'),
          selected: _loop,
          onSelected: (v) => setState(() {
            _loop = v;
            _clearResult();
          }),
          selectedColor: _accent.withValues(alpha: 0.2),
          checkmarkColor: _accent,
        ),
        FilterChip(
          label: const Text('去重（体积更小）'),
          selected: _dedup,
          onSelected: (v) => setState(() {
            _dedup = v;
            _clearResult();
          }),
          selectedColor: _accent.withValues(alpha: 0.2),
          checkmarkColor: _accent,
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

  Widget _buildResult() {
    // Everything below is measured from the produced file, not from the
    // parameters: dedup and fps rounding both make the real numbers differ
    // from `duration * fps`.
    final info = _outputInfo;
    final actualFps =
        (info != null && info.seconds > 0) ? info.frames / info.seconds : null;
    final parts = <String>[
      if (info != null) '${info.width}×${info.height}',
      if (info != null) '${info.frames} 帧',
      if (info != null) '${info.seconds.toStringAsFixed(1)} 秒',
      if (actualFps != null) '${actualFps.toStringAsFixed(1)} fps',
      if (_dedup) '已去重',
      if (info != null) (info.loops == 0 ? '循环播放' : '播放一次'),
    ];
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
        Text('${_formatBytes(_outputBytes ?? 0)} · ${parts.join(' · ')}'),
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

/// A small text button used inside cards, so the card does not need a full
/// Material button's padding.
class _QuietButton extends StatelessWidget {
  const _QuietButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
