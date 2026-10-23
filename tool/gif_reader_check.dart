// SPDX-License-Identifier: GPL-3.0-or-later

// Cross-checks lib/utils/gif_reader.dart against every GIF fixture we have.
//
// Usage: dart run tool/gif_reader_check.dart <file.gif> [...]
import 'dart:io';

import 'package:tugi/utils/gif_reader.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/gif_reader_check.dart <file.gif> [...]');
    exit(2);
  }
  var bad = 0;
  for (final path in args) {
    final f = File(path);
    if (!f.existsSync()) {
      print('${_name(path)}: MISSING');
      bad++;
      continue;
    }
    try {
      final g = GifReader.parse(f.readAsBytesSync());
      final distinct = g.delaysMs.toSet().toList()..sort();
      print('${_name(path)}: '
          '${g.width}x${g.height} '
          'frames=${g.frames} '
          'durMs=${g.durationMs} '
          'sec=${g.seconds.toStringAsFixed(2)} '
          'loop=${g.loops} '
          'delays=$distinct '
          'bytes=${f.lengthSync()}');
    } catch (e) {
      print('${_name(path)}: FAIL $e');
      bad++;
    }
  }
  exit(bad == 0 ? 0 : 1);
}

String _name(String p) {
  final i = p.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? p : p.substring(i + 1);
}
