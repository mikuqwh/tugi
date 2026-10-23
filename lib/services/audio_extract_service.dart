// SPDX-License-Identifier: GPL-3.0-or-later

/// Audio extraction: probe the source, choose copy vs re-encode, run it.
///
/// The probe is what makes the screen honest: it knows the audio codec (to
/// decide whether a stream copy is possible), the bitrate (for the size
/// estimate) and whether the file has an audio track at all (a screen that
/// only says "转换失败" after a 30 s ffmpeg run is a bad screen).
// SPDX-License-Identifier: GPL-3.0-or-later

library audio_extract_service;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';

import 'ffmpeg_progress.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:format_core/format_core.dart';

import '../ffmpeg/audio_commands.dart' as audio;

class AudioExtractException implements Exception {
  AudioExtractException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the source file has, as far as audio goes.
class SourceAudioInfo {
  const SourceAudioInfo({
    required this.duration,
    required this.codec,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.channels,
    required this.audioTrackCount,
  });

  final Duration duration;

  /// The first audio stream's codec (`aac`, `mp3`, `opus`, ...), or ''.
  final String codec;
  final int bitrateKbps;
  final int sampleRate;
  final int channels;
  final int audioTrackCount;

  bool get hasAudio => audioTrackCount > 0;

  /// Whether a stream copy into [format] is possible (no re-encode).
  bool canCopyTo(FormatSpec format) =>
      hasAudio && canStreamCopyAudio(format.id, codec);

  String get codecLabel {
    if (codec.isEmpty) return '未知';
    final rate = sampleRate > 0
        ? ' · ${(sampleRate / 1000).toStringAsFixed(1)} kHz'
        : '';
    // An unknown channel count is omitted rather than printed as "0 声道".
    final ch = switch (channels) {
      0 => '',
      1 => ' · 单声道',
      2 => ' · 立体声',
      _ => ' · $channels 声道',
    };
    return '$codec$rate$ch';
  }
}

class AudioExtractService {
  AudioExtractService({required this.workDir});

  final String workDir;

  /// Read the source's audio facts. Returns null when ffprobe cannot read the
  /// file at all (not a media file, unsupported container).
  Future<SourceAudioInfo?> probe(String path) async {
    if (!File(path).existsSync()) return null;
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;

      final streams = info.getStreams();
      final audioStreams =
          streams.where((s) => s.getType() == 'audio').toList();
      final first = audioStreams.isEmpty ? null : audioStreams.first;

      final seconds = double.tryParse(info.getDuration() ?? '') ?? 0;
      return SourceAudioInfo(
        duration: Duration(milliseconds: (seconds * 1000).round()),
        codec: first?.getCodec() ?? '',
        bitrateKbps: _parseKbps(first?.getBitrate()),
        sampleRate: int.tryParse(first?.getSampleRate() ?? '') ?? 0,
        channels: _parseChannels(first?.getChannelLayout()),
        audioTrackCount: audioStreams.length,
      );
    } catch (_) {
      return null;
    }
  }

  /// ffprobe reports a channel LAYOUT NAME (`stereo`, `mono`, `5.1`), not a
  /// count. Reading it as an int is what produced "0 声道" on the first build
  /// of this screen.
  static int _parseChannels(String? layout) {
    if (layout == null) return 0;
    final l = layout.toLowerCase().trim();
    if (l == 'mono') return 1;
    if (l == 'stereo' || l == 'downmix') return 2;
    if (l.startsWith('5.1')) return 6;
    if (l.startsWith('7.1')) return 8;
    final m = RegExp(r'^(\d+)').firstMatch(l);
    return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
  }

  static int _parseKbps(String? raw) {
    final bits = int.tryParse(raw ?? '') ?? 0;
    return bits <= 0 ? 0 : (bits / 1000).round();
  }

  /// Extract the first audio track of [inputPath] as [format].
  ///
  /// [quality] is the UI's value for [format]'s quality policy and is ignored
  /// on the copy path (there is nothing to encode).
  Future<String> extract({
    required String inputPath,
    required FormatSpec format,
    required int quality,
    required bool copy,
    void Function(double progress)? onProgress,
    void Function(FfmpegJob job)? onJob,
    int? totalMs,
  }) async {
    if (!File(inputPath).existsSync()) {
      throw AudioExtractException('找不到视频: $inputPath');
    }
    await Directory(workDir).create(recursive: true);
    final output = '$workDir/audio_${DateTime.now().millisecondsSinceEpoch}'
        '.${format.extension}';

    final args = audio.extractAudio(
      inputPath: inputPath,
      outputPath: output,
      audioArgs: copy ? const ['-c:a', 'copy'] : format.encoderArgs,
      qualityArgs: copy ? const [] : qualityArgs(format.quality, quality),
      // Raw AAC has no filename convention ffmpeg trusts; everything else is
      // inferred from the extension.
      muxer: format.id == 'aac' ? 'adts' : null,
    );

    try {
      final job = await runWithProgress(
        args,
        totalMs: totalMs,
        onProgress: onProgress,
      );
      onJob?.call(job);
      await job.wait();
    } on FfmpegCancelled {
      rethrow;
    } on FfmpegException catch (e) {
      throw AudioExtractException('提取失败: ${_summarize(e.output)}');
    }
    final file = File(output);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw AudioExtractException('提取结束但没有产出文件');
    }
    return output;
  }

  static String _summarize(String log) {
    final lines = log
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where((l) =>
            l.toLowerCase().contains('error') ||
            l.toLowerCase().contains('invalid') ||
            l.toLowerCase().contains('failed'))
        .toList();
    return lines.isEmpty
        ? (log.trim().split('\n').lastOrNull ?? '(no output)')
        : lines.take(3).join(' | ');
  }
}

extension _LastOrNull<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
