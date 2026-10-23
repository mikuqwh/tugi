// SPDX-License-Identifier: GPL-3.0-or-later

/// 混淆 / 还原: turn a photo into noise, or put it back with the password.
///
/// Deliberately one screen with one job. The screen shows the original and the
/// result side by side, so a wrong password is obvious immediately instead of
/// after saving.
library scramble_screen;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../services/export_service.dart';
import '../services/scramble_service.dart';
import '../services/works_service.dart';
import '../ui/app_palette.dart';
import '../ui/empty_state.dart';
import '../ui/rainbow_glow.dart';
import '../ui/tokens.dart';
import '../utils/image_scramble.dart';

class ScrambleScreen extends StatefulWidget {
  const ScrambleScreen({
    super.key,
    this.initialImagePath,
    this.service,
  });

  /// Pre-load an image instead of waiting for the picker (works shelf).
  final String? initialImagePath;

  /// Test seam: the host has no image codec for PNG output.
  final ScrambleService? service;

  @override
  State<ScrambleScreen> createState() => _ScrambleScreenState();
}

class _ScrambleScreenState extends State<ScrambleScreen> {
  static const _accent = FeatureColors.scramble;
  static const _on = FeatureColors.scrambleOn;

  ScrambleService get _service =>
      widget.service ?? ScrambleService(workDir: Directory.systemTemp.path);

  final TextEditingController _password = TextEditingController();
  // Mosaic first: it is the mode people expect from this kind of tool --
  // you still see the picture's colours, just not its shapes.
  ScrambleMode _mode = ScrambleMode.mosaic;
  bool _restore = false;
  bool _busy = false;
  String? _error;

  /// Decoded at preview size; `null` until an image is picked.
  DecodedImage? _source;
  String? _inputPath;

  /// Result preview bytes (PNG) and the file that was written.
  Uint8List? _result;
  String? _resultPath;

  /// The scrambled picture, kept so "还原" can undo the run on screen instead
  /// of asking the user to re-pick the original.
  DecodedImage? _scrambled;

  bool _saving = false;

  /// Block edge for the mosaic mode; bigger blocks keep more of the picture.
  int _blockSize = 24;

  /// The restored picture, shown in the ORIGINAL slot: a restore means
  /// "here is your picture back", so it belongs where the original was.
  Uint8List? _restored;

  @override
  void initState() {
    super.initState();
    final preset = widget.initialImagePath;
    if (preset != null && preset.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(preset));
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _load(picked.path);
    } catch (e) {
      setState(() => _error = '选择图片失败: $e');
    }
  }

  Future<void> _load(String path) async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _resultPath = null;
    });
    try {
      // 900 px is enough to judge whether a password is right and keeps the
      // preview transform instant on a phone.
      final decoded = await _service.decode(path, maxSide: 900);
      if (!mounted) return;
      setState(() {
        _inputPath = path;
        _source = decoded;
        _scrambled = null;
        _result = null;
        _resultPath = null;
        _restored = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '读取图片失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canRun =>
      _source != null && _password.text.trim().isNotEmpty && !_busy;

  Future<void> _run() async {
    final source = _source;
    if (source == null || !_canRun) return;
    // Restoring what is already on screen is the common case: you scrambled a
    // picture and want to check it comes back. Only fall back to the picked
    // file when there is no scrambled buffer yet.
    final input = _restore && _scrambled != null ? _scrambled! : source;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final out = await _service.transform(
        input,
        password: _password.text.trim(),
        mode: _mode,
        inverse: _restore,
        blockSize: _blockSize,
      );
      final path = await _service.writeResult(out.png, inverse: _restore);
      if (!mounted) return;
      setState(() {
        _resultPath = path;
        if (_restore) {
          // Left: what came back. Right: the scrambled picture it came from,
          // so the pair still reads as "this -> that".
          _restored = out.png;
          _result = input.bytes;
        } else {
          _result = out.png;
          _restored = null;
          _scrambled = DecodedImage(
            rgba: out.rgba,
            width: input.width,
            height: input.height,
            bytes: out.png,
          );
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final path = _resultPath;
    if (path == null || _saving) return;
    setState(() => _saving = true);
    try {
      final outcome = await ExportService().save(path, album: 'Tugi');
      if (outcome.isSuccess) {
        await WorksService.instance.record(
          originPath: path,
          featureId: 'scramble',
          sourcePath: _inputPath,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(outcome.message ?? '已保存')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFeatureTheme(Accents.violet),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: AccentGradientBackground(
            accent: FeaturePalette.scramble,
          ),
          title: const Text('混淆'),
          backgroundColor: Colors.transparent,
          foregroundColor: _on,
          elevation: 0,
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      Insets.lg, Insets.md, Insets.lg, Insets.md),
                  children: [
                    if (_source == null)
                      _pickCard()
                    else ...[
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '已选图片',
                              style: TextStyle(
                                  fontSize: 12, color: Neutrals.inkSoft),
                            ),
                          ),
                          TextButton.icon(
                            key: const Key('scramble_repick'),
                            onPressed: _busy ? null : _pick,
                            icon: const Icon(Icons.swap_horiz, size: 16),
                            label: const Text('换一张'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 32),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              textStyle: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                      _previewRow(),
                      const SizedBox(height: Insets.md),
                      _buildDirection(),
                      const SizedBox(height: Insets.md),
                      _passwordField(),
                      const SizedBox(height: Insets.md),
                      _modeRow(),
                      if (_mode == ScrambleMode.mosaic) ...[
                        const SizedBox(height: Insets.md),
                        _blockSizeRow(),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: Insets.md),
                        Text(
                          _error!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12.5),
                        ),
                      ],
                      const SizedBox(height: Insets.md),
                      _hint(),
                    ],
                  ],
                ),
              ),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pickCard() {
    return EmptyState(
      icon: Icons.blur_on,
      title: '还没有选择图片',
      hint: '选一张图片开始混淆。混淆后的图片仍是普通 PNG，'
          '任何人拿到都只是一张噪点图，只有用同样的密码才能还原。',
      accent: _accent,
      action: RainbowGlow(
        child: ElevatedButton.icon(
          key: const Key('scramble_pick'),
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('选择图片'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: _on,
            disabledBackgroundColor: _accent.withValues(alpha: 0.16),
            disabledForegroundColor: _accent.withValues(alpha: 0.55),
            minimumSize: const Size(180, 48),
          ),
        ),
      ),
    );
  }

  Widget _previewRow() {
    final source = _source!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _thumb(
            label: _restored != null ? '还原结果' : '原图',
            child: Image.memory(
              _restored ?? source.bytes,
              fit: BoxFit.cover,
              // A corrupt file must not take the screen down; the codec error
              // is shown as a placeholder instead.
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image, color: Neutrals.inkSoft),
            ),
          ),
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: _thumb(
            label: '混淆结果',
            child: _result == null
                ? const Center(
                    child: Icon(Icons.question_mark, color: Neutrals.inkSoft),
                  )
                : Image.memory(
                    _result!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, color: Neutrals.inkSoft),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _thumb({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: Radii.cardAll,
          // Fixed height, not a square: two full-width squares pushed every
          // control below the fold, and the keyboard made it worse.
          child: SizedBox(
            height: 150,
            width: double.infinity,
            child: ColoredBox(color: Neutrals.surface, child: child),
          ),
        ),
        const SizedBox(height: Insets.xs),
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: Neutrals.inkSoft),
        ),
      ],
    );
  }

  Widget _buildDirection() {
    return Row(
      children: [
        for (final restore in [false, true]) ...[
          Expanded(
            child: GestureDetector(
              key: Key(restore ? 'scramble_restore' : 'scramble_apply'),
              onTap: _busy
                  ? null
                  : () => setState(() {
                        _restore = restore;
                        _result = null;
                        _resultPath = null;
                      }),
              child: AnimatedContainer(
                duration: Motion.quick,
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _restore == restore
                      ? _accent.withValues(alpha: 0.16)
                      : Neutrals.surface,
                  borderRadius: Radii.controlAll,
                  border: Border.all(
                    color: _restore == restore ? _accent : Neutrals.line,
                  ),
                ),
                child: Text(
                  restore ? '还原' : '混淆',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight:
                        _restore == restore ? FontWeight.w700 : FontWeight.w500,
                    color: _restore == restore ? _accent : Neutrals.ink,
                  ),
                ),
              ),
            ),
          ),
          if (!restore) const SizedBox(width: Insets.sm),
        ],
      ],
    );
  }

  Widget _passwordField() {
    return TextField(
      key: const Key('scramble_password'),
      controller: _password,
      obscureText: false,
      onChanged: (_) => setState(() {
        _result = null;
        _resultPath = null;
        _restored = null;
      }),
      style: const TextStyle(fontSize: 14),
      decoration: const InputDecoration(
        labelText: '密码',
        hintText: '混淆和还原要用同一个密码',
        prefixIcon: Icon(Icons.key_outlined, size: 18),
      ),
    );
  }

  Widget _modeRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('方式',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            Text(
              _mode.detail,
              style: const TextStyle(fontSize: 11, color: Neutrals.inkSoft),
            ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        Row(
          children: [
            for (final mode in ScrambleMode.values) ...[
              Expanded(
                child: GestureDetector(
                  key: Key('scramble_mode_${mode.name}'),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                            _mode = mode;
                            _result = null;
                            _resultPath = null;
                          }),
                  child: AnimatedContainer(
                    duration: Motion.quick,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _mode == mode
                          ? _accent.withValues(alpha: 0.16)
                          : Neutrals.surface,
                      borderRadius: Radii.chipAll,
                      border: Border.all(
                        color: _mode == mode ? _accent : Neutrals.line,
                      ),
                    ),
                    child: Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            _mode == mode ? FontWeight.w700 : FontWeight.w500,
                        color: _mode == mode ? _accent : Neutrals.ink,
                      ),
                    ),
                  ),
                ),
              ),
              if (mode != ScrambleMode.values.last)
                const SizedBox(width: Insets.sm),
            ],
          ],
        ),
      ],
    );
  }

  /// Block size for mosaic: the coarser the block, the more of the original
  /// you can still recognise.
  Widget _blockSizeRow() {
    const options = <int, String>{8: '细', 16: '中', 24: '粗', 40: '很粗'};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('色块大小',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: Insets.sm),
        Row(
          children: [
            for (final entry in options.entries) ...[
              Expanded(
                child: GestureDetector(
                  key: Key('scramble_block_${entry.key}'),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                            _blockSize = entry.key;
                            _result = null;
                            _resultPath = null;
                            _restored = null;
                          }),
                  child: AnimatedContainer(
                    duration: Motion.quick,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _blockSize == entry.key
                          ? _accent.withValues(alpha: 0.16)
                          : Neutrals.surface,
                      borderRadius: Radii.chipAll,
                      border: Border.all(
                        color:
                            _blockSize == entry.key ? _accent : Neutrals.line,
                      ),
                    ),
                    child: Text(
                      entry.value,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: _blockSize == entry.key
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: _blockSize == entry.key ? _accent : Neutrals.ink,
                      ),
                    ),
                  ),
                ),
              ),
              if (entry.key != 40) const SizedBox(width: Insets.sm),
            ],
          ],
        ),
      ],
    );
  }

  Widget _hint() {
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: Neutrals.surface,
        borderRadius: Radii.cardAll,
        border: Border.all(color: Neutrals.line),
      ),
      child: const Text(
        '提示：还原时密码和方式都要和混淆时一致。混淆只打乱像素位置并做一次'
        '按位异或，不改变尺寸，所以还原是无损的；图片最好小于 4K，'
        '更大的图片会慢一些。',
        style: TextStyle(fontSize: 11.5, height: 1.6, color: Neutrals.inkSoft),
      ),
    );
  }

  Widget _bottomBar() {
    if (_source == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      minimum:
          const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, Insets.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_resultPath != null) ...[
            SizedBox(
              width: double.infinity,
              child: RainbowGlow(
                child: ElevatedButton.icon(
                  key: const Key('scramble_save'),
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_alt),
                  label: Text(_saving ? '保存中…' : '保存到相册'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: _on,
                    disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                    disabledForegroundColor: _accent.withValues(alpha: 0.55),
                    minimumSize: const Size(0, 52),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Insets.sm),
          ],
          SizedBox(
            width: double.infinity,
            child: RainbowGlow(
              child: ElevatedButton.icon(
                key: const Key('scramble_run'),
                onPressed: _canRun ? _run : null,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_restore ? Icons.lock_open : Icons.blur_on),
                label: Text(_busy
                    ? '处理中…'
                    : _restore
                        ? '还原图片'
                        : '混淆图片'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: _on,
                  // Pale until a picture AND a password are there: the same
                  // "not ready is pale" rule as every other feature.
                  disabledBackgroundColor: _accent.withValues(alpha: 0.16),
                  disabledForegroundColor: _accent.withValues(alpha: 0.55),
                  minimumSize: const Size(0, 52),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
