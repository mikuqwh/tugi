/// A feature screen with its siblings one swipe away.
///
/// The home opens a feature here instead of pushing it directly. The bottom
/// strip is the "second interaction zone": dragging it left/right moves to the
/// previous/next feature of the SAME category, and dragging right on the first
/// one opens settings (there is no previous screen to go to).
///
/// Why a strip rather than letting the whole page swipe: every feature screen
/// is full of horizontal drag surfaces (quality sliders, the watermark canvas).
/// A page-wide PageView would fight them for the gesture arena and sliders
/// would start flipping screens. A dedicated strip has no such conflict, and
/// the top strip already means "settings", so the zones stay predictable.
// SPDX-License-Identifier: GPL-3.0-or-later

library feature_pager_screen;

import 'package:flutter/material.dart';

import '../ui/app_palette.dart';
import '../ui/feature_catalog.dart';
import '../ui/settings_panel.dart';

class FeaturePagerScreen extends StatefulWidget {
  const FeaturePagerScreen({
    super.key,
    required this.entries,
    required this.initialIndex,
  });

  final List<FeatureEntry> entries;
  final int initialIndex;

  @override
  State<FeaturePagerScreen> createState() => _FeaturePagerScreenState();
}

class _FeaturePagerScreenState extends State<FeaturePagerScreen> {
  late final PageController _pager =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  double _dragDx = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (index < 0 || index >= widget.entries.length) return;
    setState(() => _index = index);
    _pager.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    // Distance OR fling: a slow drag across the strip should still switch.
    final velocity = details.velocity.pixelsPerSecond.dx;
    final dx = _dragDx.abs() > 60 ? _dragDx : velocity;
    if (dx < -60) {
      _go(_index + 1);
    } else if (dx > 60) {
      // Rightward: previous feature, or settings when there is no previous.
      if (_index == 0) {
        SettingsScope.openOf(context);
      } else {
        _go(_index - 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entries[_index];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: PageView.builder(
        controller: _pager,
        // Swiping the page switches features too. Interactive controls are
        // descendants (sliders, the watermark canvas) and therefore win the
        // gesture arena, so a drag that starts on them still edits instead of
        // flipping the page; the strip remains for discoverability.
        physics: const PageScrollPhysics(),
        onPageChanged: (i) => setState(() => _index = i),
        itemCount: widget.entries.length,
        // Keep every visited page alive: switching to a sibling and back used
        // to reset the screen (the picked file, the sliders, the result).
        itemBuilder: (context, i) => _KeepAlivePage(
          child: widget.entries[i].builder(context),
        ),
      ),
      bottomNavigationBar: _ZoneStrip(
        entries: widget.entries,
        index: _index,
        onDragUpdate: (details) => _dragDx += details.delta.dx,
        onDragEnd: _onDragEnd,
        onPrevious: () => _go(_index - 1),
        onNext: () => _go(_index + 1),
        accent: entry.accent.base,
      ),
    );
  }
}

/// Keeps a feature page's state when it scrolls out of the pager.
///
/// PageView disposes pages outside its cache extent; without this, going to
/// the next feature and back rebuilt Format Convert from scratch and threw away
/// the loaded file.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// The bottom interaction zone.
class _ZoneStrip extends StatelessWidget {
  const _ZoneStrip({
    required this.entries,
    required this.index,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onPrevious,
    required this.onNext,
    required this.accent,
  });

  final List<FeatureEntry> entries;
  final int index;
  final void Function(DragUpdateDetails) onDragUpdate;
  final void Function(DragEndDetails) onDragEnd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final hasPrev = index > 0;
    final hasNext = index < entries.length - 1;

    return GestureDetector(
      key: const Key('feature_zone_strip'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: onDragEnd,
      child: Container(
        decoration: const BoxDecoration(
          color: Neutrals.surface,
          border: Border(top: BorderSide(color: Neutrals.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 54,
            child: Row(
              children: [
                IconButton(
                  key: const Key('feature_prev'),
                  onPressed: hasPrev ? onPrevious : null,
                  icon: const Icon(Icons.chevron_left),
                  color: accent,
                  disabledColor: Neutrals.line,
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entries[index].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Neutrals.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < entries.length; i++)
                            Container(
                              width: 5,
                              height: 5,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == index
                                    ? accent
                                    : Neutrals.inkSoft.withValues(alpha: 0.28),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('feature_next'),
                  onPressed: hasNext ? onNext : null,
                  icon: const Icon(Icons.chevron_right),
                  color: accent,
                  disabledColor: Neutrals.line,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
