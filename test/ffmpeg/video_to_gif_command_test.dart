/// Pure-logic unit tests for the Video to GIF command builder and the GIF block
/// reader. No FFmpeg, no device, no binary fixtures.
///
/// Uses `package:test` rather than `flutter_test` on purpose: nothing here
/// touches Flutter, and `flutter test` needs the flutter_tester WebSocket,
/// which the sandbox blocks ("Invalid WebSocket upgrade request"). Run with
/// `dart run test test/ffmpeg/video_to_gif_command_test.dart`.
///
/// These lock in two bugs that were only ever caught by hand-inspecting a file
/// produced on the device, and would silently come back on any refactor:
///
///  1. `mpdecimate` placed before `fps` (plus a `setpts` renumbering) produced
///     a GIF that played at half the source duration. ffmpeg exits 0, so only
///     the parsed frame count and delay sum reveal it.
///
///  2. The result card reported frame count by scanning the whole file for
///     `0x21 0xF9` marker bytes. The LZW payload contains those byte pairs by
///     chance, so a real 60-frame / 5.00 s GIF was reported as 129 frames /
///     5298.3 s.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:tugi/ffmpeg/commands.dart';
import 'package:tugi/utils/gif_reader.dart';
import 'package:test/test.dart';

typedef LoopBuilder = List<String> Function(bool loop);

void main() {
  group('videoToGif filter chain', () {
    String filterOf({required bool dedup, int fps = 12, int? outputWidth}) {
      final args = videoToGif(
        inputPath: '/in.mp4',
        outputPath: '/out.gif',
        fps: fps,
        outputWidth: outputWidth,
        dedup: dedup,
      );
      return args[args.indexOf('-filter_complex') + 1];
    }

    test('dedup puts fps before mpdecimate', () {
      final f = filterOf(dedup: true);
      final fpsAt = f.indexOf('fps=');
      final decAt = f.indexOf('mpdecimate');
      expect(fpsAt, greaterThan(-1), reason: f);
      expect(decAt, greaterThan(-1), reason: f);
      expect(fpsAt, lessThan(decAt),
          reason: 'mpdecimate before fps dedups at the source rate, then fps '
              'resamples back up and nothing is actually dropped: $f');
    });

    test('dedup does not renumber PTS', () {
      // setpts=N/FRAME_RATE/TB compacts the gaps left by dropped frames, which
      // is what made a 5 s video come out as 2.5 s.
      expect(filterOf(dedup: true), isNot(contains('setpts')));
    });

    test('dedup asks the muxer for variable frame durations', () {
      final args =
          videoToGif(inputPath: '/in.mp4', outputPath: '/out.gif', dedup: true);
      expect(args, containsAllInOrder(['-fps_mode', 'vfr']));
      // -r and a non-CFR -fps_mode are mutually exclusive; ffmpeg rejects the
      // pair outright, so dedup mode must not emit -r.
      expect(args, isNot(contains('-r')));
    });

    test('non-dedup pins the output rate with -r', () {
      final args =
          videoToGif(inputPath: '/in.mp4', outputPath: '/out.gif', fps: 20);
      expect(args, containsAllInOrder(['-r', '20']));
      expect(args, isNot(contains('-fps_mode')));
    });

    test('pre-stages stay unlabelled so [s1]/[s2] bind to split', () {
      // Labelling the pre-stage makes ffmpeg bind the labels to `fps`, which
      // has one output: "More output link labels ... than it has outputs: 2 > 1".
      final f = filterOf(dedup: false);
      expect(f, isNot(contains('[0:v]')));
      expect(f, startsWith('fps=12,split[s1][s2]'));
    });

    test('output width becomes a lanczos scale with even height', () {
      expect(filterOf(dedup: false, outputWidth: 480),
          contains('scale=480:-2:flags=lanczos'));
      expect(filterOf(dedup: false, outputWidth: 1080),
          contains('scale=1080:-2:flags=lanczos'));
    });

    test('loop=false emits no dangling token before the output format', () {
      // Regression: `if (loop) '-loop', '0'` makes '-loop' a conditional
      // collection element while '0' is unconditional. With loop off that
      // leaves a bare '0' sitting after -gifflags, ffmpeg treats it as the
      // output filename, and the encode dies with "Unable to choose an output
      // format for '0'" while libx264 shows up in the log.
      final builders = <LoopBuilder>[
        (loop) => videoToGif(
            inputPath: '/in.mp4', outputPath: '/out.gif', loop: loop),
        (loop) => imagesToGif(
            concatListPath: '/l.txt', outputPath: '/out.gif', loop: loop),
        (loop) => compressGif(
            inputPath: '/in.gif',
            outputPath: '/out.gif',
            ratio: 0.5,
            loop: loop),
      ];
      for (final builder in builders) {
        for (final loop in [true, false]) {
          final args = builder(loop);
          // Always pass -loop explicitly: the GIF muxer's default is 0 (loop
          // forever), so omitting the flag silently ignores the setting.
          final loopAt = args.indexOf('-loop');
          expect(loopAt, greaterThan(-1), reason: 'loop=$loop: $args');
          expect(args[loopAt + 1], loop ? '0' : '1',
              reason: 'loop=$loop should map to ${loop ? '0' : '1'}: $args');
          // The output path must be the final argument and must be preceded by
          // '-f gif', never by a stray positional token.
          expect(args.last, '/out.gif', reason: 'loop=$loop: $args');
          final fmtAt = args.lastIndexOf('-f');
          expect(fmtAt, greaterThan(-1), reason: 'loop=$loop: $args');
          expect(args[fmtAt + 1], 'gif', reason: 'loop=$loop: $args');
          expect(args.sublist(fmtAt + 2), ['/out.gif'],
              reason: 'loop=$loop: $args');
        }
      }
    });

    test('every option value stays glued to its flag', () {
      // Any conditional element that leaves its value behind corrupts the
      // argument vector, so assert the shape for each builder instead of
      // trusting the list literals.
      final cases = <List<String>>[
        videoToGif(
            inputPath: '/in.mp4', outputPath: '/out.gif', fps: 15, dedup: true),
        videoToGif(
            inputPath: '/in.mp4', outputPath: '/out.gif', fps: 15, loop: false),
        imagesToGif(
            concatListPath: '/l.txt', outputPath: '/out.gif', loop: false),
        gifToVideo(
            inputPath: '/in.gif', outputPath: '/out.mp4', outputWidth: 480),
        gifToImages(
            inputPath: '/in.gif', outputPattern: '/f_%06d.png', framestep: 5),
        compressGif(inputPath: '/in.gif', outputPath: '/out.gif', ratio: 0.8),
        addWatermarkText(
            inputPath: '/in.gif',
            outputPath: '/out.gif',
            textFilePath: '/data/text.txt',
            fontFilePath: '/data/font.ttf'),
        addWatermarkImage(
            inputPath: '/in.gif',
            watermarkPath: '/w.png',
            outputPath: '/out.gif'),
        imagesToVideo(concatListPath: '/l.txt', outputPath: '/out.mp4'),
        editGifSpeed(
            inputPath: '/in.gif', outputPath: '/out.gif', speedMultiplier: 0.5),
        editImageTransform(
            inputPath: '/in.png',
            outputPath: '/out.jpg',
            adjust: const EditImageAdjust(saturation: 150)),
      ];
      const flagsWithValue = {
        '-i',
        '-f',
        '-filter_complex',
        '-vf',
        '-r',
        '-loop',
        '-c',
        '-safe',
        '-gifflags',
        '-fps_mode',
        '-crf',
        '-preset',
        '-movflags',
        '-pix_fmt',
        '-threads',
      };
      for (final args in cases) {
        for (var i = 0; i < args.length; i++) {
          if (flagsWithValue.contains(args[i])) {
            expect(i + 1, lessThan(args.length),
                reason: '"${args[i]}" has no value in $args');
            // A value that looks like another flag means the previous option
            // lost its value and this one is standing in for it. ffmpeg's own
            // convention puts dashes on some values (-gifflags -offsetting),
            // hence the exemption.
            const dashValued = {'-offsetting'};
            expect(
                dashValued.contains(args[i + 1]) ||
                    !args[i + 1].startsWith('-'),
                isTrue,
                reason:
                    '"${args[i]}" is followed by a flag, not a value, in $args');
          }
        }
      }
    });
  });

  group('GifReader', () {
    test('reads frame count, delays, duration, size and loop count', () {
      final g = GifReader.parse(buildGif(
        width: 640,
        height: 480,
        delaysMs: const [80, 90, 80, 90],
        loop: 0,
      ));
      expect(g.width, 640);
      expect(g.height, 480);
      expect(g.frames, 4);
      expect(g.delaysMs, [80, 90, 80, 90]);
      expect(g.durationMs, 340);
      expect(g.loops, 0);
    });

    test('delays sum to the reported duration', () {
      final g = GifReader.parse(buildGif(
        width: 480,
        height: 360,
        delaysMs: const [50, 100, 50, 100, 50],
        loop: 0,
      ));
      expect(g.delaysMs.length, g.frames);
      expect(g.delaysMs.fold<int>(0, (a, b) => a + b), g.durationMs);
      expect(g.durationMs, 350);
    });

    test('frames without a graphic control extension get delay 0', () {
      // A GCE is optional per frame; the frame still counts and plays instantly.
      final g = GifReader.parse(buildGif(
        width: 32,
        height: 32,
        delaysMs: const [40, null, 40],
        loop: 0,
      ));
      expect(g.frames, 3);
      expect(g.delaysMs, [40, 0, 40]);
    });

    test('a file with no loop block reports loops = -1', () {
      final g = GifReader.parse(buildGif(
        width: 32,
        height: 32,
        delaysMs: const [40, 40],
        loop: null,
      ));
      expect(g.loops, -1);
    });

    test('marker bytes inside the LZW payload are not counted as frames', () {
      // The exact failure mode of the old byte scanner: a 3-frame GIF whose
      // image data happens to contain 0x21 0xF9 / 0x21 0xFF pairs.
      final g = GifReader.parse(buildGif(
        width: 64,
        height: 64,
        delaysMs: const [80, 90, 80],
        loop: 0,
        poisonLzw: true,
      ));
      expect(g.frames, 3);
      expect(g.durationMs, 250);

      var naive = 0;
      final bytes = buildGif(
        width: 64,
        height: 64,
        delaysMs: const [80, 90, 80],
        loop: 0,
        poisonLzw: true,
      );
      for (var i = 0; i + 1 < bytes.length; i++) {
        if (bytes[i] == 0x21 && bytes[i + 1] == 0xF9) naive++;
        if (bytes[i] == 0x21 && bytes[i + 1] == 0xFF) naive++;
      }
      expect(naive, greaterThan(3),
          reason:
              'fixture no longer poisons the payload, so the guard is moot');
    });

    test('rejects a non-GIF payload instead of guessing', () {
      expect(() => GifReader.parse(Uint8List.fromList(List.filled(64, 0x41))),
          throwsA(isA<GifParseException>()));
    });

    test('rejects a truncated file instead of returning partial data', () {
      final full = buildGif(
        width: 32,
        height: 32,
        delaysMs: const [40, 40, 40],
        loop: 0,
      );
      expect(() => GifReader.parse(full.sublist(0, full.length - 8)),
          throwsA(isA<GifParseException>()));
    });
  });

  // ---------------------------------------------------------------------
  // Images to Video (roadmap 4.4)
  //
  // The timing rule here is the OPPOSITE of the GIF path and the difference is
  // the muxer, not the concat demuxer. Measured on host ffmpeg 9.0.2, 5 images:
  //   D=2.0 F=12 -> 10.000000 s / 120 frames
  //   D=0.3 F=12 ->  1.500000 s /  18 frames
  // `duration` alone sets the length; the mp4 muxer honours PTS. The gif muxer
  // does not (see images_to_gif_service.dart), so the two rules must never be
  // copied across.
  // ---------------------------------------------------------------------
  group('imagesToVideo', () {
    List<String> build({int fps = 12}) => imagesToVideo(
          concatListPath: '/l.txt',
          outputPath: '/out.mp4',
          fps: fps,
        );

    String vfOf(List<String> args) => args[args.indexOf('-vf') + 1];

    test('resamples the concatenated input to the requested rate', () {
      // This is the no-canvas path: the concat list holds the raw images and
      // the fps filter synthesises the in-between frames. It is only safe when
      // the sources already share dimensions, which is why the service prefers
      // the segment path whenever it can size a canvas.
      expect(vfOf(build()), 'fps=12');
      expect(vfOf(build(fps: 24)), 'fps=24');
    });

    test('encodes h264/yuv420p and fast-starts for sharing', () {
      final args = build();
      expect(args[args.indexOf('-c:v') + 1], 'libx264');
      expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p');
      expect(args[args.indexOf('-movflags') + 1], '+faststart');
      expect(args.last, '/out.mp4');
    });

    test('reads the concat list unsafely-prefixed, as the format requires', () {
      final args = build();
      expect(args[args.indexOf('-f') + 1], 'concat');
      expect(args[args.indexOf('-safe') + 1], '0');
      expect(args[args.indexOf('-i') + 1], '/l.txt');
    });

    test('carries no canvas or length flags of its own', () {
      // Canvas handling and length pinning belong to the segment path now.
      // A `-t` here would bound the pre-filter input and change the result in
      // a build-dependent way, which is exactly the bug that was removed.
      final args = build();
      expect(args.contains('-t'), isFalse);
      expect(vfOf(args), isNot(contains('scale=')));
      expect(vfOf(args), isNot(contains('pad=')));
    });
  });

  group('imagesToVideoSegments', () {
    List<String> build() => imagesToVideoSegments(
          concatListPath: '/l.txt',
          outputPath: '/out.mp4',
        );

    test('joins pre-encoded segments with a stream copy', () {
      // The canvas path renders each image to its own -t/-r segment, so the
      // join must not re-encode or resample anything: `-c copy` only.
      final args = build();
      final c = args.indexOf('-c');
      expect(args[c + 1], 'copy');
      // No filter graph at all -- reintroducing one would resample the
      // already-correct segments and risk the device truncation again.
      expect(args.contains('-vf'), isFalse);
      expect(args.contains('-t'), isFalse);
      expect(args.contains('-r'), isFalse);
    });

    test('reads the concat list and fast-starts the result', () {
      final args = build();
      expect(args[args.indexOf('-f') + 1], 'concat');
      expect(args[args.indexOf('-safe') + 1], '0');
      expect(args[args.indexOf('-i') + 1], '/l.txt');
      expect(args[args.indexOf('-movflags') + 1], '+faststart');
      expect(args.last, '/out.mp4');
    });
  });

  group('imagesToVideoCanvas', () {
    test('rounds odd values DOWN to even', () {
      // yuv420p halves both dimensions; an odd side either fails libx264 or is
      // silently floored. Rounding down keeps the promise "never larger than
      // requested" and stays predictable.
      expect(imagesToVideoCanvas(1921), 1920);
      expect(imagesToVideoCanvas(1920), 1920);
      expect(imagesToVideoCanvas(1079), 1078);
      expect(imagesToVideoCanvas(1), 2, reason: 'floors at 2, never 0');
      expect(imagesToVideoCanvas(2), 2);
      expect(imagesToVideoCanvas(3), 2);
    });

    test('null passes through so a caller can degrade to passthrough', () {
      expect(imagesToVideoCanvas(null), isNull);
    });

    test('zero and negatives cannot produce a degenerate canvas', () {
      // scale=0:0 is rejected by ffmpeg; the floor keeps the graph valid.
      expect(imagesToVideoCanvas(0), 2);
      expect(imagesToVideoCanvas(-100), 2);
    });
  });
}

/// Builds a structurally valid GIF. `poisonLzw` fills the image data with bytes
/// that look like extension introducers, which is exactly what the LZW stream
/// of a real encode does by chance.
Uint8List buildGif({
  required int width,
  required int height,
  required List<int?> delaysMs,
  required int? loop,
  bool poisonLzw = false,
}) {
  final out = BytesBuilder();
  void u8(int v) => out.addByte(v & 0xFF);
  void u16(int v) {
    u8(v);
    u8(v >> 8);
  }

  void ascii(String s) => out.add(s.codeUnits);

  ascii('GIF89a');
  u16(width);
  u16(height);
  u8(0x00); // no global colour table
  u8(0); // background colour index
  u8(0); // pixel aspect ratio

  if (loop != null) {
    u8(0x21);
    u8(0xFF);
    u8(11);
    ascii('NETSCAPE2.0');
    u8(3);
    u8(1);
    u16(loop);
    u8(0);
  }

  for (final delay in delaysMs) {
    if (delay != null) {
      u8(0x21);
      u8(0xF9);
      u8(4);
      u8(0); // disposal method + transparency flag
      u16((delay / 10).round()); // stored in 1/100 s
      u8(0); // transparent colour index
      u8(0); // block terminator
    }
    u8(0x2C); // image descriptor
    u16(0); // left
    u16(0); // top
    u16(width);
    u16(height);
    u8(0); // no local colour table
    u8(2); // LZW minimum code size
    // One sub-block holding fake LZW data. Contents are never decoded by the
    // reader -- it skips sub-blocks by length -- so any bytes are legal.
    final payload = poisonLzw
        ? [0x21, 0xF9, 0x21, 0xFF, 0x21, 0xF9, 0x21, 0xFF]
        : [0x02, 0x44, 0x01, 0x00];
    u8(payload.length);
    out.add(payload);
    u8(0); // block terminator
  }

  u8(0x3B); // trailer
  return out.toBytes();
}
