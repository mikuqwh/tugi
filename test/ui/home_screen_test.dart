/// The home pager: one page per category, 收藏 as its own page.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/home_screen.dart';
import 'package:tugi/services/home_prefs.dart';
import 'package:tugi/ui/feature_catalog.dart';

Future<MemoryHomePrefs> _pump(
  WidgetTester tester, {
  HomePrefsData? initial,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final prefs = MemoryHomePrefs(initial);
  // The flowing background animates forever; reduced motion keeps
  // pumpAndSettle able to settle (the flow has its own dedicated behaviour
  // covered by the widget itself).
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: HomeScreen(prefs: prefs),
  ));
  await tester.pumpAndSettle();
  return prefs;
}

/// Switch to the tab at [index] and settle the pager animation.
Future<void> _swipeTo(WidgetTester tester, int index) async {
  await tester.tap(find.byKey(Key('home_tab_$index')));
  await tester.pumpAndSettle();
}

void main() {
  test('the catalog covers every screen exactly once', () {
    final ids = featureCatalog.map((f) => f.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate id');
    for (final label in [
      'Format Convert',
      'Extract Audio',
      'Images to Video',
      'Video to GIF',
      'Images to GIF',
      'Edit GIF',
      'GIF to Video',
      'GIFs to Images',
      'Compress GIFs',
      'Add watermark',
      'Edit Image',
    ]) {
      expect(featureCatalog.any((f) => f.label == label), isTrue,
          reason: label);
    }
  });

  test('search matches labels and keywords across languages', () {
    expect(searchFeatures('水印').map((f) => f.id), contains('add_watermark'));
    expect(searchFeatures('mp4').map((f) => f.id), contains('format_convert'));
    expect(searchFeatures('gif').map((f) => f.id), contains('video_to_gif'));
    expect(searchFeatures('   '), isEmpty);
    expect(searchFeatures('没有任何功能'), isEmpty);
  });

  testWidgets('one tab per populated category, plus 收藏 and 作品', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('home_tab_0')), findsOneWidget); // 转换
    expect(find.byKey(const Key('home_tab_1')), findsOneWidget); // GIF
    expect(find.byKey(const Key('home_tab_2')), findsOneWidget); // 图片
    expect(find.byKey(const Key('home_tab_3')), findsOneWidget); // 收藏
    expect(find.byKey(const Key('home_tab_4')), findsOneWidget); // 作品
    expect(find.byKey(const Key('home_tab_5')), findsNothing);
    // The first page shows its own features only.
    expect(find.byKey(const Key('home_tile_format_convert')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_video_to_gif')), findsNothing);
  });

  testWidgets('the 作品 tab shows the shelf (empty at first)', (tester) async {
    await _pump(tester);
    await _swipeTo(tester, 4);
    expect(find.byKey(const Key('works_empty')), findsOneWidget);
    expect(find.byKey(const Key('works_search')), findsNothing);
  });

  testWidgets('the GIF page holds the GIF features', (tester) async {
    await _pump(tester);
    await _swipeTo(tester, 1);

    expect(find.byKey(const Key('home_tile_video_to_gif')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_compress_gif')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_format_convert')), findsNothing);
  });

  testWidgets('收藏 is an empty page until something is starred', (tester) async {
    await _pump(tester);
    await _swipeTo(tester, 3);
    expect(find.byKey(const Key('home_favorites_empty')), findsOneWidget);

    // Star on the GIF page, then go look.
    await _swipeTo(tester, 1);
    await tester.tap(find.byKey(const Key('home_star_edit_gif')));
    await tester.pumpAndSettle();
    await _swipeTo(tester, 3);

    expect(find.byKey(const Key('home_tile_fav_edit_gif')), findsOneWidget);
    expect(find.byKey(const Key('home_favorites_empty')), findsNothing);
  });

  testWidgets('the last-used capsule sits in the header and is replaced',
      (tester) async {
    final prefs = await _pump(
      tester,
      initial: const HomePrefsData(lastUsed: 'edit_image'),
    );
    expect(find.byKey(const Key('home_last_used')), findsOneWidget);
    // Just the name in a pill; no section heading and no extra card.
    expect(find.text('Edit Image'), findsWidgets);
    expect(find.text('上次使用'), findsNothing);

    await tester.tap(find.byKey(const Key('home_tile_format_convert')));
    await tester.pumpAndSettle();
    expect((await prefs.load()).lastUsed, 'format_convert');
  });

  testWidgets('pull-down at the top of a page opens search', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('home_search')), findsNothing);

    // Drag DOWN, which the list turns into a top overscroll.
    await tester.drag(find.byKey(const Key('home_tile_format_convert')),
        const Offset(0, 220));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_search')), findsOneWidget);
  });

  testWidgets('search narrows to results and clears back', (tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(const Key('home_search_toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('home_search')), '水印');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_tile_add_watermark')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_format_convert')), findsNothing);
    // The tab strip is hidden while searching.
    expect(find.byKey(const Key('home_tab_0')), findsNothing);

    await tester.tap(find.byKey(const Key('home_search_toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_tab_0')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_format_convert')), findsOneWidget);
  });

  testWidgets(
      'search opened with an empty field shows a hint, not "no results"',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('home_search_toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_search_hint')), findsOneWidget);
    expect(find.byKey(const Key('home_search_empty')), findsNothing);
  });

  testWidgets('an empty search result says so', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('home_search_toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('home_search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_search_empty')), findsOneWidget);
  });

  testWidgets('opening and closing search keeps the current category page',
      (tester) async {
    await _pump(tester);
    await _swipeTo(tester, 1); // GIF
    expect(find.byKey(const Key('home_tile_video_to_gif')), findsOneWidget);

    await tester.drag(
        find.byKey(const Key('home_tile_video_to_gif')), const Offset(0, 220));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_search')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home_search_toggle')));
    await tester.pumpAndSettle();

    // Regression: the pager was rebuilt at page 0 while the pills still said
    // GIF, so the content and the tab strip disagreed.
    expect(find.byKey(const Key('home_tile_video_to_gif')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_format_convert')), findsNothing);
  });

  testWidgets('a stale favourite is dropped by sanitize', (tester) async {
    await _pump(
      tester,
      initial: const HomePrefsData(
        favorites: ['this_feature_was_removed', 'edit_image'],
      ),
    );
    await _swipeTo(tester, 3);
    expect(find.byKey(const Key('home_tile_fav_edit_image')), findsOneWidget);
    expect(find.byKey(const Key('home_tile_fav_this_feature_was_removed')),
        findsNothing);
  });
}
