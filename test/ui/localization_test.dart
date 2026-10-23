// SPDX-License-Identifier: GPL-3.0-or-later

/// Chinese Material localizations: the text-selection toolbar was showing
/// "Copy / Select all" because the app shipped no localizations delegates.
// SPDX-License-Identifier: GPL-3.0-or-later

library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tugi/main.dart';

void main() {
  testWidgets('the app is localized to Chinese, not English defaults',
      (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.supportedLocales.map((l) => l.languageCode), contains('zh'));
    expect(app.locale?.languageCode, 'zh');
    expect(app.localizationsDelegates,
        contains(GlobalMaterialLocalizations.delegate));

    // What the selection toolbar actually reads.
    final context = tester.element(find.byType(Scaffold).first);
    final strings = MaterialLocalizations.of(context);
    expect(strings.copyButtonLabel, '复制');
    expect(strings.selectAllButtonLabel, '全选');
  });
}
