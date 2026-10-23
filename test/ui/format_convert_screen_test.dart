/// Format Convert screen (Tugi S3).
///
/// ffprobe/ffmpeg only run on a device, so the probe and the converter are
/// injected: these tests pin the DECISIONS (which formats are offered, which
/// warnings appear, what gets sent to the converter), not the codecs.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_core/format_core.dart';

import 'package:tugi/screens/format_convert_screen.dart';
import 'package:tugi/services/convert_service.dart';

ConvertSource _source({
  required MediaKind kind,
  int width = 800,
  int height = 600,
  int bytes = 400000,
  Duration duration = Duration.zero,
  bool hasAudio = false,
  bool hasAlpha = false,
  String audioCodec = '',
  int frames = 0,
}) =>
    ConvertSource(
      path: '/tmp/source.bin',
      kind: kind,
      bytes: bytes,
      width: width,
      height: height,
      duration: duration,
      hasAudio: hasAudio,
      audioCodec: audioCodec,
      videoCodec: '',
      hasAlpha: hasAlpha,
      frames: frames,
    );

Future<void> _pump(
  WidgetTester tester, {
  required ConvertSource source,
  Future<String> Function(ConvertRequest)? onConvert,
  Set<String> available = const {
    'libwebp',
    'libaom-av1',
    'libx264',
    'libx265',
    'libvpx-vp9',
    'libmp3lame',
    'libopus',
    'libvorbis',
    'apng',
    'mp4',
    'webm',
  },
}) async {
  // A real file, because the screen reads its size; never probed (injected).
  final dir = Directory.systemTemp.createTempSync('convert_screen_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });
  final file = File('${dir.path}/source.bin')
    ..writeAsBytesSync(List.filled(2048, 3));

  await tester.pumpWidget(MaterialApp(
    builder: _noAnimations,
    home: FormatConvertScreen(
      initialSourcePath: file.path,
      probeOverride: (_) async => source,
      convertOverride: onConvert,
      availableOverride: available,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// Reduced motion for the whole test: the primary CTA carries an animated
/// rainbow border, and a forever-repeating animation makes `pumpAndSettle`
/// hang. The animation itself is covered by test/ui/rainbow_glow_test.dart.
Widget _noAnimations(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

void main() {
  testWidgets('the empty state says the type is detected by content',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(builder: _noAnimations, home: FormatConvertScreen()));
    await tester.pump();
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.textContaining('由内容判断'), findsOneWidget);
  });

  testWidgets('an image offers image formats and warns about alpha loss',
      (tester) async {
    await _pump(
      tester,
      source: _source(kind: MediaKind.image, hasAlpha: true),
    );

    expect(find.byKey(const Key('convert_format_png')), findsOneWidget);
    expect(find.byKey(const Key('convert_format_mp4_h264')), findsNothing);
    // Default target is JPEG, which cannot carry alpha, so the warning shows.
    expect(find.textContaining('将垫上白色背景'), findsOneWidget);
    // Compressed-image estimates are a band, and the UI says why.
    expect(find.textContaining('取决于画面内容'), findsOneWidget);
  });

  testWidgets(
      'an animation converted to a still says only the first frame stays',
      (tester) async {
    await _pump(
      tester,
      source: _source(
          kind: MediaKind.animated,
          frames: 24,
          duration: const Duration(seconds: 2)),
    );
    await tester.tap(find.byKey(const Key('convert_format_png')));
    await tester.pumpAndSettle();

    expect(find.textContaining('只会保留第一帧'), findsOneWidget);
  });

  testWidgets('a video offers video and audio targets, no image ones',
      (tester) async {
    await _pump(
      tester,
      source: _source(
        kind: MediaKind.video,
        width: 1920,
        height: 1080,
        duration: const Duration(seconds: 10),
        hasAudio: true,
        audioCodec: 'aac',
      ),
    );

    expect(find.byKey(const Key('convert_format_mp4_h264')), findsOneWidget);
    expect(find.byKey(const Key('convert_format_mp3')), findsOneWidget);
    expect(find.byKey(const Key('convert_format_png')), findsNothing);

    // The panel is a lazy ListView: each control is scrolled to before it is
    // asserted, otherwise "not built" would read as "not offered".
    await _scrollTo(tester, find.byKey(const Key('convert_keep_audio')));
    expect(find.byKey(const Key('convert_keep_audio')), findsOneWidget);
    await _scrollTo(tester, find.byKey(const Key('convert_分辨率_720p')));
    expect(find.byKey(const Key('convert_分辨率_720p')), findsOneWidget);
    await _scrollTo(tester, find.byKey(const Key('convert_帧率_24')));
    expect(find.byKey(const Key('convert_帧率_24')), findsOneWidget);
    // Video gets no number, and says so instead.
    await _scrollTo(tester, find.byKey(const Key('convert_estimate')));
    expect(find.textContaining('编码前无法可靠预估'), findsOneWidget);
  });

  testWidgets('a silent video does not offer the audio switch', (tester) async {
    await _pump(
      tester,
      source: _source(
        kind: MediaKind.video,
        duration: const Duration(seconds: 5),
        hasAudio: false,
      ),
    );
    expect(find.byKey(const Key('convert_keep_audio')), findsNothing);
  });

  testWidgets('audio-only shows audio targets and an arithmetic estimate',
      (tester) async {
    await _pump(
      tester,
      source: _source(
        kind: MediaKind.audio,
        duration: const Duration(seconds: 60),
        hasAudio: true,
        audioCodec: 'aac',
      ),
    );

    expect(find.byKey(const Key('convert_format_mp3')), findsOneWidget);
    expect(find.byKey(const Key('convert_format_webm_vp9')), findsNothing);
    // 192 kbps x 60 s ~ 1.4 MB, shown as a range from the estimate helper.
    expect(find.textContaining('MB'), findsOneWidget);
  });

  testWidgets('missing encoders grey a format out instead of hiding it',
      (tester) async {
    await _pump(
      tester,
      source: _source(kind: MediaKind.image),
      available: const {'libwebp'},
    );
    final avif =
        tester.widget<ChoiceChip>(find.byKey(const Key('convert_format_avif')));
    expect(avif.onSelected, isNull);
    final webp =
        tester.widget<ChoiceChip>(find.byKey(const Key('convert_format_webp')));
    expect(webp.onSelected, isNotNull);
  });

  testWidgets('converting sends the chosen format and shows the result',
      (tester) async {
    ConvertRequest? seen;
    await _pump(
      tester,
      source: _source(kind: MediaKind.image),
      onConvert: (request) async {
        seen = request;
        final file = File(
            '${Directory.systemTemp.path}/out_${DateTime.now().microsecondsSinceEpoch}.webp')
          ..writeAsBytesSync(List.filled(1000, 1));
        return file.path;
      },
    );

    await tester.tap(find.byKey(const Key('convert_format_webp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('convert_run')));
    await tester.pumpAndSettle();

    expect(seen?.format.id, 'webp');
    expect(find.textContaining('已生成'), findsOneWidget);
    expect(find.text('存到相册'), findsOneWidget);
  });

  testWidgets('a failed conversion surfaces the message', (tester) async {
    await _pump(
      tester,
      source: _source(kind: MediaKind.image),
      onConvert: (_) async => throw ConvertException('转换失败: 编码器不存在'),
    );
    await tester.tap(find.byKey(const Key('convert_run')));
    await tester.pumpAndSettle();
    expect(find.textContaining('编码器不存在'), findsOneWidget);
  });
}
