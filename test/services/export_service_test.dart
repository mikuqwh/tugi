/// Where an output goes, and what happens when the gallery says no.
///
/// The routing is tested with fakes rather than the real Gal/channel calls:
/// what matters is that an MP3 never reaches `Gal.putImage` (the reported bug)
/// and that a gallery refusal degrades to the save dialog instead of an error.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/services/export_service.dart';

/// A real file with the given extension: [ExportService.save] refuses to route
/// a path that does not exist, which is itself a behaviour under test.
String _file(String name) {
  final dir = Directory.systemTemp.createTempSync('export_service_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });
  final file = File('${dir.path}/$name')..writeAsBytesSync([1, 2, 3, 4]);
  return file.path;
}

void main() {
  group('classification', () {
    test('audio formats route to the file dialog', () {
      for (final ext in ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav']) {
        expect(exportKindFor('x.$ext'), ExportKind.audio, reason: ext);
        expect(exportActionFor('x.$ext'), ExportAction.file, reason: ext);
      }
    });

    test('image formats go to the gallery', () {
      for (final ext in ['png', 'jpg', 'jpeg', 'webp', 'gif', 'apng', 'bmp']) {
        expect(exportKindFor('x.$ext'), ExportKind.image, reason: ext);
        expect(exportActionFor('x.$ext'), ExportAction.gallery, reason: ext);
      }
    });

    test('video formats use Gal.putVideo, not putImage', () {
      for (final ext in ['mp4', 'mov', 'mkv', 'webm', 'avi']) {
        expect(exportKindFor('x.$ext'), ExportKind.video, reason: ext);
        expect(exportActionFor('x.$ext'), ExportAction.gallery, reason: ext);
      }
    });

    test('case and directories do not confuse it', () {
      expect(exportKindFor('/tmp/A/B.MP3'), ExportKind.audio);
      expect(exportKindFor(r'C:\x\y\z.MP4'), ExportKind.video);
    });

    test('an unknown extension takes the safe destination', () {
      // Better a save dialog than a gallery call that throws.
      expect(exportKindFor('x.xyz'), ExportKind.audio);
      expect(exportKindFor('no-extension'), ExportKind.audio);
    });
  });

  group('routing', () {
    test('an audio file never touches the gallery', () async {
      var galleryCalls = 0;
      var dialogCalls = 0;
      final service = ExportService(
        saveImage: (_, __) async => galleryCalls++,
        saveVideo: (_, __) async => galleryCalls++,
        saveAs: (_, __) async {
          dialogCalls++;
          return true;
        },
      );

      final outcome = await service.save(_file('clip.mp3'));
      expect(outcome.status, ExportStatus.savedToFile);
      expect(dialogCalls, 1);
      expect(galleryCalls, 0);
    });

    test('an image goes to the gallery', () async {
      var images = 0;
      final service = ExportService(
        saveImage: (_, __) async => images++,
        saveAs: (_, __) async => true,
      );
      final outcome = await service.save(_file('a.png'));
      expect(outcome.status, ExportStatus.savedToGallery);
      expect(images, 1);
    });

    test('a video goes through putVideo', () async {
      var videos = 0;
      var images = 0;
      final service = ExportService(
        saveImage: (_, __) async => images++,
        saveVideo: (_, __) async => videos++,
        saveAs: (_, __) async => true,
      );
      final outcome = await service.save(_file('a.mp4'));
      expect(outcome.status, ExportStatus.savedToGallery);
      expect(videos, 1);
      expect(images, 0);
    });

    test('a gallery refusal falls back to the save dialog', () async {
      var dialogCalls = 0;
      final service = ExportService(
        saveImage: (_, __) async => throw Exception('unsupported'),
        saveAs: (_, __) async {
          dialogCalls++;
          return true;
        },
      );
      final outcome = await service.save(_file('a.png'));
      expect(outcome.status, ExportStatus.savedToFile);
      expect(outcome.message, contains('相册不接受'));
      expect(dialogCalls, 1);
    });

    test('both destinations failing is reported, not thrown', () async {
      final service = ExportService(
        saveImage: (_, __) async => throw Exception('nope'),
        saveAs: (_, __) async => throw Exception('also nope'),
      );
      final outcome = await service.save(_file('a.png'));
      expect(outcome.status, ExportStatus.failed);
      expect(outcome.message, isNotNull);
    });

    test('backing out of the dialog is a cancel, not an error', () async {
      final service = ExportService(saveAs: (_, __) async => false);
      final outcome = await service.save(_file('a.mp3'));
      expect(outcome.status, ExportStatus.cancelled);
      expect(outcome.isSuccess, isFalse);
    });

    test('a missing file fails before any destination is touched', () async {
      var touched = 0;
      final service = ExportService(
        saveImage: (_, __) async => touched++,
        saveAs: (_, __) async {
          touched++;
          return true;
        },
      );
      final outcome = await service.save(
          '${Directory.systemTemp.path}/definitely-not-here-${DateTime.now().microsecondsSinceEpoch}.mp3');
      expect(outcome.status, ExportStatus.failed);
      expect(touched, 0);
    });
  });
}
