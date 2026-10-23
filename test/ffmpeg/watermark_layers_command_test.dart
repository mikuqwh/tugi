/// The multi-layer watermark command shape.
///
/// These pin the FILTERGRAPH, because a graph that is wrong by one label or
/// one comma fails at runtime with an ffmpeg error the UI can only echo back.
/// `tool/wmprobe/verify3.sh` runs the same graphs through real ffmpeg; this
/// file is what keeps that script's copies honest.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/ffmpeg/commands.dart';

WatermarkLayerSpec text(String file, {String color = 'white'}) =>
    WatermarkLayerSpec(
      kind: WatermarkLayerKind.text,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      textFilePath: file,
      fontFilePath: 'font.ttf',
      fontSize: 24,
      fontColor: color,
    );

WatermarkLayerSpec image(String path, {int? width = 60}) => WatermarkLayerSpec(
      kind: WatermarkLayerKind.image,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.topLeft),
      mediaPath: path,
      width: width,
    );

WatermarkLayerSpec gif(String path, {int frames = 8, double opacity = 1.0}) =>
    WatermarkLayerSpec(
      kind: WatermarkLayerKind.gif,
      placement: const WatermarkPlacement.anchor(WatermarkPosition.bottomRight),
      mediaPath: path,
      width: 40,
      frames: frames,
      opacity: opacity,
    );

String graphOf(List<String> args) => args[args.indexOf('-filter_complex') + 1];

void main() {
  test('text + image + gif on a GIF source, one pass', () {
    final args = addWatermarks(
      inputPath: 'src.gif',
      outputPath: 'out.gif',
      kind: WatermarkMediaKind.gif,
      layers: [
        text('t.txt'),
        image('wm.png'),
        gif('wmgif.gif', opacity: 0.8),
      ],
    );

    // Inputs: the source first, then each media layer in list order.
    expect(args.sublist(0, 7),
        ['-y', '-i', 'src.gif', '-i', 'wm.png', '-i', 'wmgif.gif']);

    final graph = graphOf(args);
    // The text is drawn on the base, then handed to the first overlay.
    expect(graph, startsWith('[0:v]drawtext=fontfile='));
    expect(graph, contains('textfile=t.txt'));
    expect(graph, contains('expansion=none'));
    expect(graph, contains('fontcolor=white'));
    expect(graph, contains('overlay=0:0')); // top-left image layer
    // The still watermark keeps its own branch, scaled then alpha-normalised.
    expect(graph, contains('[1:v]scale=60:-1,format=rgba[wm1]'));
    // The animated one is scaled, made RGBA, dimmed and LOOPED.
    expect(
        graph,
        contains(
            '[2:v]scale=40:-1,format=rgba,colorchannelmixer=aa=0.800,loop=loop=-1:size=8[wm2]'));
    // A moving source cuts the output at its own end.
    expect(graph,
        contains('overlay=main_w-overlay_w-10:main_h-overlay_h-10:shortest=1'));
    // The palette split is last: quantising before the watermark would
    // destroy it.
    expect(
        graph,
        endsWith(',split[s1][s2];[s1]palettegen=stats_mode=single[p];'
            '[s2][p]paletteuse=new=1'));
    // GIF muxer flags still apply.
    expect(args, contains('-f'));
    expect(args.last, 'out.gif');
  });

  test('two text layers fuse into one drawtext chain', () {
    final args = addWatermarks(
      inputPath: 'src.gif',
      outputPath: 'out.gif',
      kind: WatermarkMediaKind.gif,
      layers: [text('a.txt'), text('b.txt', color: 'yellow')],
    );
    final graph = graphOf(args);
    expect(RegExp('drawtext=').allMatches(graph).length, 2);
    // No overlay in a text-only job, so no labels between them: a comma is
    // all that separates the two filters.
    expect(graph, contains('expansion=none:fontsize=24:fontcolor=white:'));
    expect(graph, contains(',drawtext=fontfile=font.ttf:textfile=b.txt'));
    expect(graph, isNot(contains('[wm')));
  });

  test('a still source does not loop its animated watermark', () {
    // One frame of base means `shortest=1` would cut the output to a single
    // frame, and a looping watermark would never end. Both are dropped, and
    // `overlay`'s default eof_action=repeat holds the watermark's last frame.
    final args = addWatermarks(
      inputPath: 'still.png',
      outputPath: 'out.gif',
      kind: WatermarkMediaKind.gif,
      layers: [gif('wmgif.gif', frames: 12)],
      stillSource: true,
    );
    final graph = graphOf(args);
    expect(graph, isNot(contains('loop=loop=')));
    expect(graph, isNot(contains('shortest=1')));
    expect(graph, contains('[1:v]scale=40:-1,format=rgba[wm1]'));
  });

  test('a video source with two media layers keeps h264 and faststart', () {
    final args = addWatermarks(
      inputPath: 'src.mp4',
      outputPath: 'out.mp4',
      kind: WatermarkMediaKind.video,
      layers: [image('a.png'), gif('b.gif')],
    );
    final graph = graphOf(args);
    expect(graph, contains('[o1][wm2]overlay='));
    expect(args, contains('-movflags'));
    expect(args.last, 'out.mp4');
  });

  test('a media layer before a text layer keeps the text on top', () {
    // Order is paint order: the text must be applied to the OVERLAY's output,
    // not to the raw base, or the image would cover it.
    final args = addWatermarks(
      inputPath: 'src.gif',
      outputPath: 'out.gif',
      kind: WatermarkMediaKind.gif,
      layers: [image('a.png'), text('t.txt')],
    );
    final graph = graphOf(args);
    final overlayAt = graph.indexOf('[o1]');
    final textAt = graph.lastIndexOf('drawtext=');
    expect(overlayAt, greaterThan(0));
    expect(textAt, greaterThan(overlayAt));
    expect(graph, contains('[o1]drawtext='));
  });

  test('an empty layer list is a programming error, not a silent no-op', () {
    expect(
      () => addWatermarks(
        inputPath: 'src.gif',
        outputPath: 'out.gif',
        kind: WatermarkMediaKind.gif,
        layers: const [],
      ),
      throwsArgumentError,
    );
  });
}
