// On a device against a live relay:
//   flutter test integration_test/app_test.dart --dart-define=PAIR_LINK='agterm://pair?h=10.0.2.2&...'
// The computer must have a session named "phone-target" running a shell.
import 'package:agterm_mobile/main.dart' as app;
import 'package:agterm_mobile/model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// the screens poll on timers, so pumpAndSettle never settles: pump until the finder matches
Future<void> pumpUntil(WidgetTester t, Finder f, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('timed out waiting for $f');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const link = String.fromEnvironment('PAIR_LINK');

  testWidgets('pair, open a session, type into it, start a new one', (t) async {
    expect(link, isNotEmpty, reason: 'pass --dart-define=PAIR_LINK=...');
    await PairingStore.save([]);
    app.main();
    await pumpUntil(t, find.byKey(const Key('pairLink')));

    await t.enterText(find.byKey(const Key('pairLink')), 'not a link');
    await t.ensureVisible(find.byKey(const Key('connect')));
    await t.tap(find.byKey(const Key('connect')));
    await pumpUntil(t, find.byKey(const Key('pairError')));

    await t.enterText(find.byKey(const Key('pairLink')), link);
    await t.ensureVisible(find.byKey(const Key('connect')));
    await t.tap(find.byKey(const Key('connect')));
    await pumpUntil(t, find.text('WORKSPACES'));
    await pumpUntil(t, find.text('phone-target'));

    await t.tap(find.text('phone-target').last); // the row; a Needs-you card may show it too
    await pumpUntil(t, find.byKey(const Key('composer')));
    await t.enterText(find.byKey(const Key('composer')), 'echo from-the-phone');
    await t.tap(find.byKey(const Key('send')));
    await pumpUntil(t, find.textContaining(RegExp(r'\nfrom-the-phone')));

    await t.tap(find.byKey(const Key('key-Control C')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pageBack();
    await pumpUntil(t, find.byKey(const Key('newSession')));

    await t.tap(find.byKey(const Key('newSession')));
    await pumpUntil(t, find.byKey(const Key('newName')));
    await t.enterText(find.byKey(const Key('newName')), 'made-on-phone');
    await t.ensureVisible(find.byKey(const Key('createSession')));
    await t.tap(find.byKey(const Key('createSession')));
    await pumpUntil(t, find.byKey(const Key('composer')));
    await t.pageBack();
    await pumpUntil(t, find.text('made-on-phone'));
  });
}
