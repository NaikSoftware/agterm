import 'dart:async';
import 'dart:convert';

import 'package:elis_mobile/chat/chat_view.dart';
import 'package:elis_mobile/chat/mode.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/screens/session.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show frame, json;
import 'session_term_test.dart' show FakeVt, Harness, treeOf;

const _claude = {'agent': 'claude', 'agentSessionId': 'c1'};

List<Map> _watches(Harness h) => [
  for (final o in h.r.opens)
    if (o['claim'] != true) o,
];
List<Map> _claims(Harness h) => [
  for (final o in h.r.opens)
    if (o['claim'] == true) o,
];
bool _chat() => find.byType(ChatView).evaluate().isNotEmpty;
ChatView _view(WidgetTester t) => t.widget<ChatView>(find.byType(ChatView));

GateStep _up() => GateStep(KeyWrite(VtKey.arrowUp), ready: (_) => true, done: (_) => true);

/// The watch channel's grid changes: the gate checks `done`.
Future<void> _redraw(Harness h) async {
  h.r.send(frame(LinkKind.data, 2, utf8.encode('x')));
  await h.t.pump();
  await h.t.pump();
}

Future<void> _tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await t.pumpAndSettle(const Duration(milliseconds: 10));
}

void main() {
  setUp(() => ComposerPref.shown = true);
  tearDown(() {
    ComposerPref.shown = false;
    ModePicks.pick('s1', null);
    ModePicks.tooOld.clear();
  });

  testWidgets('autoShowsChatForClaude', (t) async {
    final h = Harness(t, treeOf(session: _claude));
    await h.start();
    await t.pump(const Duration(milliseconds: 100));
    expect(_chat(), isTrue);
    expect(h.r.transcriptArgs.first['pane'], 'left');
    await h.stop();
  });

  for (final shown in [true, false]) {
    testWidgets('termAndChatSwitch${shown ? '' : 'WithoutComposer'}', (t) async {
      ComposerPref.shown = shown;
      final h = Harness(t, treeOf(session: _claude));
      await h.start();
      await h.opened();
      expect(_claims(h), isEmpty);
      await _tapKey(t, 'modeTerm');
      expect(_chat(), isFalse);
      expect(find.byKey(const Key('term')), findsOneWidget);
      expect(_claims(h), hasLength(1)); // Term's claim on OPENED, on the next frame
      await _tapKey(t, 'modeChat');
      expect(_chat(), isTrue);
      await h.stop();
    });
  }

  testWidgets('autoItemClearsTheManualPick', (t) async {
    final h = Harness(t, treeOf(session: _claude));
    await h.start();
    await _tapKey(t, 'modeTerm');
    expect(_chat(), isFalse);
    await _tapKey(t, 'sessionMenu');
    await _tapKey(t, 'autoMode');
    expect(_chat(), isTrue);
    expect(ModePicks.of('s1'), isNull);
    await h.stop();
  });

  testWidgets('chatDisabledWithoutAgent', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    expect(t.widget<OutlinedButton>(find.byKey(const Key('modeChat'))).onPressed, isNull);
    expect(_chat(), isFalse);
    expect(h.r.transcriptArgs, isEmpty);
    await h.stop();
  });

  for (final viaTerm in [false, true]) {
    testWidgets('chatNeverResizes${viaTerm ? 'AfterTerm' : ''}', (t) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final h = Harness(t, treeOf(session: _claude));
      await h.start();
      if (viaTerm) {
        await _tapKey(t, 'modeTerm'); // Term lays out the phone grid
        await _tapKey(t, 'modeChat');
      }
      await h.opened();
      t.view.viewInsets = const FakeViewPadding(bottom: 900); // the soft keyboard
      await t.pump(const Duration(milliseconds: 400));
      t.view.physicalSize = const Size(2340, 1080); // a rotation
      await t.pump(const Duration(milliseconds: 400));
      expect(h.r.grids, isEmpty);
      expect(_claims(h), isEmpty);
      final result = _view(t).gate.run(1, (s) => s.send(_up()));
      await t.pump();
      await t.pump();
      expect(_claims(h), [
        {'type': 'vt', 'target': 's1', 'pane': 'left', 'claim': true, 'cols': 80, 'rows': 24},
      ]);
      h.r.send([
        ...json(LinkKind.opened, 3, {'cols': 80, 'rows': 24}),
        ...json(LinkKind.lead, 3, {'role': 'leader'}),
      ]);
      await t.pump();
      await t.pump();
      await _redraw(h);
      expect((await result).outcome, GateOutcome.done);
      t.view.physicalSize = const Size(1080, 2340);
      await t.pump(const Duration(milliseconds: 400));
      expect(h.r.of(LinkKind.resize), isEmpty);
      expect(h.r.grids, isEmpty);
      expect(_claims(h), hasLength(1));
      await h.stop();
    });
  }

  testWidgets('statusEventPollsAtOnce', (t) async {
    final h = Harness(t, treeOf(session: _claude));
    await h.start();
    await t.pump(const Duration(milliseconds: 300));
    h.r.events.add({
      'kind': 'status',
      'session': 's1',
      'payload': {'status': 'running'},
    });
    var last = 0, step = 0, delivered = -1, polled = -1;
    var count = h.r.transcriptArgs.length;
    while (polled < 0 && step < 300) {
      await t.pump(const Duration(milliseconds: 10));
      step++;
      if (delivered < 0 && h.r.eventsServed > 0) delivered = step;
      if (h.r.transcriptArgs.length > count) {
        count = h.r.transcriptArgs.length;
        if (delivered >= 0) {
          polled = step;
        } else {
          last = step;
        }
      }
    }
    expect(delivered, greaterThanOrEqualTo(0));
    expect(polled - delivered, lessThanOrEqualTo(2)); // at once
    expect(polled - last, lessThan(70)); // not the 700 ms tick
    await h.stop();
  });

  testWidgets('nonLivePanePollsText', (t) async {
    final h = Harness(t, treeOf(live: false, session: _claude));
    await h.start();
    await t.pump(const Duration(seconds: 2));
    expect(_chat(), isTrue);
    expect(h.r.textArgs, isNotEmpty);
    expect(h.r.textArgs.last['lines'], isNull); // the screen, not the history
    expect(h.r.grids, isEmpty);
    await h.stop();
  });

  testWidgets('exitKeepsChatShown', (t) async {
    final h = Harness(t, treeOf(session: _claude));
    await h.start();
    expect(_view(t).exited, isFalse);
    await h.retree(treeOf(session: {'agentSessionId': 'c1'}));
    await t.pump();
    expect(_chat(), isTrue);
    expect(_view(t).exited, isTrue);
    // Chat sits below the toolbar: the exited row's Term button is not under the segments
    final bar = t.getRect(find.byKey(const Key('toolbar')));
    expect(t.getRect(find.byKey(const Key('chatExited'))).top, greaterThanOrEqualTo(bar.bottom));
    await h.stop();
  });

  testWidgets('refusedClaimWritesThroughSessionType', (t) async {
    final h = Harness(t, treeOf(session: _claude));
    await h.start();
    await h.opened();
    final first = _view(t).gate.run(1, (s) => s.send(_up()));
    await t.pump();
    await t.pump();
    expect(_claims(h), hasLength(1));
    h.r.send(json(LinkKind.opened, 3, {'error': 'session not realized'}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.typed, ['\x1b[A']); // the refusal turns this write to session.type, not after the lead's 10 s
    await _redraw(h);
    expect((await first).outcome, GateOutcome.done);
    h.r.typed.clear();
    final second = _view(t).gate.run(1, (s) => s.send(_up()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.typed, ['\x1b[A']);
    await _redraw(h);
    expect((await second).outcome, GateOutcome.done);
    expect(_claims(h), hasLength(1));
    expect(h.r.grids, isEmpty); // no refit after the refusal
    await h.stop();
  });

  testWidgets('opensOnTheAgentPane', (t) async {
    final h = Harness(t, treeOf(split: true, session: {..._claude, 'agentPane': 'right'}));
    await h.start();
    await t.pump(const Duration(milliseconds: 100));
    expect(_chat(), isTrue);
    expect(h.r.transcriptArgs.first['pane'], 'right');
    expect(_watches(h).first['pane'], 'right');
    await h.stop();
  });

  testWidgets('tooOldHostShowsTerm', (t) async {
    final h = Harness(t, treeOf(session: _claude));
    h.r.errors['session.transcript'] = 'unknown command: session.transcript';
    await h.start();
    await t.pump(const Duration(milliseconds: 100));
    expect(_chat(), isFalse);
    expect(t.widget<OutlinedButton>(find.byKey(const Key('modeChat'))).onPressed, isNull);
    final calls = h.r.transcriptArgs.length;
    h.nav.currentState!.pop();
    await t.pumpAndSettle(const Duration(milliseconds: 10));
    unawaited(
      h.nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(model: h.m, sessionId: 's1', vt: (c, r) => FakeVt(c, r)),
        ),
      ),
    );
    await t.pumpAndSettle(const Duration(milliseconds: 10));
    await t.pump(const Duration(seconds: 2));
    expect(_chat(), isFalse);
    expect(h.r.transcriptArgs.length, calls);
    await h.stop();
  });
}
