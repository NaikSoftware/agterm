import 'package:elis_mobile/notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a notice shows at the top, runs its action, and leaves on its own', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(children: [
            TextButton(onPressed: () => showNotice(context, 'Agent blocked', action: 'Open', onAction: () => opened++), child: const Text('alert')),
            TextButton(onPressed: () => showNotice(context, 'No recently closed sessions'), child: const Text('error')),
            const Spacer(),
            const TextField(key: Key('composer')),
          ]),
        ),
      ),
    ));

    await tester.tap(find.text('alert'));
    await tester.pumpAndSettle();
    expect(find.text('Agent blocked'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Agent blocked')).dy, lessThan(100));
    // the composer at the bottom stays reachable while the notice is up
    await tester.tap(find.byKey(const Key('composer')));
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    expect(find.text('hi'), findsOneWidget);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Agent blocked'), findsNothing);

    // an action notice leaves on its own too, unlike an action SnackBar
    await tester.tap(find.text('alert'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Agent blocked'), findsNothing);

    // a new notice replaces the one already up
    await tester.tap(find.text('alert'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('error'));
    await tester.pumpAndSettle();
    expect(find.text('Agent blocked'), findsNothing);
    expect(find.text('No recently closed sessions'), findsOneWidget);
    hideNotice();
  });
}
