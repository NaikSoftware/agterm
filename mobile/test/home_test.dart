import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/main.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/screens/home.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ElisModel model() {
  final m = ElisModel(Pairing(name: 'MacBook', host: '10.0.0.2', port: 1, token: 't', fingerprint: 'f'))
    ..state = LinkState.connected
    ..loaded = true
    ..workspaces = [
      Workspace({
        'id': 'w1', 'name': 'elis', 'tint': 'purple', 'active': true,
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

Future<void> pumpHome(WidgetTester t, ElisModel m) async {
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
    expect(find.descendant(of: find.byKey(const Key('row-c1')), matching: find.byType(StatusShape)), findsNothing); // idle shows no mark
    expect(find.descendant(of: find.byKey(const Key('row-s1')), matching: find.byType(StatusShape)), findsOneWidget);
    await t.tap(find.byKey(const Key('ws-w1')));
    await t.pump();
    expect(find.byKey(const Key('row-s1')), findsNothing);
    await t.pumpWidget(const SizedBox()); // stops the snippet timer
  });

  testWidgets('a closed session leaves its row in place, then the row is gone', (t) async {
    final m = model();
    await pumpHome(t, m);
    m.workspaces = [m.workspaces[0], Workspace({'id': 'w2', 'name': 'sys', 'sessions': []})];
    m.notifyListeners(); // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    await t.pump();
    expect(find.byKey(const Key('row-s5')), findsOneWidget);
    expect(find.byKey(const Key('wsTile-w2')), findsNothing);
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    expect(find.byKey(const Key('row-s5')), findsNothing);
    expect(find.byKey(const Key('wsTile-w2')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the workspace ⋮ opens its actions with a new session there', (t) async {
    await pumpHome(t, model());
    await t.tap(find.byKey(const Key('wsMenu-w2')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('New session here'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a tint colors both the icon and the name', (t) async {
    await pumpHome(t, model());
    T inRow<T extends Widget>(String key, Finder f) => t.widget<T>(find.descendant(of: find.byKey(Key(key)), matching: f).first);
    expect(inRow<Text>('row-s4', find.text('prod api')).style?.color, tintColor('red'));
    expect(inRow<AgentLogo>('row-s4', find.byType(AgentLogo)).color, tintColor('red'));
    expect(inRow<Text>('ws-w1', find.text('elis')).style?.color, tintColor('purple'));
    expect(inRow<Lucide>('ws-w1', find.byType(Lucide)).color, tintColor('purple'));
    await t.pumpWidget(const SizedBox());
  });
}
