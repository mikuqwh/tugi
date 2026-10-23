// SPDX-License-Identifier: GPL-3.0-or-later

/// The works shelf screen: every export, with its thumbnail, size and time.
///
/// Sorting and search live here rather than in the shared catalog because this
/// is a file browser, not a feature list: search matches file names, formats
/// and the feature that produced the work.
// SPDX-License-Identifier: GPL-3.0-or-later

library works_screen;

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/works_service.dart';
import 'work_preview_screen.dart';
import '../ui/page_transitions.dart';
import '../ui/app_palette.dart';
import '../ui/empty_state.dart';
import '../ui/theme_settings.dart';

class WorksScreen extends StatefulWidget {
  const WorksScreen({super.key, this.service});

  /// Test seam; defaults to the singleton.
  final WorksService? service;

  @override
  State<WorksScreen> createState() => _WorksScreenState();
}

class _WorksScreenState extends State<WorksScreen> {
  WorksService get _service => widget.service ?? WorksService.instance;

  final TextEditingController _search = TextEditingController();
  WorkSort _sort = WorkSort.newest;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_service, ThemeSettingsController.instance]),
      builder: (context, _) {
        final settings = ThemeSettingsController.instance.value;
        final items = _service.query(search: _search.text, sort: _sort);
        final all = _service.items;

        if (all.isEmpty) {
          return EmptyState(
            key: const Key('works_empty'),
            icon: Icons.collections_outlined,
            title: '还没有作品',
            hint: '在任何功能里保存一次，导出的文件和原图都会出现在这里。',
            accent: settings.accentColor,
            onColor: settings.onBackground,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StorageBar(
              service: _service,
              settings: settings,
              onCleanup: _runCleanup,
              onKeepChanged: (v) => _service.setKeepLimit(v),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: TextField(
                key: const Key('works_search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Neutrals.ink),
                decoration: InputDecoration(
                  hintText: '搜索作品：文件名、格式或功能',
                  isDense: true,
                  filled: true,
                  fillColor: Neutrals.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Neutrals.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Neutrals.line),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                itemCount: WorkSort.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final sort = WorkSort.values[i];
                  final selected = sort == _sort;
                  return GestureDetector(
                    key: Key('works_sort_${sort.name}'),
                    onTap: () => setState(() => _sort = sort),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? settings.accentColor.withValues(alpha: 0.16)
                            : Neutrals.surface,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color:
                              selected ? settings.accentColor : Neutrals.line,
                        ),
                      ),
                      child: Text(
                        sort.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected
                              ? settings.accentColor
                              : Neutrals.inkSoft,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的作品',
                        key: const Key('works_no_match'),
                        style: TextStyle(
                          color: settings.onBackground.withValues(alpha: 0.8),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _WorkCard(
                        item: items[i],
                        onOpen: () => _openPreview(items, i),
                        onDelete: _delete,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  void _openPreview(List<WorkItem> items, int index) {
    Navigator.push(
      context,
      tugiRoute(
        (_) => WorkPreviewScreen(
          items: items,
          initialIndex: index,
          service: widget.service,
        ),
      ),
    );
  }

  Future<void> _runCleanup() async {
    final before = _service.items.length;
    // With no limit configured, "clean up" trims to the default 50.
    final keep = _service.keepLimit > 0 ? _service.keepLimit : 50;
    final result = await _service.cleanup(keep: keep);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.removed == 0
            ? '已经是最近 $keep 个，无需清理'
            : '已清理 ${result.removed} 个（$before → ${_service.items.length}），'
                '释放 ${_mb(result.bytes)}'),
      ),
    );
  }

  Future<void> _delete(WorkItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个作品？'),
        content: Text(
          '${item.fileName}\n只会从作品区移除，不会影响相册里已经保存的副本。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await _service.remove(item);
  }
}

String _mb(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Usage line, a "keep last N" selector and the one-tap cleanup.
class _StorageBar extends StatelessWidget {
  const _StorageBar({
    required this.service,
    required this.settings,
    required this.onCleanup,
    required this.onKeepChanged,
  });

  final WorksService service;
  final ThemeSettings settings;
  final VoidCallback onCleanup;
  final ValueChanged<int> onKeepChanged;

  static const _options = <int, String>{
    0: '不限',
    20: '20 个',
    50: '50 个',
    100: '100 个',
    200: '200 个',
  };

  @override
  Widget build(BuildContext context) {
    final count = service.items.length;
    final bytes = service.totalBytes;
    final keep =
        _options.containsKey(service.keepLimit) ? service.keepLimit : 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: Neutrals.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Neutrals.line),
        ),
        child: Row(
          children: [
            Icon(Icons.sd_storage_outlined,
                size: 16, color: settings.accentColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$count 个作品 · ${_mb(bytes)}',
                key: const Key('works_usage'),
                style: const TextStyle(fontSize: 12, color: Neutrals.ink),
              ),
            ),
            // "Keep last N" — the cleanup button respects it.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Neutrals.line),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('works_keep'),
                  value: keep,
                  isDense: true,
                  style: const TextStyle(fontSize: 12, color: Neutrals.ink),
                  items: [
                    for (final entry in _options.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text('保留 ${entry.value}'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) onKeepChanged(v);
                  },
                ),
              ),
            ),
            IconButton(
              key: const Key('works_cleanup'),
              tooltip: '一键清理',
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              color: Neutrals.inkSoft,
              onPressed: count == 0 ? null : onCleanup,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkCard extends StatelessWidget {
  const _WorkCard({
    required this.item,
    required this.onOpen,
    required this.onDelete,
  });

  final WorkItem item;
  final VoidCallback onOpen;
  final Future<void> Function(WorkItem) onDelete;

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.year}/${t.month.toString().padLeft(2, '0')}/'
        '${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = ThemeSettingsController.instance.value;
    final thumb = item.thumbnailPath;

    return Material(
      color: Neutrals.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: Key('work_${item.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        onLongPress: () => onDelete(item),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: thumb != null && File(thumb).existsSync()
                      ? Image.file(File(thumb), fit: BoxFit.cover)
                      : ColoredBox(
                          color: settings.accentColor.withValues(alpha: 0.14),
                          child: Icon(
                            Icons.audiotrack,
                            color: settings.accentColor,
                            size: 26,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      featureLabelOf(item.featureId),
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Neutrals.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${item.formatExtension.toUpperCase()} · ${_bytes(item.bytes)} · ${_when(item.createdAt)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Neutrals.inkSoft,
                      ),
                    ),
                    if (!item.copied)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          '文件较大，仅记录原始位置',
                          style:
                              TextStyle(fontSize: 10.5, color: Colors.orange),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除记录',
                icon: const Icon(Icons.delete_outline, size: 19),
                color: Neutrals.inkSoft,
                onPressed: () => onDelete(item),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
