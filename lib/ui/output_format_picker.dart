// SPDX-License-Identifier: GPL-3.0-or-later

/// "A few common formats, then the rest" picker.
///
/// Every feature that can write more than one container needs the same thing:
/// show the two or three formats people actually pick, hide the long tail of
/// TIFF/BMP/QOI behind one "更多格式" tap. Dumping fourteen chips into a tool
/// screen buries the real controls -- which is fine on the converter, where
/// choosing the format IS the feature, and not fine anywhere else.
///
/// Formats this ffmpeg build cannot write stay visible but disabled with a
/// tooltip (same rule as the converter).
// SPDX-License-Identifier: GPL-3.0-or-later

library output_format_picker;

import 'package:flutter/material.dart';
import 'package:format_core/format_core.dart';

import 'app_palette.dart';

class OutputFormatPicker extends StatefulWidget {
  const OutputFormatPicker({
    super.key,
    required this.formats,
    required this.selected,
    required this.onSelected,
    this.common = const [],
    this.available,
    this.title = '输出格式',
  });

  /// Every format this screen can produce, in display order.
  final List<FormatSpec> formats;

  /// The current choice; must appear in [formats].
  final FormatSpec selected;

  /// Ids shown before the "更多格式" toggle. Everything else goes behind it.
  final List<String> common;

  /// Called when an available format is tapped.
  final ValueChanged<FormatSpec> onSelected;

  /// Codec/muxer names from the capability probe. Null means "assume all".
  final Set<String>? available;

  final String title;

  @override
  State<OutputFormatPicker> createState() => _OutputFormatPickerState();
}

class _OutputFormatPickerState extends State<OutputFormatPicker> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final common = [
      for (final id in widget.common)
        for (final f in widget.formats)
          if (f.id == id) f,
    ];
    final inCommon = (FormatSpec f) => common.any((c) => c.id == f.id);
    final rest = widget.formats.where((f) => !inCommon(f)).toList();

    // The SELECTED format is always visible, even when it lives behind "更多":
    // a collapsed picker that hides the current choice looks like the choice
    // was lost, and the note under it would describe an invisible format.
    final showSelected = !inCommon(widget.selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in common) _chip(f),
            if (showSelected) _chip(widget.selected),
            if (_expanded)
              for (final f in rest)
                if (f.id != widget.selected.id) _chip(f),
            if (rest.isNotEmpty && !_expanded)
              ActionChip(
                key: const Key('format_picker_more'),
                avatar: const Icon(Icons.expand_more, size: 16),
                label: Text('更多格式 (${rest.length})'),
                onPressed: () => setState(() => _expanded = true),
              ),
            if (rest.isNotEmpty && _expanded)
              ActionChip(
                key: const Key('format_picker_less'),
                avatar: const Icon(Icons.expand_less, size: 16),
                label: const Text('收起'),
                onPressed: () => setState(() => _expanded = false),
              ),
          ],
        ),
        if (widget.selected.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            widget.selected.note,
            style: const TextStyle(color: Neutrals.inkSoft, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _chip(FormatSpec format) {
    final available = widget.available == null ||
        isFormatAvailable(format, widget.available!);
    return ChoiceChip(
      key: Key('format_chip_${format.id}'),
      label: Text(format.label),
      selected: widget.selected.id == format.id,
      onSelected: available ? (_) => widget.onSelected(format) : null,
      tooltip: available ? format.note : '这个 ffmpeg 构建不支持',
    );
  }
}
