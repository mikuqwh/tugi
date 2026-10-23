// SPDX-License-Identifier: GPL-3.0-or-later

/// The feature pager keeps state, and the strip is the only thing that
/// switches pages.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/screens/feature_pager_screen.dart';
import 'package:tugi/ui/eager_pan.dart';
import 'package:tugi/ui/feature_catalog.dart';

/// A stand-in feature that counts its own builds, like a real screen holding a
/// picked file.
class _Counter extends StatefulWidget {
  const _Counter({required this.label});

  final String label;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.label)),
      body: Center(
        child: TextButton(
          onPressed: () => setState(() => taps++),
          child: Text('${widget.label}: $taps'),
        ),
      ),
    );
  }
}

List<FeatureEntry> _entries() => [
      FeatureEntry(
        id: 'video_to_gif',
        label: 'First',
        subtitle: 'first',
        icon: Icons.videocam,
        category: FeatureCategory.gif,
        builder: (_) => const _Counter(label: 'First'),
      ),
      FeatureEntry(
        id: 'images_to_gif',
        label: 'Second',
        subtitle: 'second',
        icon: Icons.photo,
        category: FeatureCategory.gif,
        builder: (_) => const _Counter(label: 'Second'),
      ),
      FeatureEntry(
        id: 'edit_gif',
        label: 'Third',
        subtitle: 'third',
        icon: Icons.edit,
        category: FeatureCategory.gif,
        builder: (_) => const _Counter(label: 'Third'),
      ),
    ];

void main() {
  testWidgets('state survives a switch away and back', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FeaturePagerScreen(entries: _entries(), initialIndex: 0),
    ));
    await tester.pumpAndSettle();

    // Interact with the first page so it has state to lose.
    await tester.tap(find.text('First: 0'));
    await tester.pumpAndSettle();
    expect(find.text('First: 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feature_next')));
    await tester.pumpAndSettle();
    expect(find.text('Second: 0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feature_prev')));
    await tester.pumpAndSettle();
    // Without AutomaticKeepAlive this would read "First: 0" again.
    expect(find.text('First: 1'), findsOneWidget);
  });

  testWidgets('swiping the page switches features', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FeaturePagerScreen(entries: _entries(), initialIndex: 0),
    ));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('Second: 0'), findsOneWidget);

    // And back by swiping the other way.
    await tester.fling(find.byType(PageView), const Offset(400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('First: 0'), findsOneWidget);
  });

  testWidgets('a drag on an interactive child does not flip the page',
      (tester) async {
    // Stands in for the watermark canvas: a page that owns its own pan.
    var pans = 0;
    final entries = [
      FeatureEntry(
        id: 'video_to_gif',
        label: 'Canvas',
        subtitle: 'canvas',
        icon: Icons.text_fields,
        category: FeatureCategory.gif,
        builder: (_) => Scaffold(
          body: Center(
            child: EagerPanDetector(
              onUpdate: (_) => pans++,
              child: Container(
                key: const Key('fake_canvas'),
                width: 300,
                height: 300,
                color: Colors.amber,
              ),
            ),
          ),
        ),
      ),
      FeatureEntry(
        id: 'images_to_gif',
        label: 'Other',
        subtitle: 'other',
        icon: Icons.photo,
        category: FeatureCategory.gif,
        builder: (_) => const _Counter(label: 'Other'),
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: FeaturePagerScreen(entries: entries, initialIndex: 0),
    ));
    await tester.pumpAndSettle();

    await tester.drag(
        find.byKey(const Key('fake_canvas')), const Offset(-250, 0));
    await tester.pumpAndSettle();

    // The page stayed AND the child received the drag.
    expect(find.byKey(const Key('fake_canvas')), findsOneWidget);
    expect(pans, greaterThan(0));
  });
}
