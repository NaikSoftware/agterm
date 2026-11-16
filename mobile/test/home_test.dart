import 'package:agterm_mobile/client.dart';
import 'package:agterm_mobile/main.dart';
import 'package:agterm_mobile/model.dart';
import 'package:agterm_mobile/screens/home.dart';
import 'package:agterm_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgtermModel model() {
  final m = AgtermModel(Pairing(name: 'MacBook', host: '10.0.0.2', port: 1, token: 't', fingerprint: 'f'))
    ..state = LinkState.connected
    ..loaded = true
    ..workspaces = [
      Workspace({
        'id': 'w1', 'name': 'agterm', 'tint': 'purple', 'active': true,
        'sessions': [
          {'id': 's1', 'name': 'phone-bluetooth', 'agent': 'claude', 'status': 'active', 'active': true, 'flagged': true, 'context': 'Running tests'},
          {'id': 'c1', 'name': 'gradle watch', 'parent': 's1', 'status': 'idle'},
          {'id': 's2', 'name': 'review', 'agent': 'claude', 'status': 'blocked', 'unseen': 2},
          {'id': 's3', 'name': 'android app', 'agent': 'codex', 'status': 'active', 'collapsed': true, 'cwd': '/Users/me/app'},
          {'id': 'c2', 'name': 'emulator', 'parent': 's3', 'status': 'blocked'},
          {'id': 's4', 'name': 'prod api', 'tint': 'red', 'cwd': '/Users/me', 'status': 'completed'},
        ],
      }),
      Workspace({'id': 'w2', 'name': 'sys', 'sessions': [{'id': 's5', 'name': 'top', 'status': 'completed'}]}),
    ];
  return m;
}

Future<void> pumpHome(WidgetTester t, AgtermModel m) async {
  t.view.physicalSize = const Size(390 * 3, 1400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(), home: HomeScreen(model: m, computers: Computers())));
  await t.pump();
}

void main() {
  testWidgets('a folded parent hides its companions and marks a blocked one', (t) async {
    final m = model();
    await pumpHome(t, m);
    expect(find.byKey(const Key('row-c1')), findsOneWidget);
    expect(find.byKey(const Key('row-c2')), findsNothing);
    expect(find.byKey(const Key('hiddenBlocked-s3')), findsOneWidget);
    expect(find.byKey(const Key('hiddenBlocked-s1')), findsNothing);
    expect(find.byKey(const Key('wsMenu-w1')), findsOneWidget);
    await t.tap(find.byKey(const Key('ws-w1')));
    await t.pump();
    expect(find.byKey(const Key('row-s1')), findsNothing);
    await t.pumpWidget(const SizedBox()); // stops the snippet timer
  });

}
