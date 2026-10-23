// SPDX-License-Identifier: GPL-3.0-or-later

/// Universal format conversion (Tugi S3).
///
/// One screen, three paths, chosen by what the FILE is rather than by what the
/// user picked: ffprobe decides if the source is a still image, an animation,
/// a video or audio, and the target grid follows.
///
/// Two honesty rules carried over from S1:
///  * formats this ffmpeg build cannot write are shown greyed out with a
///    tooltip, not hidden;
///  * the estimate says what it is. Audio is arithmetic, uncompressed images
///    are pixel maths, compressed images are a measured band, video gets no
///    number at all because a CRF encode's size is a property of the content.
// SPDX-License-Identifier: GPL-3.0-or-later

library format_convert_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:format_core/format_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../convert/capability_probe.dart';
import '../services/convert_service.dart';
import '../services/ffmpeg_progress.dart';
import '../services/export_service.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/empty_state.dart';
import '../ui/export_progress.dart';
import '../ui/rainbow_glow.dart';
import '../utils/size_estimate.dart';

class FormatConvertScreen extends StatefulWidget {
  const FormatConvertScreen({
    super.key,
    this.initialSourcePath,
    this.probeOverride,
    this.convertOverride,
    this.availableOverride,
  });

  final String? initialSourcePath;

  /// Injected probe/converter: FFprobeKit and FFmpegKit only exist on a device.
  final Future<ConvertSource?> Function(String path)? probeOverride;
  final Future<String> Function(ConvertRequest request)? convertOverride;

  final Set<String>? availableOverride;

  @override
  State<FormatConvertScreen> createState() => _FormatConvertScreenState();
}

class _FormatConvertScreenState extends State<FormatConvertScreen> {
  static const _cyan = Color(0xFF00A6C2);
  static const _on = FeatureColors.formatConvertOn;

  final _picker = ImagePicker();

  ConvertSource? _source;
  FormatSpec? _format;
  String? _error;

  int _quality = 85;
  int? _width;
  double? _fps;
  bool _dropAudio = false;
  bool _hardware = false;
  bool _busy = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;

  String? _outputPath;
  int? _outputBytes;

  Set<String>? _available;

  ConvertService get _service =>
      ConvertService(workDir: Directory.systemTemp.path);

  @override
  void initState() {
    super.initState();
    final preset = widget.initialSourcePath;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(preset));
    }
    if (widget.availableOverride != null) {
      _available = widget.availableOverride;
    } else {
      _loadCapabilities();
    }
  }

  Future<void> _loadCapabilities() async {
    try {
      final names = await CapabilityProbe().availableNames();
      if (mounted) setState(() => _available = names);
    } catch (_) {
      if (mounted) setState(() => _available = const {});
    }
  }

  /// Test seam: load [path] through the production probe path.
  @visibleForTesting
  Future<void> loadSourceForTest(String path) => _load(path);

  Future<ConvertSource?> _probe(String path) {
    final override = widget.probeOverride;
    return override != null ? override(path) : _service.probe(path);
  }

  Future<void> _pick() async {
    try {
      final picked = await _picker.pickMedia();
      if (picked != null) await _load(picked.path);
    } catch (e) {
      setState(() => _error = '选择文件失败: $e');
    }
  }

  Future<void> _load(String path) async {
    final source = await _probe(path);
    if (!mounted) return;
    setState(() {
      _source = source;
      _outputPath = null;
      _outputBytes = null;
      _hardware = false;
      _dropAudio = false;
      _width = null;
      _fps = null;
      _error = source == null ? '无法读取这个文件' : null;
      _format = source == null ? null : _defaultFormatFor(source);
      if (_format != null) _quality = defaultQualityFor(_format!.quality);
    });
  }

  /// The target that needs the fewest choices: same family, sensible default.
  FormatSpec? _defaultFormatFor(ConvertSource source) {
    final rows = availabilityFor(_available ?? const {}, source.kind)
        .where((r) => r.$2)
        .toList();
    if (rows.isEmpty) return null;
    final preferred = switch (source.kind) {
      MediaKind.audio => 'mp3',
      MediaKind.video => 'mp4_h264',
      MediaKind.image || MediaKind.animated => 'jpg',
    };
    for (final row in rows) {
      if (row.$1.id == preferred) return row.$1;
    }
    return rows.first.$1;
  }

  Future<void> _convert() async {
    final source = _source;
    final format = _format;
    if (source == null || format == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _job = null;
      _error = null;
    });
    try {
      final request = ConvertRequest(
        source: source,
        format: format,
        quality: _quality,
        width: _width,
        fps: _fps,
        dropAudio: _dropAudio,
        hardware: _hardware,
      );
      final override = widget.convertOverride;
      final spanMs = source.duration.inMilliseconds;
      final path = override != null
          ? await override(request)
          : await _service.convert(
              request,
              totalMs: spanMs > 0 ? spanMs : null,
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
      // Cancelled by the user: no error, no result.
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Stop the running conversion.
  void _cancelConvert() => _job?.cancel();

  /// Where the file goes is decided by what it IS: the gallery cannot hold
  /// audio, so an MP3 gets the system save dialog instead (mainActivity's
  /// `tugi/export` channel). A gallery refusal on an image/video falls back to
  /// the same dialog rather than failing.
  Future<void> _save() async {
    final path = _outputPath;
    if (path == null) return;
    final outcome = await ExportService().save(path, album: 'Tugi');
    if (!mounted) return;
    final message = switch (outcome.status) {
      ExportStatus.savedToGallery => '已存到相册',
      ExportStatus.savedToFile => outcome.message ?? '已保存到文件',
      ExportStatus.cancelled => '已取消',
      ExportStatus.failed => outcome.message ?? '保存失败',
    };
    if (outcome.isSuccess) {
      await WorksService.instance.record(
        originPath: path,
        featureId: 'format_convert',
        sourcePath: _source?.path,
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

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _duration(Duration d) {
    if (d.inMilliseconds <= 0) return '';
    final m = d.inMinutes;
    final s = (d.inMilliseconds / 1000) % 60;
    return m > 0
        ? '$m:${s.toStringAsFixed(1).padLeft(4, '0')}'
        : '${s.toStringAsFixed(1)} 秒';
  }

  String get _kindLabel => switch (_source?.kind) {
        MediaKind.image => '图片',
        MediaKind.animated => '动图',
        MediaKind.video => '视频',
        MediaKind.audio => '音频',
        null => '',
      };

  @override
  Widget build(BuildContext context) {
    final source = _source;
    return Theme(
      data: buildFeatureTheme(Accents.cyan),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.formatConvert,
          ),
          title: const Text('Format convert'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Everything lives in ONE scrolling column (the Images-to-Video
        // layout): the picker or the source card is simply the first item.
        // The old split -- pinned subject above, controls below -- was built
        // for screens with many controls, and made these two feel heavier
        // than they are.
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            source == null
                ? RainbowGlow(
                    child: ElevatedButton.icon(
                    key: const Key('convert_pick'),
                    onPressed: _pick,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('选择文件'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _cyan,
                      foregroundColor: _on,
                      disabledBackgroundColor: _cyan.withValues(alpha: 0.16),
                      disabledForegroundColor: _cyan.withValues(alpha: 0.55),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ))
                : _buildSourceCard(source),
            const SizedBox(height: 12),
            if (source == null) _buildIntro(),
            // Options are visible before a file is picked (Images-to-Video
            // layout). Until a file arrives the grid previews the image
            // formats and stays non-selectable.
            _buildFormatGrid(source),
            if (source == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '选好文件后，这里会按内容列出可选格式。',
                  style: TextStyle(fontSize: 12, color: Neutrals.inkSoft),
                ),
              ),
            if (source != null && _format != null) ...[
              const SizedBox(height: 16),
              ..._buildParams(source),
              const SizedBox(height: 12),
              _buildEstimate(source),
              const SizedBox(height: 20),
              // The one rainbow element on this screen (brand spec §9.3).
              if (_busy)
                ExportProgress(
                  progress: _progress,
                  label: '正在转换…',
                  accent: _cyan,
                  onColor: _on,
                  onCancel: _cancelConvert,
                )
              else
                RainbowGlow(
                  child: ElevatedButton.icon(
                    key: const Key('convert_run'),
                    onPressed: (_source == null || _busy) ? null : _convert,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始转换'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _cyan,
                      foregroundColor: _on,
                      disabledBackgroundColor: _cyan.withValues(alpha: 0.16),
                      disabledForegroundColor: _cyan.withValues(alpha: 0.55),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
            ],
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
    );
  }

  Widget _buildIntro() {
    return const Text(
      '图片、动图、视频、音频互转。\n'
      '源文件类型由内容判断，不看扩展名；本设备写不了的格式会置灰并说明原因。',
      style: TextStyle(color: Neutrals.inkSoft, height: 1.5),
    );
  }

  Widget _buildSourceCard(ConvertSource source) {
    final bits = [
      _kindLabel,
      if (source.width > 0) source.sizeLabel,
      if (source.bytes > 0) _bytes(source.bytes),
      if (source.duration > Duration.zero) _duration(source.duration),
      if (source.kind == MediaKind.animated && source.frames > 0)
        '${source.frames} 帧',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _cyan.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                switch (source.kind) {
                  MediaKind.audio => Icons.audiotrack,
                  MediaKind.video => Icons.movie_outlined,
                  MediaKind.animated => Icons.gif,
                  MediaKind.image => Icons.image_outlined,
                },
                color: _cyan,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.path.split(Platform.pathSeparator).last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(bits.join(' · '),
                      style: const TextStyle(
                          color: Neutrals.inkSoft, fontSize: 12)),
                ],
              ),
            ),
            TextButton(onPressed: _pick, child: const Text('更换')),
          ],
        ),
      ),
    );
  }

  Widget _buildFormatGrid(ConvertSource? source) {
    final rows = availabilityFor(
      _available ?? const {},
      source?.kind ?? MediaKind.image,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('输出格式', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (spec, available) in rows)
              ChoiceChip(
                key: Key('convert_format_${spec.id}'),
                label: Text(spec.label),
                selected: _format?.id == spec.id,
                onSelected: available ? (_) => _selectFormat(spec) : null,
                selectedColor: _cyan.withValues(alpha: 0.22),
                checkmarkColor: _on,
                tooltip: available ? spec.note : '这个 ffmpeg 构建不支持',
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _format?.note ?? '',
          style: const TextStyle(color: Neutrals.inkSoft, fontSize: 12),
        ),
        if (source != null &&
            _format?.kind == MediaKind.image &&
            source.kind == MediaKind.animated) ...[
          const SizedBox(height: 8),
          _notice('动图转静态格式只会保留第一帧'),
        ],
        if (_source != null &&
            !(_format?.supportsAlpha ?? true) &&
            _source!.hasAlpha) ...[
          const SizedBox(height: 8),
          _notice('源图带透明通道，输出格式不支持透明，将垫上白色背景'),
        ],
      ],
    );
  }

  Widget _notice(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0DC),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: Color(0xFFFF9500)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  void _selectFormat(FormatSpec spec) {
    setState(() {
      _format = spec;
      _quality = defaultQualityFor(spec.quality);
      _outputPath = null;
      _outputBytes = null;
    });
  }

  List<Widget> _buildParams(ConvertSource source) {
    final format = _format!;
    switch (format.kind) {
      case MediaKind.audio:
        if (format.quality != QualityPolicy.audioBitrate) {
          return const [SizedBox.shrink()];
        }
        return [
          _slider(
            key: const Key('convert_quality'),
            label: '音质',
            valueLabel: '$_quality kbps',
            value: _quality.toDouble().clamp(32, 320),
            min: 32,
            max: 320,
            divisions: 36,
            onChanged: (v) => setState(() => _quality = (v / 8).round() * 8),
          ),
        ];
      case MediaKind.video:
        return [
          _slider(
            key: const Key('convert_quality'),
            label: '画质',
            valueLabel: '$_quality',
            value: _quality.toDouble().clamp(10, 100),
            min: 10,
            max: 100,
            divisions: 18,
            onChanged: (v) => setState(() => _quality = v.round()),
          ),
          const SizedBox(height: 8),
          _chips(
            label: '分辨率',
            options: const [
              (null, '原始'),
              (1080, '1080p'),
              (720, '720p'),
              (480, '480p'),
            ],
            selected: _width,
            onSelected: (v) => setState(() => _width = v),
          ),
          const SizedBox(height: 8),
          _chips(
            label: '帧率',
            options: const [
              (null, '原始'),
              (30, '30'),
              (24, '24'),
              (15, '15'),
            ],
            selected: _fps?.toInt(),
            onSelected: (v) => setState(() => _fps = v?.toDouble()),
          ),
          if (source.hasAudio)
            SwitchListTile(
              key: const Key('convert_keep_audio'),
              contentPadding: EdgeInsets.zero,
              title: const Text('保留音频'),
              value: !_dropAudio,
              onChanged: (v) => setState(() => _dropAudio = !v),
            ),
          SwitchListTile(
            key: const Key('convert_hardware'),
            contentPadding: EdgeInsets.zero,
            title: const Text('硬件编码（更快，仅 H.264/H.265）'),
            value: _hardware,
            onChanged: (v) => setState(() => _hardware = v),
          ),
        ];
      case MediaKind.image:
      case MediaKind.animated:
        if (format.quality == QualityPolicy.none) {
          return const [SizedBox.shrink()];
        }
        return [
          format.quality == QualityPolicy.audioBitrate
              ? const SizedBox.shrink()
              : _slider(
                  key: const Key('convert_quality'),
                  label: '质量',
                  valueLabel: '$_quality',
                  value: _quality.toDouble().clamp(10, 100),
                  min: 10,
                  max: 100,
                  divisions: 18,
                  onChanged: (v) => setState(() => _quality = v.round()),
                ),
        ];
    }
  }

  Widget _slider({
    required Key key,
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(valueLabel,
                style: const TextStyle(
                    color: _cyan, fontWeight: FontWeight.w700, fontSize: 13)),
          ],
        ),
        Slider(
          key: key,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _chips({
    required String label,
    required List<(int?, String)> options,
    required int? selected,
    required ValueChanged<int?> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final (value, text) in options)
              ChoiceChip(
                key: Key('convert_${label}_$text'),
                label: Text(text),
                selected: selected == value,
                onSelected: (_) => onSelected(value),
                selectedColor: _cyan.withValues(alpha: 0.22),
                checkmarkColor: _on,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildEstimate(ConvertSource source) {
    final format = _format!;
    final RangeEstimate? range = switch (format.kind) {
      MediaKind.audio => _audioEstimate(source, format),
      MediaKind.image || MediaKind.animated => _imageEstimate(source, format),
      MediaKind.video => null,
    };

    if (range == null) {
      return Container(
        key: const Key('convert_estimate'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _cyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: _cyan),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '视频体积取决于画面内容与时长，编码前无法可靠预估；转换后可见实际大小。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: const Key('convert_estimate'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _cyan.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _cyan.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.insights, size: 16, color: _cyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              range.exact
                  ? '预计 ≈ ${_bytes(range.sizes.lowBytes)}'
                  : '预计 ≈ ${_bytes(range.sizes.lowBytes)} – '
                      '${_bytes(range.sizes.highBytes)}'
                      '${range.note == null ? '' : '（${range.note}）'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  RangeEstimate? _audioEstimate(ConvertSource source, FormatSpec format) {
    if (source.duration <= Duration.zero) return null;
    final canCopy = source.kind == MediaKind.audio &&
        canStreamCopyAudio(format.id, source.audioCodec);
    final bitrate = canCopy ? _quality : _quality;
    final sizes = estimateAudioBytes(
      bitrateKbps: bitrate,
      duration: source.duration,
    );
    return sizes.isValid
        ? RangeEstimate(sizes, exact: false, note: canCopy ? '无损复制' : null)
        : null;
  }

  RangeEstimate? _imageEstimate(ConvertSource source, FormatSpec format) {
    if (source.width <= 0 || source.height <= 0) return null;
    // Scaling changes the pixel count, and the pixel model has to follow it.
    final width = _width ?? source.width;
    final height = _width == null
        ? source.height
        : (source.height * _width! / source.width).round();
    final sizes = estimateImageBytes(
      inputBytes: source.bytes,
      width: width,
      height: height,
      format: format,
      quality: _quality,
    );
    if (!sizes.isValid) return null;
    return RangeEstimate(
      sizes,
      exact: isExactImageEstimate(format),
      note: isExactImageEstimate(format) ? null : '取决于画面内容',
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
          child: ListTile(
            leading: const Icon(Icons.check_circle, color: _cyan),
            title: Text('${_format?.label ?? ''} 已生成',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(_bytes(_outputBytes ?? 0)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: RainbowGlow(
                  child: ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_alt),
                label: Text(
                  _outputPath != null &&
                          exportActionFor(_outputPath!) == ExportAction.file
                      ? '保存到文件'
                      : '存到相册',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cyan,
                  foregroundColor: _on,
                  disabledBackgroundColor: _cyan.withValues(alpha: 0.16),
                  disabledForegroundColor: _cyan.withValues(alpha: 0.55),
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
      ],
    );
  }
}

/// A rendered estimate: the numbers plus how much to trust them.
class RangeEstimate {
  const RangeEstimate(this.sizes, {required this.exact, this.note});
  final SizeRange sizes;
  final bool exact;
  final String? note;
}
