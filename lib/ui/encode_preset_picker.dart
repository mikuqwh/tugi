// SPDX-License-Identifier: GPL-3.0-or-later

/// The 快速 / 均衡 / 高质量 selector.
///
/// Three taps, no dropdown: the choice changes both speed and output size, so
/// it belongs next to the other export knobs rather than behind a menu.
library encode_preset_picker;

import 'package:flutter/material.dart';

import '../models/encode_preset.dart';
import 'app_palette.dart';

class EncodePresetPicker extends StatelessWidget {
  const EncodePresetPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.accent,
    this.enabled = true,
  });

  final EncodePreset value;
  final ValueChanged<EncodePreset> onChanged;
  final Color accent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '速度 / 质量',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const Spacer(),
            Text(
              value.detail,
              style: const TextStyle(fontSize: 11, color: Neutrals.inkSoft),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final preset in EncodePreset.values) ...[
              Expanded(
                child: GestureDetector(
                  key: Key('encode_${preset.name}'),
                  onTap: enabled ? () => onChanged(preset) : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: preset == value
                          ? accent.withValues(alpha: 0.16)
                          : Neutrals.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: preset == value ? accent : Neutrals.line,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          preset.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: preset == value
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: preset == value ? accent : Neutrals.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (preset != EncodePreset.values.last) const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }
}
