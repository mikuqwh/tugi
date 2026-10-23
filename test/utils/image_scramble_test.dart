// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/utils/image_scramble.dart';

/// The round trip must be EXACT: this tool's whole promise is "scramble it,
/// share it, restore it perfectly with the password".
void main() {
  Uint8List randomBytes(int pixels, int seed) {
    final rng = Random(seed);
    final bytes = Uint8List(pixels * 4);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  group('round trip', () {
    for (final mode in ScrambleMode.values) {
      test('${mode.name}: 17x5 restores exactly', () {
        final src = randomBytes(17 * 5, 1);
        final scrambled = scrambleBytes(
          src,
          width: 17,
          height: 5,
          password: 'hunter2',
          mode: mode,
          blockSize: 4,
        );
        expect(scrambled, isNot(equals(src)));
        final restored = scrambleBytes(
          scrambled,
          width: 17,
          height: 5,
          password: 'hunter2',
          mode: mode,
          blockSize: 4,
          inverse: true,
        );
        expect(restored, equals(src));
      });
    }

    test('40x40 restores exactly', () {
      final src = randomBytes(1600, 7);
      for (final mode in ScrambleMode.values) {
        final scrambled = scrambleBytes(src,
            width: 40, height: 40, password: 'p@ss', mode: mode, blockSize: 8);
        final restored = scrambleBytes(scrambled,
            width: 40,
            height: 40,
            password: 'p@ss',
            mode: mode,
            blockSize: 8,
            inverse: true);
        expect(restored, equals(src), reason: mode.name);
      }
    });

    test('mosaic restores exactly at several block sizes', () {
      final src = randomBytes(37 * 23, 21);
      for (final block in [8, 16, 24, 64]) {
        final scrambled = scrambleBytes(src,
            width: 37,
            height: 23,
            password: 'blocks',
            mode: ScrambleMode.mosaic,
            blockSize: block);
        expect(scrambled, isNot(equals(src)), reason: 'block $block');
        final restored = scrambleBytes(scrambled,
            width: 37,
            height: 23,
            password: 'blocks',
            mode: ScrambleMode.mosaic,
            blockSize: block,
            inverse: true);
        expect(restored, equals(src), reason: 'block $block');
      }
    });

    test('mosaic keeps whole blocks intact (colours survive)', () {
      // A 32x32 image split into 8px blocks: every 8x8 block must reappear
      // somewhere unchanged, which is what makes it read as a mosaic rather
      // than noise.
      final src = randomBytes(32 * 32, 22);
      final out = scrambleBytes(src,
          width: 32,
          height: 32,
          password: 'm',
          mode: ScrambleMode.mosaic,
          blockSize: 8);
      Set<String> blockKeys(Uint8List bytes) {
        final keys = <String>{};
        for (var by = 0; by < 4; by++) {
          for (var bx = 0; bx < 4; bx++) {
            final buf = StringBuffer();
            for (var y = 0; y < 8; y++) {
              final at = ((by * 8 + y) * 32 + bx * 8) * 4;
              buf.write(bytes.sublist(at, at + 8 * 4).join(','));
            }
            keys.add(buf.toString());
          }
        }
        return keys;
      }

      expect(blockKeys(out), equals(blockKeys(src)));
    });

    test('a 1-pixel image survives', () {
      final src = Uint8List.fromList([12, 34, 56, 255]);
      for (final mode in ScrambleMode.values) {
        final scrambled =
            scrambleBytes(src, width: 1, height: 1, password: 'x', mode: mode);
        final restored = scrambleBytes(scrambled,
            width: 1, height: 1, password: 'x', mode: mode, inverse: true);
        expect(restored, equals(src), reason: mode.name);
      }
    });
  });

  group('password', () {
    test('a different password cannot restore the image', () {
      final src = randomBytes(12 * 8, 3);
      final scrambled = scrambleBytes(src,
          width: 12, height: 8, password: 'right', mode: ScrambleMode.standard);
      final wrong = scrambleBytes(scrambled,
          width: 12,
          height: 8,
          password: 'wrong',
          mode: ScrambleMode.standard,
          inverse: true);
      expect(wrong, isNot(equals(src)));
    });

    test('the same password always produces the same output', () {
      final src = randomBytes(9 * 9, 4);
      final a = scrambleBytes(src,
          width: 9, height: 9, password: 'same', mode: ScrambleMode.standard);
      final b = scrambleBytes(src,
          width: 9, height: 9, password: 'same', mode: ScrambleMode.standard);
      expect(a, equals(b));
    });

    test('different passwords produce different scrambles', () {
      final src = randomBytes(9 * 9, 5);
      final a = scrambleBytes(src,
          width: 9, height: 9, password: 'a', mode: ScrambleMode.standard);
      final b = scrambleBytes(src,
          width: 9, height: 9, password: 'b', mode: ScrambleMode.standard);
      expect(a, isNot(equals(b)));
    });

    test('an empty password is refused', () {
      expect(
        () => scrambleBytes(Uint8List(4), width: 1, height: 1, password: ''),
        throwsArgumentError,
      );
    });
  });

  group('alpha', () {
    test('transparency is preserved through the round trip', () {
      final src = randomBytes(6 * 4, 9);
      // Force a couple of transparent and translucent pixels.
      for (var i = 3; i < src.length; i += 4) {
        src[i] = (i ~/ 4).isEven ? 0 : 128;
      }
      final scrambled = scrambleBytes(src,
          width: 6, height: 4, password: 'alpha', mode: ScrambleMode.strong);
      final restored = scrambleBytes(scrambled,
          width: 6,
          height: 4,
          password: 'alpha',
          mode: ScrambleMode.strong,
          inverse: true);
      for (var i = 3; i < restored.length; i += 4) {
        expect(restored[i], src[i]);
      }
    });
  });

  group('permutation', () {
    test('is a bijection', () {
      final order = permutation(100, 12345);
      expect(order.toSet().length, 100);
    });

    test('the Hilbert order visits every pixel exactly once', () {
      for (final size in [(5, 3), (8, 8), (13, 7), (1, 9)]) {
        final order = hilbertPermutation(size.$1, size.$2, 99);
        expect(order.length, size.$1 * size.$2);
        expect(order.toSet().length, size.$1 * size.$2);
      }
    });
  });

  test('the scrambled image is not a copy of the source', () {
    final src = randomBytes(32 * 32, 11);
    final out = scrambleBytes(src,
        width: 32, height: 32, password: 'noise', mode: ScrambleMode.standard);
    var same = 0;
    for (var i = 0; i < src.length; i++) {
      if (src[i] == out[i]) same++;
    }
    // A permutation of random bytes keeps many positions equal by chance;
    // what matters is that the pixels moved, so compare whole pixels.
    var moved = 0;
    for (var i = 0; i < 32 * 32; i++) {
      final a = src.sublist(i * 4, i * 4 + 4);
      final b = out.sublist(i * 4, i * 4 + 4);
      if (a[0] != b[0] || a[1] != b[1] || a[2] != b[2]) moved++;
    }
    expect(moved, greaterThan(900));
    expect(same, lessThan(src.length));
  });
}
