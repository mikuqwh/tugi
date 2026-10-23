/// Full-screen preview for one work: swipe between works, zoom the picture,
/// share it, or reopen it in the feature that produced it.
// SPDX-License-Identifier: GPL-3.0-or-later

library work_preview_screen;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/zoomable_image.dart';
import '../services/open_service.dart';

class WorkPreviewScreen extends StatefulWidget {
  const WorkPreviewScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    this.service,
    this.openFile,
  });

  final List<WorkItem> items;
  final int initialIndex;
  final WorksService? service;

  /// Test seam: the host has no platform channel to open a file with.
  final Future<bool> Function(String path)? openFile;

  @override
  State<WorkPreviewScreen> createState() => _WorkPreviewScreenState();
}

class _WorkPreviewScreenState extends State<WorkPreviewScreen> {
  WorksService get _service => widget.service ?? WorksService.instance;

  late final PageController _pager =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  WorkItem get _item => widget.items[_index];

  @override
  Widget build(BuildContext context) {
    final item = _item;

    return Scaffold(
      backgroundColor: const Color(0xFF10131A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          featureLabelOf(item.featureId),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            key: const Key('work_share'),
            tooltip: '分享',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _share(item),
          ),
          IconButton(
            key: const Key('work_open'),
            tooltip: '打开',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _open(item),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pager,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final w = widget.items[i];
                // Audio works have no thumbnail: ffmpeg could not pull a
                // frame, which is the cheap "is this visual" test.
                return _Media(item: w, audio: w.thumbnailPath == null);
              },
            ),
          ),
          _InfoBar(item: item),
        ],
      ),
    );
  }

  Future<void> _share(WorkItem item) async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(item.path)]));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('分享失败：$e')));
    }
  }

  /// Hand the file to the system: gallery, video player or music player.
  ///
  /// This replaced "redo in the feature that made it": a work is an OUTPUT, so
  /// feeding it back in is usually invalid (a GIF cannot be an input for
  /// "Images to GIF", a JPEG cannot be a video source).
  Future<void> _open(WorkItem item) async {
    final opener = widget.openFile ?? const OpenService().open;
    final ok = await opener(item.path);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有能打开这个文件的应用，试试分享')),
      );
    }
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.item, required this.audio});

  final WorkItem item;
  final bool audio;

  @override
  Widget build(BuildContext context) {
    final file = File(item.path);
    if (audio || !file.existsSync()) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.audiotrack, size: 64, color: Colors.white54),
            const SizedBox(height: 12),
            Text(
              item.originalName,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 6),
            const Text(
              '音频不能内嵌播放，用右边的分享导出到其他应用',
              style: TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
          ],
        ),
      );
    }
    // GIFs animate through Image.file; stills are zoomable.
    final ext = item.formatExtension;
    final isGif = ext == 'gif' || ext == 'apng' || ext == 'webp';
    final image = Image.file(file, fit: BoxFit.contain, gaplessPlayback: true);
    if (isGif) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(child: image),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ZoomableImage(key: const Key('work_zoom'), child: image),
    );
  }
}

class _InfoBar extends StatelessWidget {
  const _InfoBar({required this.item});

  final WorkItem item;

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final at = item.createdAt;
    final stamp = '${at.year}/${at.month.toString().padLeft(2, '0')}/'
        '${at.day.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        color: const Color(0xFF1A1F29),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.originalName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${item.formatExtension.toUpperCase()} · '
              '${_bytes(item.bytes)} · $stamp',
              style: const TextStyle(color: Colors.white54, fontSize: 11.5),
            ),
            if (item.sourcePath != null) ...[
              const SizedBox(height: 2),
              Text(
                '原图：${item.sourcePath!.split(Platform.pathSeparator).last}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
            if (!item.copied) ...[
              const SizedBox(height: 2),
              const Text(
                '文件较大，未复制到作品区',
                style: TextStyle(color: Color(0xFFFFB74D), fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.swipe,
                    size: 14, color: Colors.white.withValues(alpha: 0.4)),
                const SizedBox(width: 6),
                Text(
                  '左右滑动切换作品',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
