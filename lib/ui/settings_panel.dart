// SPDX-License-Identifier: GPL-3.0-or-later

/// The settings panel: a card that slides in from the left, floating above
/// the app rather than replacing it.
///
/// Two pieces:
///   * [SettingsHost] lives above the Navigator (mounted from
///     `MaterialApp.builder`), so every screen shares it and the panel can
///     cover whatever is open.
///   * a horizontal drag that STARTS in the top interaction zone opens it
///     (see [topZoneHeight]). Sliders and page swipes are descendants in the
///     gesture arena, so they keep winning; only drags over chrome and empty
///     space reach this detector.
///
/// The panel closes three ways: the X, the scrim, and a left-swipe on the panel
/// itself (the scrim alone was easy to miss).
// SPDX-License-Identifier: GPL-3.0-or-later

library settings_panel;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/background_store.dart';
import '../services/color_presets.dart';
import 'app_palette.dart';
import 'color_wheel.dart';
import 'flow_background.dart';
import 'theme_settings.dart';

/// Lets a screen open/close the panel without knowing where it is mounted.
class SettingsScope extends InheritedWidget {
  const SettingsScope({
    super.key,
    required this.open,
    required this.close,
    required this.isOpen,
    required super.child,
  });

  final VoidCallback open;
  final VoidCallback close;
  final bool isOpen;

  static SettingsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>();

  /// Convenience for screens/gestures.
  static void openOf(BuildContext context) => maybeOf(context)?.open();

  @override
  bool updateShouldNotify(SettingsScope old) => old.isOpen != isOpen;
}

/// Height of the "chrome / empty space" strip at the top of every screen.
///
/// Generous on purpose: it covers the status bar, the home header and a
/// feature screen's app bar, which is where a right-swipe should mean
/// "settings" rather than "go back".
double topZoneHeight(BuildContext context) =>
    MediaQuery.of(context).padding.top + 132;

class SettingsHost extends StatefulWidget {
  const SettingsHost({super.key, required this.child});

  final Widget child;

  @override
  State<SettingsHost> createState() => _SettingsHostState();
}

class _SettingsHostState extends State<SettingsHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 240),
  );

  bool _shown = false;
  double _dragStartY = 0;
  double _dragDx = 0;

  /// True while a text field owns the focus.
  ///
  /// The top-zone swipe must be fully detached then: a text selection handle
  /// drag is a horizontal drag too, and the ancestor recogniser was stealing
  /// it -- dragging the handle to extend a selection opened settings instead.
  bool _editingText = false;

  void _open() {
    if (_animation.value == 1) return;
    setState(() => _shown = true);
    _animation.forward();
  }

  void _close() {
    if (_animation.value == 0) return;
    _animation.reverse().whenComplete(() {
      if (mounted) setState(() => _shown = false);
    });
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  void _onFocusChanged() {
    final context = FocusManager.instance.primaryFocus?.context;
    final editing = context != null &&
        (context.widget is EditableText ||
            context.findAncestorWidgetOfExactType<EditableText>() != null);
    if (editing != _editingText && mounted) {
      setState(() => _editingText = editing);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topZone = topZoneHeight(context);

    // The whole app is light: status-bar icons must be dark or they vanish
    // into the background.
    final app = AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Neutrals.surface,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: widget.child,
    );

    return SettingsScope(
      open: _open,
      close: _close,
      isOpen: _animation.value > 0.5,
      child: Stack(
        children: [
          // While a field is focused the detector is not mounted at all: a
          // recogniser that merely ignores the gesture would still win the
          // arena and block the selection handle.
          if (_editingText)
            app
          else
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (details) {
                _dragStartY = details.globalPosition.dy;
                _dragDx = 0;
              },
              onHorizontalDragUpdate: (details) {
                _dragDx += details.delta.dx;
              },
              onHorizontalDragEnd: (_) {
                final rightward = _dragDx > 56;
                final inTopZone = _dragStartY <= topZone;
                if (rightward && inTopZone && !_shown) _open();
              },
              child: app,
            ),
          // The panel lives above the Navigator, so it has no Overlay of its
          // own -- and Material 3 sliders (and tooltips) REQUIRE one. A local
          // Overlay is the smallest fix: it wraps just the panel, leaving the
          // app's own Navigator/Overlay untouched.
          if (_shown)
            Positioned.fill(
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (context) => Stack(
                      children: [
                        _Scrim(animation: _animation, onTap: _close),
                        _Panel(animation: _animation, onClose: _close),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.animation, required this.onTap});

  final Animation<double> animation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) => GestureDetector(
          key: const Key('settings_scrim'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.32 * animation.value),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.animation, required this.onClose});

  final Animation<double> animation;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: width * 0.88,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(animation.value);
          // Slide in, then a small scale + yaw so it reads as a card floating
          // over the app instead of a page that replaced it.
          final matrix = Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..translateByDouble(-width * 0.88 * (1 - t), 0.0, 0.0, 1.0)
            ..rotateY(-0.08 * (1 - t))
            ..scaleByDouble(0.94 + 0.06 * t, 0.94 + 0.06 * t, 1.0, 1.0);
          return Transform(
            alignment: Alignment.centerLeft,
            transform: matrix,
            child: child,
          );
        },
        child: _SwipeToClose(
          onClose: onClose,
          child: Container(
            key: const Key('settings_panel'),
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.horizontal(right: Radius.circular(26)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 28,
                  offset: Offset(8, 0),
                ),
              ],
            ),
            // A Material is required: ListTile/SwitchListTile paint ink on it.
            child: Material(
              color: Neutrals.surface,
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(26)),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                child: AnimatedBuilder(
                  animation: ThemeSettingsController.instance,
                  builder: (context, _) => _SettingsBody(onClose: onClose),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A left drag anywhere on the panel closes it.
class _SwipeToClose extends StatefulWidget {
  const _SwipeToClose({required this.onClose, required this.child});

  final VoidCallback onClose;
  final Widget child;

  @override
  State<_SwipeToClose> createState() => _SwipeToCloseState();
}

class _SwipeToCloseState extends State<_SwipeToClose> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('settings_swipe_close'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _dx = 0,
      onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
      onHorizontalDragEnd: (_) {
        if (_dx < -56) widget.onClose();
        _dx = 0;
      },
      child: widget.child,
    );
  }
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  bool _customAccent = false;
  bool _importing = false;

  ThemeSettingsController get _controller => ThemeSettingsController.instance;
  ThemeSettings get _settings => _controller.value;

  Future<void> _importImage() async {
    setState(() => _importing = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (picked == null) return;
      final stored = await importBackground(picked.path);
      await _controller.update(_settings.copyWith(
        background: BackgroundStyle.image,
        customImagePath: stored,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final hsv = HSVColor.fromColor(settings.accentColor);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 24),
      children: [
        Row(
          children: [
            const Text(
              '设置',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Neutrals.ink,
              ),
            ),
            const Spacer(),
            IconButton(
              key: const Key('settings_close'),
              onPressed: widget.onClose,
              icon: const Icon(Icons.close),
              color: Neutrals.ink,
            ),
          ],
        ),
        const SizedBox(height: 4),
        _Preview(settings: settings),
        const SizedBox(height: 18),
        _label('背景'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final style in BackgroundStyle.values)
              _Choice(
                key: Key('settings_bg_${style.name}'),
                label: style.label,
                blurb: style.blurb,
                selected: settings.background == style,
                onTap: () =>
                    _controller.update(settings.copyWith(background: style)),
              ),
          ],
        ),
        if (settings.background == BackgroundStyle.image) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < backgroundPresets.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    key: Key('settings_bg_preset_$i'),
                    onTap: () => _controller.update(settings.copyWith(
                      imagePreset: i,
                      clearCustomImage: true,
                    )),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: settings.customImagePath == null &&
                                  settings.imagePreset == i
                              ? Neutrals.ink
                              : Colors.transparent,
                          width: 2,
                        ),
                        image: DecorationImage(
                          image: AssetImage(backgroundPresets[i]),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              GestureDetector(
                key: const Key('settings_bg_import'),
                // Opaque on purpose: the tile below is a Container whose
                // decoration IS the image once one is set, which does not hit
                // test on its own -- that is why replacing it looked dead.
                behavior: HitTestBehavior.opaque,
                onTap: _importing ? null : _importImage,
                // Explicit size: a Stack inside a Row gets unbounded width.
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Neutrals.bg,
                          border: Border.all(
                            color: settings.customImagePath != null
                                ? Neutrals.ink
                                : Neutrals.line,
                            width: settings.customImagePath != null ? 2 : 1,
                          ),
                          image: settings.customImagePath != null
                              ? DecorationImage(
                                  image: FileImage(
                                      File(settings.customImagePath!)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                      ),
                      if (settings.customImagePath != null)
                        // A visible replace affordance over the picture.
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Container(
                            margin: const EdgeInsets.all(3),
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(Icons.swap_horiz,
                                size: 13, color: Colors.white),
                          ),
                        )
                      else
                        Center(
                          child: Icon(
                            _importing
                                ? Icons.hourglass_top
                                : Icons.add_photo_alternate_outlined,
                            color: Neutrals.inkSoft,
                            size: 22,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SliderRow(
            key: const Key('settings_bg_opacity'),
            label: '透明度',
            value: settings.imageOpacity,
            min: 0.02,
            max: 0.45,
            display: '${(settings.imageOpacity * 100).round()}%',
            onChanged: (v) =>
                _controller.update(settings.copyWith(imageOpacity: v)),
          ),
        ],
        const SizedBox(height: 20),
        _label('主题色'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < accentPresets.length; i++)
              GestureDetector(
                key: Key('settings_accent_$i'),
                onTap: () {
                  setState(() => _customAccent = false);
                  _controller.update(settings.copyWith(
                    accentValue: accentPresets[i].color.toARGB32(),
                  ));
                },
                // No Tooltip here: the panel is mounted above the Navigator,
                // so there is no Overlay for one to attach to.
                child: Semantics(
                  label: accentPresets[i].label,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accentPresets[i].color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: !_customAccent &&
                                settings.accentValue ==
                                    accentPresets[i].color.toARGB32()
                            ? Neutrals.ink
                            : Colors.transparent,
                        width: 2.4,
                      ),
                    ),
                  ),
                ),
              ),
            GestureDetector(
              key: const Key('settings_accent_custom'),
              onTap: () => setState(() => _customAccent = !_customAccent),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: _customAccent ? Neutrals.ink : Neutrals.line,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.palette_outlined,
                        size: 16,
                        color: _customAccent ? Neutrals.ink : Neutrals.inkSoft),
                    const SizedBox(width: 4),
                    Text(
                      '自调',
                      style: TextStyle(
                        fontSize: 12,
                        color: _customAccent ? Neutrals.ink : Neutrals.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_customAccent) ...[
          const SizedBox(height: 12),
          Center(
            child: ColorWheel(
              color: settings.accentColor,
              size: 200,
              onChanged: (c) => _controller.update(
                settings.copyWith(accentValue: c.toARGB32()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: settings.accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                hexLabel(settings.accentColor),
                style: const TextStyle(fontSize: 12, color: Neutrals.inkSoft),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('settings_save_color'),
                onPressed: () async {
                  // Capture the messenger before the await: using `context`
                  // afterwards is exactly the async-gap warning.
                  final messenger = ScaffoldMessenger.of(context);
                  await ColorPresetStore.instance.add(settings.accentColor);
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('已保存 ${hexLabel(settings.accentColor)}'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          AnimatedBuilder(
            animation: ColorPresetStore.instance,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SavedColorRow(
                    colors: ColorPresetStore.instance.colors,
                    current: settings.accentColor,
                    onPick: (c) => _controller
                        .update(settings.copyWith(accentValue: c.toARGB32())),
                    onRemove: (c) => ColorPresetStore.instance.remove(c),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '长按已保存的颜色可以删除',
                    key: Key('settings_saved_hint'),
                    style: TextStyle(fontSize: 11, color: Neutrals.inkSoft),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (settings.background != BackgroundStyle.image) ...[
          const SizedBox(height: 4),
          _SliderRow(
            key: const Key('settings_bg_alpha'),
            label: '透明度',
            value: settings.backgroundOpacity,
            min: 0.2,
            max: 1.0,
            display: '${(settings.backgroundOpacity * 100).round()}%',
            onChanged: (v) =>
                _controller.update(settings.copyWith(backgroundOpacity: v)),
          ),
        ],
        const SizedBox(height: 16),
        _label('动效'),
        SwitchListTile(
          key: const Key('settings_motion'),
          contentPadding: EdgeInsets.zero,
          value: settings.motion,
          onChanged: (v) => _controller.update(settings.copyWith(motion: v)),
          title: const Text('动画与彩虹光效',
              style: TextStyle(fontSize: 14, color: Neutrals.ink)),
          subtitle: const Text('关闭后界面切换与背景流动都会停下',
              style: TextStyle(fontSize: 12, color: Neutrals.inkSoft)),
        ),
        const SizedBox(height: 8),
        _label('关于'),
        const SizedBox(height: 8),
        const Text(
          'Tugi 图叽 · 0.2.0\n'
          '所有处理都在本机完成，不上传、不联网。',
          style:
              TextStyle(fontSize: 12.5, height: 1.6, color: Neutrals.inkSoft),
        ),
        const SizedBox(height: 18),
        Center(
          child: Text(
            '在顶部区域右滑打开，左滑或点空白处关闭',
            style: TextStyle(
              fontSize: 11.5,
              color: Neutrals.inkSoft.withValues(alpha: 0.8),
            ),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom),
      ],
    );
  }

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: Neutrals.inkSoft,
          letterSpacing: 0.2,
        ),
      );
}

/// A live miniature of the home screen with the current settings applied.
class _Preview extends StatelessWidget {
  const _Preview({required this.settings});

  final ThemeSettings settings;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: const Key('settings_preview'),
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            switch (settings.background) {
              BackgroundStyle.plain => DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      settings.accentColor
                          .withValues(alpha: settings.backgroundOpacity),
                      Neutrals.bg,
                    ),
                  ),
                ),
              BackgroundStyle.flow => FlowBackground(
                  color: settings.accentColor,
                  opacity: settings.backgroundOpacity,
                  animate: settings.motion,
                  period: const Duration(seconds: 22),
                ),
              BackgroundStyle.image => Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Neutrals.bg),
                    if (settings.backgroundImage != null)
                      Opacity(
                        opacity: settings.imageOpacity,
                        child: Image(
                          image: settings.backgroundImage!,
                          fit: BoxFit.cover,
                        ),
                      ),
                  ],
                ),
            },
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: settings.accentColor,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 42,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Neutrals.ink.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 46,
                        height: 12,
                        decoration: BoxDecoration(
                          color: settings.accentColor.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Row(
                      children: [
                        for (var i = 0; i < 2; i++)
                          Expanded(
                            child: Container(
                              margin: EdgeInsets.only(right: i == 0 ? 8 : 0),
                              decoration: BoxDecoration(
                                color: Neutrals.surface.withValues(alpha: 0.94),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: settings.accentColor,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    width: 52,
                                    height: 6,
                                    color: Neutrals.ink.withValues(alpha: 0.55),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    width: 34,
                                    height: 5,
                                    color: Neutrals.inkSoft
                                        .withValues(alpha: 0.35),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Neutrals.inkSoft)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11.5, color: Neutrals.inkSoft),
          ),
        ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.blurb,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String blurb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 104,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Neutrals.bg : Neutrals.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Neutrals.ink : Neutrals.line,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Neutrals.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              blurb,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: Neutrals.inkSoft),
            ),
          ],
        ),
      ),
    );
  }
}
