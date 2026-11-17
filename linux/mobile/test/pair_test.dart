import 'package:agterm_mobile/screens/pair.dart';
import 'package:agterm_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the app buttons open their download pages, and copy the link when nothing can open it', (tester) async {
    final opened = <Object?>[];
    var canOpen = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('agterm/open'), (call) async {
      opened.add(call.arguments);
      return canOpen;
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PairScreen(onPaired: (_) async {})));

    await tester.tap(find.byKey(const Key('app-macOS app')));
    await tester.tap(find.byKey(const Key('app-Linux app')));
    await tester.pump();
    expect(opened, [macAppUrl, linuxAppUrl]);
    expect(find.text('Link copied'), findsNothing);

    canOpen = false;
    await tester.tap(find.byKey(const Key('app-macOS app')));
    await tester.pump();
    expect(find.text('Link copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
