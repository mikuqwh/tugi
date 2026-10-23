// SPDX-License-Identifier: GPL-3.0-or-later

/// Reversible image scrambling — the "混淆 / 还原" tool.
///
/// The idea (as in the 番茄/混淆图 family of tools): turn a photo into something
/// that looks like noise, share it, and restore it later with the same
/// password. Two properties matter:
///
///  * every pixel still exists exactly once (a PERMUTATION, not a lossy
///    filter), so the round trip is exact;
///  * the permutation is derived from the password, so another password
///    produces a different picture and cannot restore this one.
///
/// Three modes, all invertible at any size:
///  * [ScrambleMode.standard] — Fisher–Yates pixel shuffle + an RGB keystream.
///  * [ScrambleMode.strong] — the same shuffle twice with different seeds.
///  * [ScrambleMode.hilbert] — the shuffle follows a Hilbert curve, which keeps
///    neighbours nearby and gives a finer-grained noise texture.
///
/// Alpha is never touched: a transparent PNG stays transparent.
library image_scramble;

import 'dart:convert';
import 'dart:typed_data';

enum ScrambleMode {
  mosaic('马赛克', '按色块打乱：看不出原图，但颜色分布还在'),
  standard('标准', '逐像素打乱，肉眼就是噪点'),
  strong('强混淆', '两轮置换，结构更难看出'),
  hilbert('希尔伯特', '按曲线顺序打乱，噪声更细');

  const ScrambleMode(this.label, this.detail);
  final String label;
  final String detail;
}

/// Password -> 64-bit seed (FNV-1a). Stable across runs and platforms that
/// have 64-bit ints, which every Android device does.
int seedFromPassword(String password) {
  var hash = 0xcbf29ce484222325;
  for (final unit in utf8.encode(password)) {
    hash ^= unit;
    // Dart ints wrap at 64 bits on the VM, which is exactly what we want.
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash;
}

/// xorshift64*, enough for scrambling and identical on every platform.
class _Rng {
  _Rng(int seed) : _state = seed == 0 ? 0x9E3779B97F4A7C15 : seed;

  int _state;

  int next() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF;
    x ^= x >> 7;
    x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF;
    _state = x & 0xFFFFFFFFFFFFFFFF;
    return _state;
  }

  /// 0..[max]-1.
  int below(int max) => (next() & 0x7FFFFFFF) % max;
}

/// A Fisher–Yates permutation of `0..count-1`.
Uint32List permutation(int count, int seed) {
  final order = Uint32List(count);
  for (var i = 0; i < count; i++) {
    order[i] = i;
  }
  final rng = _Rng(seed);
  for (var i = count - 1; i > 0; i--) {
    final j = rng.below(i + 1);
    final tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
  return order;
}

/// Order of pixels along a Hilbert curve.
///
/// The curve is defined on a square of side 2^k; for a rectangle the extra
/// cells are simply never visited, which still visits every real pixel exactly
/// once.
Uint32List hilbertPermutation(int width, int height, int seed) {
  var side = 1;
  while (side < (width > height ? width : height)) {
    side <<= 1;
  }
  final keys = List<int>.filled(width * height, 0);
  final indices = List<int>.generate(width * height, (i) => i);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      keys[y * width + x] = _hilbertIndex(x, y, side);
    }
  }
  indices.sort((a, b) {
    final byKey = keys[a].compareTo(keys[b]);
    return byKey != 0 ? byKey : a.compareTo(b);
  });
  // A small rotation mixes the curve's start point so two different passwords
  // do not begin at the same pixel.
  final rng = _Rng(seed);
  final shift = rng.below(width * height);
  final out = Uint32List(width * height);
  for (var i = 0; i < out.length; i++) {
    out[i] = indices[(i + shift) % out.length];
  }
  return out;
}

/// Position of (x, y) along a Hilbert curve of the given side.
int _hilbertIndex(int x, int y, int side) {
  var rx = 0;
  var ry = 0;
  var d = 0;
  var t = side >> 1;
  while (t > 0) {
    rx = (x & t) > 0 ? 1 : 0;
    ry = (y & t) > 0 ? 1 : 0;
    d += t * t * ((3 * rx) ^ ry);
    // Rotate the quadrant.
    if (ry == 0) {
      if (rx == 1) {
        x = side - 1 - x;
        y = side - 1 - y;
      }
      final tmp = x;
      x = y;
      y = tmp;
    }
    t >>= 1;
  }
  return d;
}

/// Scramble (or, with [inverse], restore) an RGBA buffer.
///
/// [rgba] must be exactly `width * height * 4` bytes in RGBA order, which is
/// what `ui.ImageByteFormat.rawRgba` produces.
Uint8List scrambleBytes(
  Uint8List rgba, {
  required int width,
  required int height,
  required String password,
  ScrambleMode mode = ScrambleMode.standard,
  bool inverse = false,

  /// Block edge in pixels for [ScrambleMode.mosaic]. Larger blocks keep more
  /// of the picture readable, which is the whole point of that mode.
  int blockSize = 24,
}) {
  final count = width * height;
  if (rgba.length != count * 4) {
    throw ArgumentError('rgba length ${rgba.length} != ${count * 4}');
  }
  if (password.isEmpty) {
    throw ArgumentError('password must not be empty');
  }

  final base = seedFromPassword(password);

  if (mode == ScrambleMode.mosaic) {
    return _mosaic(
      rgba,
      width: width,
      height: height,
      seed: base,
      blockSize: blockSize,
      inverse: inverse,
    );
  }

  final order = switch (mode) {
    ScrambleMode.hilbert => hilbertPermutation(width, height, base),
    _ => permutation(count, base),
  };
  final second = mode == ScrambleMode.strong
      ? permutation(count, seedFromPassword('$password#2'))
      : null;

  final out = Uint8List(rgba.length);

  if (!inverse) {
    // out[i] = src[order[i]], then (strong) the same again, then the keystream.
    _applyPermutation(rgba, out, order, count);
    if (second != null) {
      final tmp = Uint8List(rgba.length);
      _applyPermutation(out, tmp, second, count);
      out.setAll(0, tmp);
    }
    _xor(out, base, count);
    return out;
  }

  // Inverse order: undo the keystream, then the permutations backwards.
  _xor(rgba, base, count);
  if (second != null) {
    final tmp = Uint8List(rgba.length);
    _applyInversePermutation(rgba, tmp, second, count);
    _applyInversePermutation(tmp, out, order, count);
    return out;
  }
  _applyInversePermutation(rgba, out, order, count);
  return out;
}

/// Block-level shuffle: whole tiles move, so the result reads as a mosaic of
/// the original colours instead of uniform noise.
Uint8List _mosaic(
  Uint8List rgba, {
  required int width,
  required int height,
  required int seed,
  required int blockSize,
  required bool inverse,
}) {
  // Only WHOLE blocks take part. A partial block at the right/bottom edge has
  // fewer pixels than the others, so moving it into the middle would either
  // clip its neighbour or drop content -- and the round trip must stay exact.
  // Leaving that last strip untouched costs a few pixels and is invisible.
  final smallest = width < height ? width : height;
  final limit = smallest ~/ 2;
  if (limit < 2) {
    // Smaller than 4 px on a side: mosaic cannot form two blocks. Fall back to
    // the pixel shuffle so the operation still does something reversible.
    final order = permutation(width * height, seed);
    final out = Uint8List(rgba.length);
    if (inverse) {
      _applyInversePermutation(rgba, out, order, width * height);
    } else {
      _applyPermutation(rgba, out, order, width * height);
    }
    return out;
  }
  final size = blockSize.clamp(2, limit > 256 ? 256 : limit);
  final cols = width ~/ size;
  final rows = height ~/ size;
  final blocks = cols * rows;
  final order = permutation(blocks, seed);
  final out = Uint8List.fromList(rgba);

  for (var b = 0; b < blocks; b++) {
    // Forward: destination block b takes source block order[b].
    // Inverse: destination block order[b] takes source block b.
    final dstBlock = inverse ? order[b] : b;
    final srcBlock = inverse ? b : order[b];
    final sx = (srcBlock % cols) * size;
    final sy = (srcBlock ~/ cols) * size;
    final dx = (dstBlock % cols) * size;
    final dy = (dstBlock ~/ cols) * size;
    for (var y = 0; y < size; y++) {
      final from = ((sy + y) * width + sx) * 4;
      final to = ((dy + y) * width + dx) * 4;
      out.setRange(to, to + size * 4, rgba, from);
    }
  }
  return out;
}

/// `dst[i] = src[order[i]]`.
void _applyPermutation(
    Uint8List src, Uint8List dst, Uint32List order, int count) {
  for (var i = 0; i < count; i++) {
    final from = order[i] * 4;
    final to = i * 4;
    dst[to] = src[from];
    dst[to + 1] = src[from + 1];
    dst[to + 2] = src[from + 2];
    dst[to + 3] = src[from + 3];
  }
}

/// `dst[order[i]] = src[i]`, the exact inverse of [_applyPermutation].
void _applyInversePermutation(
    Uint8List src, Uint8List dst, Uint32List order, int count) {
  for (var i = 0; i < count; i++) {
    final to = order[i] * 4;
    final from = i * 4;
    dst[to] = src[from];
    dst[to + 1] = src[from + 1];
    dst[to + 2] = src[from + 2];
    dst[to + 3] = src[from + 3];
  }
}

/// XORs R/G/B of every pixel with a keystream. Alpha is left alone so
/// transparency survives the round trip.
void _xor(Uint8List bytes, int seed, int count) {
  final rng = _Rng(seed ^ 0x2545F4914F6CDD1D);
  for (var i = 0; i < count; i++) {
    final key = rng.next();
    final at = i * 4;
    bytes[at] = bytes[at] ^ (key & 0xFF);
    bytes[at + 1] = bytes[at + 1] ^ ((key >> 8) & 0xFF);
    bytes[at + 2] = bytes[at + 2] ^ ((key >> 16) & 0xFF);
  }
}
