/// Tugi's home: one swipeable page per category, plus 收藏.
///
/// The single long list was the problem: eleven rows and a favourites section
/// stacked on top of each other, scrolled forever. Now each category owns a
/// page and the pages swipe horizontally; 收藏 gets a page of its own.
///
/// Everything reads [featureCatalog], so adding a feature is still one entry.
// SPDX-License-Identifier: GPL-3.0-or-later

library home_screen;

import 'package:flutter/material.dart';

import '../services/home_prefs.dart';
import '../ui/app_palette.dart';
import '../ui/tokens.dart';
import '../ui/feature_catalog.dart';
import '../ui/page_transitions.dart';
import '../ui/flow_background.dart';
import '../ui/settings_panel.dart';
import '../ui/theme_settings.dart';
import 'feature_pager_screen.dart';
import 'works_screen.dart';

/// What a home page shows.
enum _TabKind { category, favorites, works }

/// A tab in the home pager.
class _HomeTab {
  const _HomeTab(
    this.label,
    this.color, {
    this.kind = _TabKind.category,
    this.category,
  });

  final String label;
  final Color color;
  final _TabKind kind;
  final FeatureCategory? category;

  bool get favorites => kind == _TabKind.favorites;
  bool get works => kind == _TabKind.works;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.prefs});

  /// Injectable so widget tests do not touch path_provider.
  final HomePrefs? prefs;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomePrefs _prefs = widget.prefs ?? FileHomePrefs();
  final PageController _pager = PageController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  HomePrefsData _data = const HomePrefsData();
  bool _ready = false;
  bool _searching = false;
  int _index = 0;

  /// Accumulated rightward overscroll on the first page.
  double _pullRight = 0;

  /// Accumulated downward pull at the top of a page.
  double _pullDown = 0;

  List<FeatureCategory> get _categories => populatedCategories;

  List<_HomeTab> get _tabs => [
        for (final c in _categories)
          _HomeTab(c.title, c.accent.base, category: c),
        const _HomeTab('收藏', Color(0xFFFFB300), kind: _TabKind.favorites),
        const _HomeTab('作品', Color(0xFF00897B), kind: _TabKind.works),
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pager.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = sanitize(await _prefs.load());
    if (!mounted) return;
    setState(() {
      _data = data;
      _ready = true;
    });
  }

  Future<void> _persist(HomePrefsData data) async {
    setState(() => _data = data);
    await _prefs.save(data);
  }

  /// Opening a feature enters the pager, so its siblings are one bottom-strip
  /// swipe away.
  void _open(FeatureEntry entry) {
    _persist(_data.copyWith(lastUsed: entry.id));
    final siblings = featuresIn(entry.category);
    final index = siblings.indexWhere((e) => e.id == entry.id);
    Navigator.push(
      context,
      tugiRoute((_) => FeaturePagerScreen(
            entries: siblings,
            initialIndex: index < 0 ? 0 : index,
          )),
    );
  }

  void _toggleFavorite(FeatureEntry entry) {
    final favorites = List<String>.from(_data.favorites);
    if (favorites.contains(entry.id)) {
      favorites.remove(entry.id);
    } else {
      favorites.add(entry.id);
    }
    _persist(_data.copyWith(favorites: favorites));
  }

  void _goTo(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _pager.animateToPage(
      index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _search.clear();
    });
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
      return;
    }
    // Closing search rebuilds the pager (the body cross-fades), and a fresh
    // PageView starts at its controller's initial page. Restore the page the
    // tab strip still shows, otherwise the pills say GIF while the content
    // shows 转换.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _searching) return;
      if (_pager.hasClients) _pager.jumpToPage(_index);
    });
  }

  /// Right-swipe past the FIRST page means "there is nothing before this":
  /// open settings, mirroring the top-zone gesture.
  bool _onScroll(ScrollNotification notification) {
    if (notification is OverscrollNotification) {
      final horizontal = notification.metrics.axis == Axis.horizontal;
      if (horizontal) {
        // Pulling the FIRST page right: nothing is before it, so settings.
        if (notification.metrics.pixels <= 0 &&
            notification.overscroll < 0 &&
            _index == 0) {
          _pullRight -= notification.overscroll;
          if (_pullRight > 70) {
            _pullRight = 0;
            SettingsScope.openOf(context);
          }
        }
      } else if (notification.metrics.pixels <= 0 &&
          notification.overscroll < 0) {
        // Pulling down at the top of a page opens search, the gesture people
        // already expect from a list.
        _pullDown -= notification.overscroll;
        if (_pullDown > 64) {
          _pullDown = 0;
          if (!_searching) _toggleSearch();
        }
      }
    } else if (notification is ScrollEndNotification) {
      _pullRight = 0;
      _pullDown = 0;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeSettingsController.instance,
      builder: (context, _) {
        final settings = ThemeSettingsController.instance.value;
        final query = _search.text.trim();
        final results = searchFeatures(query);

        return Scaffold(
          body: SafeArea(
            child: !_ready
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(settings),
                      // Collapsing beats disappearing: the header and the body
                      // then change together instead of the strip blinking out.
                      AnimatedSize(
                        duration: const Duration(milliseconds: 420),
                        curve: Curves.easeOutQuart,
                        alignment: Alignment.topCenter,
                        child: _searching
                            ? const SizedBox(width: double.infinity)
                            : _tabStrip(settings),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 520),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: CurvedAnimation(
                              parent: animation,
                              curve: const Interval(0.15, 1,
                                  curve: Curves.easeOut),
                            ),
                            child: child,
                          ),
                          child: _searching
                              ? KeyedSubtree(
                                  key: const ValueKey('search'),
                                  child: _searchResults(results, settings),
                                )
                              : KeyedSubtree(
                                  key: const ValueKey('pages'),
                                  child:
                                      NotificationListener<ScrollNotification>(
                                    onNotification: _onScroll,
                                    child: PageView.builder(
                                      controller: _pager,
                                      itemCount: _tabs.length,
                                      onPageChanged: (i) =>
                                          setState(() => _index = i),
                                      itemBuilder: (context, i) =>
                                          _page(i, settings),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _header(ThemeSettings settings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 4),
      child: Row(
        children: [
          Expanded(
            // Opening search replaces the wordmark with the field: cross-fade
            // plus a horizontal size transition, so the row does not jump.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 520),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axis: Axis.horizontal,
                  child: child,
                ),
              ),
              child: _searching
                  ? _searchField(settings)
                  : Row(
                      key: const ValueKey('wordmark'),
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.asset(
                            'assets/brand/app_icon.png',
                            width: 34,
                            height: 34,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '图叽',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: settings.onBackground,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Tugi',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color:
                                settings.onBackground.withValues(alpha: 0.85),
                            letterSpacing: 0.4,
                          ),
                        ),
                        const Spacer(),
                        if (!_searching) _lastUsedCapsule(settings),
                      ],
                    ),
            ),
          ),
          IconButton(
            key: const Key('home_settings'),
            tooltip: '设置',
            icon: const Icon(Icons.tune_rounded),
            color: settings.onBackground,
            onPressed: () => SettingsScope.openOf(context),
          ),
          IconButton(
            key: const Key('home_search_toggle'),
            tooltip: _searching ? '关闭搜索' : '搜索',
            icon: Icon(_searching ? Icons.close : Icons.search),
            color: _searching ? Neutrals.ink : settings.onBackground,
            onPressed: _toggleSearch,
          ),
        ],
      ),
    );
  }

  Widget _searchField(ThemeSettings settings) {
    return TextField(
      key: const Key('home_search'),
      controller: _search,
      focusNode: _searchFocus,
      onChanged: (_) => setState(() {}),
      textInputAction: TextInputAction.search,
      style: TextStyle(
          color: settings.onBackground == Colors.white
              ? Colors.white
              : Neutrals.ink),
      decoration: InputDecoration(
        hintText: '搜索功能，比如「水印」「mp4」',
        hintStyle: const TextStyle(color: Neutrals.inkSoft),
        isDense: true,
        filled: true,
        fillColor: Neutrals.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Neutrals.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Neutrals.line),
        ),
      ),
    );
  }

  /// A small pill with just the name of the last opened feature, so it is
  /// reachable from every page without spending a section on it.
  Widget _lastUsedCapsule(ThemeSettings settings) {
    final last = featureById(_data.lastUsed ?? '');
    if (last == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: GestureDetector(
        key: const Key('home_last_used'),
        onTap: () => _open(last),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Neutrals.surface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Neutrals.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_rounded,
                  size: 14, color: settings.accentColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  last.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Neutrals.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabStrip(ThemeSettings settings) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        itemCount: _tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final tab = _tabs[i];
          final selected = i == _index;
          return Pressable(
            key: Key('home_tab_$i'),
            scale: 0.95,
            onTap: () => _goTo(i),
            child: AnimatedContainer(
              duration: Motion.medium,
              curve: Motion.enter,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? settings.onBackground.withValues(alpha: 0.16)
                    : null,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? settings.onBackground.withValues(alpha: 0.40)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tab.favorites || tab.works) ...[
                    Icon(
                      tab.favorites
                          ? Icons.star_rounded
                          : Icons.collections_outlined,
                      size: 15,
                      color: selected
                          ? settings.onBackground
                          : settings.onBackground.withValues(alpha: 0.72),
                    ),
                    const SizedBox(width: 4),
                  ],
                  AnimatedDefaultTextStyle(
                    duration: Motion.medium,
                    curve: Motion.enter,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? settings.onBackground
                          : settings.onBackground.withValues(alpha: 0.75),
                    ),
                    child: Text(tab.label),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _page(int index, ThemeSettings settings) {
    // Every page animates in when it becomes the current one. Pages are kept
    // alive by the PageView, so without this the switch is instant.
    return PageReveal(
      active: index == _index,
      child: _pageContent(index, settings),
    );
  }

  Widget _pageContent(int index, ThemeSettings settings) {
    final tab = _tabs[index];
    if (tab.works) {
      return const WorksScreen();
    }
    if (tab.favorites) {
      final favorites =
          _data.favorites.map(featureById).whereType<FeatureEntry>().toList();
      if (favorites.isEmpty) return const _EmptyFavorites();
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          for (final entry in favorites) _card(entry, prefix: 'fav_'),
        ],
      );
    }

    final category = tab.category ?? _categories.first;
    final entries = featuresIn(category);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _sectionLabel(category.blurb, settings),
        for (final entry in entries) _card(entry),
      ],
    );
  }

  Widget _searchResults(List<FeatureEntry> results, ThemeSettings settings) {
    // Search can be opened with nothing typed (pull-down, icon); an empty
    // field must not read as "no results for 「」".
    if (_search.text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '输入功能名或关键词，比如「水印」「mp4」。',
          key: const Key('home_search_hint'),
          style: TextStyle(
            fontSize: 13,
            color: settings.onBackground.withValues(alpha: 0.75),
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '没找到「${_search.text.trim()}」',
          key: const Key('home_search_empty'),
          style: TextStyle(color: settings.onBackground.withValues(alpha: 0.8)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _sectionLabel('${results.length} 个结果', settings),
        for (final entry in results) _card(entry),
      ],
    );
  }

  Widget _sectionLabel(String text, ThemeSettings settings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: settings.onBackground.withValues(alpha: 0.78),
        ),
      ),
    );
  }

  /// One feature as a wide bar.
  ///
  /// Square tiles made every page look empty -- two rows of two and then a lot
  /// of nothing. A full-width bar carries icon, name, description and action on
  /// one row, so the page looks dense at any feature count.
  Widget _card(FeatureEntry entry, {String prefix = ''}) {
    final accent = entry.accent;
    final favorite = _data.favorites.contains(entry.id);
    // Staggered entrance: the list assembles instead of appearing all at
    // once. The delay is capped so a long search result list is not slow.
    final index = _featureIndexOf(entry);
    return EnterOnce(
      delay: Duration(
        milliseconds: (index.clamp(0, 6) * Motion.stagger.inMilliseconds),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Material(
          color: Neutrals.surface,
          borderRadius: Radii.cardAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('home_tile_$prefix${entry.id}'),
            borderRadius: Radii.cardAll,
            onTap: () => _open(entry),
            onLongPress: () => _toggleFavorite(entry),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.md, Insets.md, Insets.sm, Insets.md),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: accent.gradient,
                      borderRadius: BorderRadius.circular(13),
                      boxShadow: [
                        BoxShadow(
                          color: accent.base.withValues(alpha: 0.26),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Icon(entry.icon, color: accent.on, size: 23),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.label,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Neutrals.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          entry.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: Neutrals.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('home_star_$prefix${entry.id}'),
                    tooltip: favorite ? '取消收藏' : '收藏',
                    icon: Icon(
                      favorite
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color:
                          favorite ? const Color(0xFFFFB300) : Neutrals.inkSoft,
                      size: 21,
                    ),
                    onPressed: () => _toggleFavorite(entry),
                  ),
                  Icon(Icons.chevron_right, color: accent.base, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Position of [entry] in the current page, for the entrance stagger.
  int _featureIndexOf(FeatureEntry entry) {
    final tab = _tabs[_index];
    final entries = tab.category == null
        ? const <FeatureEntry>[]
        : featuresIn(tab.category!);
    final at = entries.indexWhere((e) => e.id == entry.id);
    return at < 0 ? 0 : at;
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('home_favorites_empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.star_outline_rounded, size: 44, color: Neutrals.inkSoft),
          SizedBox(height: 10),
          Text(
            '还没有收藏',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Neutrals.ink,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '点功能右侧的星标，就会出现在这里',
            style: TextStyle(fontSize: 12.5, color: Neutrals.inkSoft),
          ),
        ],
      ),
    );
  }
}
