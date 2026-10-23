// SPDX-License-Identifier: GPL-3.0-or-later

/// A colour picker dialog built on [ColorWheel], with saved presets.
// SPDX-License-Identifier: GPL-3.0-or-later

library color_picker_dialog;

import 'package:flutter/material.dart';

import '../services/color_presets.dart';
import 'app_palette.dart';
import 'color_wheel.dart';

/// Returns the chosen colour, or null if the user cancels.
Future<Color?> showColorPickerDialog(
  BuildContext context, {
  required Color initial,
  String title = '选择颜色',
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => _ColorPickerDialog(initial: initial, title: title),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial, required this.title});

  final Color initial;
  final String title;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late Color _color = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: AnimatedBuilder(
          animation: ColorPresetStore.instance,
          builder: (context, _) {
            final saved = ColorPresetStore.instance.colors;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Neutrals.ink,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: _color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Neutrals.line),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      hexLabel(_color),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Neutrals.inkSoft,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Center(
                  child: ColorWheel(
                    color: _color,
                    size: 210,
                    onChanged: (c) => setState(() => _color = c),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('已保存',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Neutrals.inkSoft)),
                const SizedBox(height: 6),
                SavedColorRow(
                  colors: saved,
                  current: _color,
                  onPick: (c) => setState(() => _color = c),
                  onRemove: (c) => ColorPresetStore.instance.remove(c),
                ),
                if (saved.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '长按已保存的颜色可以删除',
                      style: TextStyle(fontSize: 11, color: Neutrals.inkSoft),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton.icon(
                      key: const Key('color_save'),
                      onPressed: () async {
                        await ColorPresetStore.instance.add(_color);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已保存 ${hexLabel(_color)}'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('保存当前颜色'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      key: const Key('color_confirm'),
                      onPressed: () => Navigator.pop(context, _color),
                      child: const Text('使用'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
