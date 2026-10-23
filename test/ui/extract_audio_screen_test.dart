/// Extract Audio screen (Tugi S1).
///
/// FFprobeKit only runs on a device, so the screen takes an injected probe and
/// an injected capability set: these tests pin the DECISIONS the screen makes
/// from that information, not ffprobe itself.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/extract_audio_screen.dart';
import 'package:tugi/services/audio_extract_service.dart';
import 'package:tugi/utils/size_estimate.dart';

SourceAudioInfo _aac({int bitrate = 128, double seconds = 12}) =>
    SourceAudioInfo(
      duration: Duration(milliseconds: (seconds * 1000).round()),
      codec: 'aac',
      bitrateKbps: bitrate,
      sampleRate: 44100,
      channels: 2,
      audioTrackCount: 1,
    );

Future<void> _pump(
  WidgetTester tester, {
  required SourceAudioInfo? info,
  Set<String> available = const {
    'libmp3lame',
    'libopus',
    'libvorbis',
    'adts',
  },
}) async {
  // A real file so the size/label code has something to read; its CONTENT is
  // never probed because the probe is injected.
  final dir = Directory.systemTemp.createTempSync('audio_screen_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });
  final file = File('${dir.path}/clip.mp4')
    ..writeAsBytesSync(List.filled(4096, 7));

  await tester.pumpWidget(MaterialApp(
    builder: _noAnimations,
    home: ExtractAudioScreen(
      initialVideoPath: file.path,
      probeOverride: (_) async => info,
      availableOverride: available,
    ),
  ));
  await tester.pumpAndSettle();
}

String _estimateText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('audio_estimate'))).data!;

/// Reduced motion for the whole test: the primary CTA carries an animated
/// rainbow border, and a forever-repeating animation makes `pumpAndSettle`
/// hang. The animation itself is covered by test/ui/rainbow_glow_test.dart.
Widget _noAnimations(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

void main() {
  testWidgets('the empty state explains the two paths', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(builder: _noAnimations, home: ExtractAudioScreen()));
    await tester.pump();
    expect(find.text('选择视频'), findsOneWidget);
    expect(find.textContaining('直接复制'), findsOneWidget);
  });

  testWidgets('a copyable source defaults to a lossless copy', (tester) async {
    await _pump(tester, info: _aac());

    // aac -> m4a is the first copyable format, so the screen starts there
    // and says so.
    expect(find.byKey(const Key('audio_copy_badge')), findsOneWidget);
    // Scope the assertion to the badge: the action button ALSO says
    // 「无损提取为 M4A」 (added later), so a bare textContaining matches twice.
    expect(
      find.descendant(
        of: find.byKey(const Key('audio_copy_badge')),
        matching: find.textContaining('无损提取'),
      ),
      findsOneWidget,
    );
    // No quality slider on a copy: there is nothing to encode.
    expect(find.byKey(const Key('audio_quality')), findsNothing);

    // The estimate uses the SOURCE bitrate (128k x 12 s = 192 KB).
    final expected = estimateAudioBytes(
      bitrateKbps: 128,
      duration: const Duration(seconds: 12),
    );
    expect(_estimateText(tester),
        contains('${(expected.lowBytes / 1024).toStringAsFixed(1)} KB'));
  });

  testWidgets('choosing a different container switches to a re-encode',
      (tester) async {
    await _pump(tester, info: _aac());

    await tester.tap(find.byKey(const Key('audio_format_mp3')));
    await tester.pumpAndSettle();

    // aac into mp3 cannot be copied: the badge goes away and the bitrate
    // slider appears.
    expect(find.byKey(const Key('audio_copy_badge')), findsNothing);
    expect(find.byKey(const Key('audio_quality')), findsOneWidget);

    // Dragging the slider changes the estimate.
    await tester.drag(
        find.byKey(const Key('audio_quality')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    final lowered = _estimateText(tester);
    await tester.drag(
        find.byKey(const Key('audio_quality')), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(_estimateText(tester), isNot(lowered));
  });

  testWidgets('a video without an audio track says so and cannot extract',
      (tester) async {
    await _pump(
      tester,
      info: const SourceAudioInfo(
        duration: Duration(seconds: 5),
        codec: '',
        bitrateKbps: 0,
        sampleRate: 0,
        channels: 0,
        audioTrackCount: 0,
      ),
    );

    expect(find.text('这个视频没有音轨'), findsOneWidget);
    // The button stays visible (options are always shown, Images-to-Video
    // style) but is not pressable.
    final button =
        tester.widget<ElevatedButton>(find.byKey(const Key('audio_extract')));
    expect(button.onPressed, isNull);
  });

  testWidgets('an unreadable file reports it instead of crashing',
      (tester) async {
    await _pump(tester, info: null);
    expect(find.textContaining('无法读取这个文件'), findsOneWidget);
    final button =
        tester.widget<ElevatedButton>(find.byKey(const Key('audio_extract')));
    expect(button.onPressed, isNull);
  });

  testWidgets('formats this build cannot write are greyed out, not hidden',
      (tester) async {
    // A build with no libopus: OPUS stays on screen but is not selectable.
    await _pump(tester, info: _aac(), available: const {'libmp3lame'});
    final opus =
        tester.widget<ChoiceChip>(find.byKey(const Key('audio_format_opus')));
    expect(opus.onSelected, isNull);
    final mp3 =
        tester.widget<ChoiceChip>(find.byKey(const Key('audio_format_mp3')));
    expect(mp3.onSelected, isNotNull);
  });
}
