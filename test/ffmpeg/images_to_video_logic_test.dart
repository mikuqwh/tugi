/// Pure-logic tests for the Images to Video timing rules (roadmap 4.4).
///
/// These import `commands.dart`, NOT the service: the service imports
/// `ffmpeg_kit_flutter_new`, which pulls in Flutter, and the plain Dart VM
/// cannot load that ("Invalid WebSocket upgrade request" / analyzer errors out
/// of flutter/src). Anything that must be testable therefore lives in the pure
/// builder file -- same split the Edit Image work used.
///
/// Background, measured on host ffmpeg 9.0.2 with the concat demuxer (5 images,
/// ffprobe for duration and frame count, sampled frames for survival):
///
///   D=2.0  F=12  (24 frames/img) -> 10.000000 s, 120 frames, all 5 present
///   D=0.3  F=12  (3.6 frames/img) ->  1.500000 s,  18 frames, all 5 present
///   D=0.3  F=2   (0.6 frames/img) ->  1.500000 s,   3 frames, only red/blue/
///                                    magenta survived
///   D=0.05 F=12  (0.6 frames/img) ->  0.250000 s,   3 frames, only green/blue/
///                                    magenta survived -- the FIRST image went
///
/// The sub-1 case is the dangerous one: the duration can still come out looking
/// right while whole images are missing, so it must be prevented up front
/// rather than detected afterwards.

// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:tugi/ffmpeg/commands.dart';
import 'package:test/test.dart';

void main() {
  group('imagesToVideoSettleFps', () {
    test('leaves a comfortable setting alone', () {
      // 1 s per image at 12 fps is 12 frames per image: nothing to fix.
      expect(
          imagesToVideoSettleFps(secondsPerImage: 1.0, requestedFps: 12), 12);
      expect(
          imagesToVideoSettleFps(secondsPerImage: 2.0, requestedFps: 12), 12);
      expect(
          imagesToVideoSettleFps(secondsPerImage: 0.5, requestedFps: 12), 12);
    });

    test('raises fps when an image would otherwise span under 2 frames', () {
      // 0.3 s at 12 fps = 3.6 frames, which is fine (>= 2).
      expect(
          imagesToVideoSettleFps(secondsPerImage: 0.3, requestedFps: 12), 12);
      // 0.3 s at 2 fps = 0.6 frames: the measured disappearing case.
      expect(imagesToVideoSettleFps(secondsPerImage: 0.3, requestedFps: 2), 7);
      // 0.05 s at 12 fps = 0.6 frames: also measured to drop images.
      expect(
          imagesToVideoSettleFps(secondsPerImage: 0.05, requestedFps: 12), 40);
    });

    test('the settled value always satisfies the survival rule', () {
      // Whatever comes in, the outgoing pair must keep every image on screen.
      for (final d in <double>[0.02, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0, 5.0]) {
        for (final f in <int>[1, 2, 5, 12, 24, 30, 60]) {
          final got =
              imagesToVideoSettleFps(secondsPerImage: d, requestedFps: f);
          expect(d * got, greaterThanOrEqualTo(2),
              reason: 'D=$d F=$f -> $got gives ${d * got} frames per image');
        }
      }
    });

    test('never lowers fps below what the caller asked for', () {
      for (final d in <double>[0.1, 1.0, 10.0]) {
        final got =
            imagesToVideoSettleFps(secondsPerImage: d, requestedFps: 30);
        expect(got, greaterThanOrEqualTo(30), reason: 'D=$d');
      }
    });

    test('a non-positive duration is passed through untouched', () {
      // Rejecting the input is the service's job; this must not divide by zero
      // or invent a value.
      expect(imagesToVideoSettleFps(secondsPerImage: 0, requestedFps: 12), 12);
      expect(imagesToVideoSettleFps(secondsPerImage: -1, requestedFps: 12), 12);
    });

    test('ceil, not round: 0.4 s needs 5 fps, not 4', () {
      // 2 / 0.4 = 5 exactly.
      expect(imagesToVideoSettleFps(secondsPerImage: 0.4, requestedFps: 1), 5);
      // 2 / 0.35 = 5.71 -> must round UP to 6, or one image gets 1.75 frames.
      expect(imagesToVideoSettleFps(secondsPerImage: 0.35, requestedFps: 1), 6);
    });
  });

  group('imagesToVideoTimingIsSafe', () {
    test('matches the measured survive/drop boundary', () {
      // The measured cases, stated as the predicate the service asserts on.
      expect(imagesToVideoTimingIsSafe(secondsPerImage: 2.0, fps: 12), isTrue);
      expect(imagesToVideoTimingIsSafe(secondsPerImage: 0.3, fps: 12), isTrue);
      // 0.3 x 2 = 0.6 and 0.05 x 12 = 0.6: both dropped images.
      expect(imagesToVideoTimingIsSafe(secondsPerImage: 0.3, fps: 2), isFalse);
      expect(
          imagesToVideoTimingIsSafe(secondsPerImage: 0.05, fps: 12), isFalse);
    });

    test('the threshold is the clamp target, not a hardcoded 1', () {
      // The clamp raises the rate until each image spans
      // imagesToVideoMinFramesPerImage frames. An earlier version of this
      // predicate compared against a literal 1, so the two disagreed about
      // what "safe" meant. Anything the clamp produces must pass, and the
      // boundary must sit at the shared constant.
      for (final d in <double>[0.05, 0.2, 0.5, 1.0, 2.0, 3.0]) {
        for (final f in <int>[1, 12, 24, 30, 60]) {
          final settled = imagesToVideoSettleFps(
            secondsPerImage: d,
            requestedFps: f,
          );
          expect(
            imagesToVideoTimingIsSafe(secondsPerImage: d, fps: settled),
            isTrue,
            reason: 'clamp output must always be safe (D=$d F=$f -> $settled)',
          );
        }
      }
      // One frame per image is not enough; the target is two.
      expect(imagesToVideoTimingIsSafe(secondsPerImage: 1.0, fps: 1), isFalse);
      expect(imagesToVideoTimingIsSafe(secondsPerImage: 1.0, fps: 2), isTrue);
    });
  });

  // ---------------------------------------------------------------------
  // The mixed-dimension trap.
  //
  // The concat demuxer hands its files to the decoder as ONE continuous
  // stream, so a resolution change ends the input. A `-vf scale/pad` chain
  // runs AFTER the demuxer and therefore cannot repair it -- the first image
  // is all that survives, and the `fps` filter then resamples that fragment
  // into a short video that still looks like a plausible result.
  //
  // Measured on host ffmpeg 9.0.2, 3 images at 0.5 s each, `fps=12`:
  //   same size   (1600x900 x3)                  -> 1.500000 s / 18 frames
  //   mixed sizes (1600x900, 900x1600, 1200x1200) -> 0.500000 s /  6 frames
  //
  // The service avoids this by rendering every image onto the canvas with its
  // own ffmpeg pass BEFORE writing the concat list. These tests pin the shape
  // of that contract, because nothing in the encode itself would fail loudly:
  // ffmpeg exits 0, only the duration is wrong.
  // ---------------------------------------------------------------------
  group('canvas normalization contract', () {
    test('the REAL letterbox filter letterboxes without cropping', () {
      // Calls the function the encoder actually uses, not a copy of its
      // string. An earlier version of this test pasted the filter chain
      // inline, so changing the service to `increase` (crop) kept it green --
      // it was documenting the contract, not testing it.
      final vf = imagesToVideoLetterboxFilter(1080, 608);
      expect(vf, contains('force_original_aspect_ratio=decrease'));
      expect(vf, isNot(contains('increase')));
      expect(vf, isNot(contains('crop')));
      expect(vf, contains('pad=1080:608:(ow-iw)/2:(oh-ih)/2'));
      expect(vf, contains('setsar=1'));
    });

    test('the filter follows the canvas it is given', () {
      // Guards against a hardcoded size: the chain must describe THIS canvas.
      expect(imagesToVideoLetterboxFilter(1920, 1080),
          startsWith('scale=1920:1080:'));
      expect(
          imagesToVideoLetterboxFilter(1920, 1080), contains('pad=1920:1080:'));
      expect(imagesToVideoLetterboxFilter(640, 480), contains('pad=640:480:'));
    });

    test('the REAL segment command renders at the right rate and length', () {
      // Same reasoning: pin the command the service builds.
      final args = imagesToVideoSegment(
        inputPath: '/in.png',
        outputPath: '/seg.mp4',
        canvas: (1080, 608),
        seconds: 1.0,
        fps: 12,
      );
      expect(args[args.indexOf('-loop') + 1], '1');
      expect(args[args.indexOf('-t') + 1], '1.000');
      expect(args[args.indexOf('-r') + 1], '12');
      expect(args[args.indexOf('-vf') + 1],
          imagesToVideoLetterboxFilter(1080, 608));
      expect(args[args.indexOf('-c:v') + 1], 'libx264');
      expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p');
    });

    test('segment seconds are emitted at millisecond precision', () {
      // Truncating to whole seconds would silently change the video's length.
      final args = imagesToVideoSegment(
        inputPath: '/in.png',
        outputPath: '/seg.mp4',
        canvas: (1080, 608),
        seconds: 0.2,
        fps: 12,
      );
      expect(args[args.indexOf('-t') + 1], '0.200');
    });

    test('even-rounding a 16:9 height lands off-ratio, hence setsar', () {
      // This is the arithmetic behind the off-ratio canvas: only some widths
      // divide evenly. 1080/608 = 1.77632 and 720/404 = 1.78218 against
      // 16/9 = 1.77778, so ffmpeg would otherwise tag a non-square SAR.
      //
      // Note this is a correctness matter in its own right -- the frame should
      // not be stretched to a display aspect its pixels do not imply. It is
      // NOT what caused the device truncation; `setsar=1` did not change that
      // frame count, per-image segments did.
      double ratioFor(int w) {
        final h = imagesToVideoCanvas((w * 9 / 16).round())!;
        return w / h;
      }

      const sixteenNine = 16 / 9;
      // Exact cases keep square pixels on their own.
      expect((ratioFor(1920) - sixteenNine).abs(), lessThan(1e-9));
      expect((ratioFor(480) - sixteenNine).abs(), lessThan(1e-9));
      // These do not, which is precisely why setsar=1 must be present.
      expect((ratioFor(1080) - sixteenNine).abs(), greaterThan(1e-4));
      expect((ratioFor(720) - sixteenNine).abs(), greaterThan(1e-4));
    });

    test('the canvas is even on both axes for any 16:9 target width', () {
      // Odd canvas values are what make libx264 reject the graph outright, so
      // every width the UI offers must land on even output.
      for (final target in <int>[1920, 1080, 720, 480]) {
        final w = imagesToVideoCanvas(target);
        // 16:9 derived height, then rounded the same way the service does.
        final h = imagesToVideoCanvas((target * 9 / 16).round());
        expect(w! % 2, 0, reason: 'width for target $target');
        expect(h! % 2, 0, reason: 'height for target $target');
      }
    });

    test('a portrait first image yields a portrait canvas', () {
      // The canvas follows the FIRST image, so picking a portrait photo first
      // produces a portrait video rather than a 16:9 one with huge bars.
      final info = (width: 900, height: 1600);
      final ratio = info.height / info.width;
      final w = imagesToVideoCanvas(1080)!;
      final h = imagesToVideoCanvas((1080 * ratio).round())!;
      expect(w, 1080);
      expect(h, 1920);
      expect(h, greaterThan(w), reason: 'portrait stays portrait');
    });
  });
}
