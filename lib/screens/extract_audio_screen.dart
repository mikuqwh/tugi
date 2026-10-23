/// Extract the audio track out of a video (Tugi S1).
///
/// The first user-visible slice of the converter, chosen because it is the
/// cheapest path that still exercises the whole chain: probe -> choose
/// copy/re-encode -> run ffmpeg -> save/share.
///
/// Two things this screen refuses to hide:
///  * whether the extraction will be a **stream copy** (zero loss, instant) or
///    a re-encode, because that is the difference between 50 ms and 30 s;
///  * whether the file has an audio track at all, checked BEFORE running
///    ffmpeg instead of after.
// SPDX-License-Identifier: GPL-3.0-or-later

library extract_audio_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:format_core/format_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../convert/capability_probe.dart';
import '../services/audio_extract_service.dart';
import '../services/ffmpeg_progress.dart';
import '../services/export_service.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/export_progress.dart';
import '../ui/rainbow_glow.dart';
import '../utils/size_estimate.dart';

class ExtractAudioScreen extends StatefulWidget {
  const ExtractAudioScreen({
    super.key,
    this.initialVideoPath,
    this.probeOverride,
    this.availableOverride,
  });

  /// Pre-load a file instead of waiting for the picker (tests).
  final String? initialVideoPath;

  /// Injected probe: FFprobeKit only exists on a device, so widget tests pass
  /// their own answer instead of pretending to run ffprobe.
  final Future<SourceAudioInfo?> Function(String path)? probeOverride;

  /// Injected capability names (tests): which encoders/muxers "exist".
  final Set<String>? availableOverride;

  @override
  State<ExtractAudioScreen> createState() => _ExtractAudioScreenState();
}

class _ExtractAudioScreenState extends State<ExtractAudioScreen> {
  static const _cyan = Color(0xFF00A6C2);
  static const _on = FeatureColors.extractAudioOn;

  final _picker = ImagePicker();

  XFile? _video;
  int _inputBytes = 0;
  SourceAudioInfo? _info;
  String? _error;

  FormatSpec _format = formatById('m4a')!;
  int _quality = 192;

  bool _busy = false;

  /// 0..1 while ffmpeg runs; null means "no estimate yet".
  double? _progress;

  /// The running job, so cancel has something to stop.
  FfmpegJob? _job;
  String? _outputPath;
  int? _outputBytes;

  Set<String>? _available;

  AudioExtractService get _service =>
      AudioExtractService(workDir: Directory.systemTemp.path);

  bool get _canCopy => _info?.canCopyTo(_format) ?? false;

  @override
  void initState() {
    super.initState();
    final preset = widget.initialVideoPath;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(preset));
    }
    if (widget.availableOverride != null) {
      _available = widget.availableOverride;
    } else {
      // A probe failure must not break the screen: without names the format
      // grid simply treats nothing as unavailable (the old behaviour) rather
      // than throwing an unhandled async error.
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
  Future<void> loadVideoForTest(String path) => _load(path);

  Future<SourceAudioInfo?> _probe(String path) {
    final override = widget.probeOverride;
    return override != null ? override(path) : _service.probe(path);
  }

  Future<void> _pick() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked != null) await _load(picked.path);
    } catch (e) {
      setState(() => _error = '选择视频失败: $e');
    }
  }

  Future<void> _load(String path) async {
    final info = await _probe(path);
    if (!mounted) return;
    setState(() {
      _video = XFile(path);
      _inputBytes = File(path).lengthSync();
      _info = info;
      _outputPath = null;
      _outputBytes = null;
      _error = info == null
          ? '无法读取这个文件（可能不是视频）'
          : (info.hasAudio ? null : '这个视频没有音轨');
      // Pick a format the source can copy into when possible: that is the
      // best result with the least waiting.
      if (info != null && info.hasAudio) {
        final copyable = formatsFor(MediaKind.audio).where(info.canCopyTo);
        if (copyable.isNotEmpty) _format = copyable.first;
        _quality = defaultQualityFor(_format.quality);
      }
    });
  }

  Future<void> _extract() async {
    final video = _video;
    if (video == null || _info == null || !_info!.hasAudio) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _job = null;
      _error = null;
    });
    try {
      final ms = _info?.duration.inMilliseconds ?? 0;
      final path = await _service.extract(
        inputPath: video.path,
        format: _format,
        quality: _quality,
        copy: _canCopy,
        totalMs: ms > 0 ? ms : null,
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
          _busy = false;
          _progress = null;
          _job = null;
        });
      }
    }
  }

  /// Stop the running extraction.
  void _cancelExtract() => _job?.cancel();

  /// Where the file goes is decided by what it IS: the gallery cannot hold
  /// audio, so an MP3 gets the system save dialog instead (mainActivity's
  /// `tugi/export` channel). A gallery refusal on an image/video falls back to
  /// the same dialog rather than failing.
  Future<void> _save() async {
    final path = _outputPath;
    if (path == null) return;
    // "clip_audio.m4a" beats "audio_1792597974237.m4a" in the save dialog.
    final sourceName =
        _video?.path.split(Platform.pathSeparator).last ?? 'audio';
    final base = sourceName.contains('.')
        ? sourceName.substring(0, sourceName.lastIndexOf('.'))
        : sourceName;
    final outcome = await ExportService().save(
      path,
      album: 'Tugi',
      suggestedName: '${base}_audio.${path.split('.').last}',
    );
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
        featureId: 'extract_audio',
        sourcePath: _video?.path,
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _durationLabel(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? '$m 分 $s 秒' : '$s 秒';
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.cyan),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.extractAudio,
          ),
          title: const Text('Extract audio'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        // Same single-column layout as Images to Video: picker (or the
        // source card) first, options right under it.
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _video == null
                ? RainbowGlow(
                    child: ElevatedButton.icon(
                    key: const Key('audio_pick'),
                    onPressed: _pick,
                    icon: const Icon(Icons.audiotrack),
                    label: const Text('选择视频'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _cyan,
                      foregroundColor: _on,
                      disabledBackgroundColor: _cyan.withValues(alpha: 0.16),
                      disabledForegroundColor: _cyan.withValues(alpha: 0.55),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ))
                : _buildSourceCard(),
            const SizedBox(height: 12),
            if (_video == null) _buildEmptyHint(),
            // Options are visible BEFORE a file is picked, exactly like
            // Images to Video: the screen should show what it can do instead
            // of hiding behind the picker.
            _buildFormatSection(),
            const SizedBox(height: 16),
            _buildQualitySection(),
            if (_info != null) _buildEstimateLine(),
            if (_video != null && _info != null && !_info!.hasAudio)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  '这个视频没有音轨，换一个文件再试。',
                  style: TextStyle(color: Colors.red, fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 20),
            RainbowGlow(
              child: RainbowGlow(
                  child: ElevatedButton.icon(
                key: const Key('audio_extract'),
                onPressed: (_busy || _video == null || _info?.hasAudio != true)
                    ? null
                    : _extract,
                icon: const Icon(Icons.play_arrow),
                // The label states the OPERATION, not just the feature:
                // a copy is lossless and instant, a re-encode is not,
                // and the target format is worth repeating.
                label: Text(
                  _busy
                      ? (_canCopy ? '提取中…' : '转换中…')
                      : _canCopy
                          ? '无损提取为 ${_format.label}'
                          : '提取并转为 ${_format.label}',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cyan,
                  foregroundColor: _on,
                  disabledBackgroundColor: _cyan.withValues(alpha: 0.16),
                  disabledForegroundColor: _cyan.withValues(alpha: 0.55),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              )),
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              ExportProgress(
                progress: _progress,
                label: '正在提取…',
                accent: _cyan,
                onColor: _on,
                onCancel: _cancelExtract,
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
    );
  }

  Widget _buildEmptyHint() {
    return const Padding(
      padding: EdgeInsets.only(top: 12),
      child: Text(
        '从视频里取出音轨，可存成 M4A / MP3 / FLAC / WAV 等格式。\n'
        '如果源音轨编码与目标容器一致，会直接复制（无损、瞬时完成）。',
        style: TextStyle(color: Neutrals.inkSoft, height: 1.5),
      ),
    );
  }

  Widget _buildSourceCard() {
    final info = _info;
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
              child: const Icon(Icons.movie_outlined, color: _cyan),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _video!.path.split(Platform.pathSeparator).last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      _formatBytes(_inputBytes),
                      if (info != null) _durationLabel(info.duration),
                      if (info != null && info.hasAudio) info.codecLabel,
                    ].join(' · '),
                    style:
                        const TextStyle(color: Neutrals.inkSoft, fontSize: 12),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: _pick, child: const Text('更换')),
          ],
        ),
      ),
    );
  }

  /// The audio formats the registry knows, greyed out when this build cannot
  /// write them (capability probe) rather than hidden.
  Widget _buildFormatSection() {
    final rows = availabilityFor(
      _available ?? const {},
      MediaKind.audio,
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
                key: Key('audio_format_${spec.id}'),
                label: Text(spec.label),
                selected: _format.id == spec.id,
                onSelected: available ? (_) => _selectFormat(spec) : null,
                selectedColor: _cyan.withValues(alpha: 0.22),
                checkmarkColor: _on,
                tooltip: available ? spec.note : '这个 ffmpeg 构建不支持',
              ),
          ],
        ),
        if (_format.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _format.note,
            style: const TextStyle(color: Neutrals.inkSoft, fontSize: 12),
          ),
        ],
      ],
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

  Widget _buildQualitySection() {
    if (_canCopy) {
      return Container(
        key: const Key('audio_copy_badge'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFDDF6FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _cyan.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.bolt, size: 18, color: _cyan),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '无损提取（不重新编码）· 源音轨是 ${_info?.codec}，可直接放到 '
                '${_format.label} 里',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }
    if (_format.quality != QualityPolicy.audioBitrate) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('音质', style: TextStyle(fontWeight: FontWeight.w600)),
            Text('$_quality kbps',
                style: const TextStyle(
                    color: _cyan, fontWeight: FontWeight.w700, fontSize: 13)),
          ],
        ),
        Slider(
          key: const Key('audio_quality'),
          value: _quality.toDouble().clamp(32, 320),
          min: 32,
          max: 320,
          divisions: 36,
          onChanged: (v) => setState(() => _quality = (v / 8).round() * 8),
        ),
      ],
    );
  }

  Widget _buildEstimateLine() {
    final info = _info;
    if (info == null || !info.hasAudio) return const SizedBox.shrink();
    final bitrate = _canCopy
        ? (info.bitrateKbps > 0 ? info.bitrateKbps : _quality)
        : _quality;
    final estimate =
        estimateAudioBytes(bitrateKbps: bitrate, duration: info.duration);
    if (!estimate.isValid) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 10),
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
              '预计 ≈ ${_formatBytes(estimate.lowBytes)} – '
              '${_formatBytes(estimate.highBytes)}'
              '${_canCopy ? '（与源音轨一致）' : ''}',
              key: const Key('audio_estimate'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
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
            leading: const Icon(Icons.audiotrack, color: _cyan),
            title: Text('${_format.label} 已生成',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(_formatBytes(_outputBytes ?? 0)),
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
