import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/card_checks.dart';
import 'package:elis_mobile/chat/card_steps.dart';
import 'package:elis_mobile/chat/chat_view.dart';
import 'package:elis_mobile/chat/checks.dart';
import 'package:elis_mobile/chat/claude_screen.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/prompt_cards.dart';
import 'package:elis_mobile/chat/prompt_dialog.dart';
import 'package:elis_mobile/chat/prompt_match.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';
import 'support/fake_claude.dart';

const _dir = 'test/fixtures/grid';
const _harbour = 'Harbour light on the long southern breakwater';
const _stopped = "Stopped at step 1 of 3: Claude's screen did not change. The prompt may be half answered.";

Grid _g(String name) => gridFromAnsi(File('$_dir/$name-45.ansi').readAsStringSync());

Map<String, dynamic> _json(String name) =>
    (jsonDecode(File('$_dir/$name.pending.json').readAsStringSync()) as List).first as Map<String, dynamic>;

PendingCall _call(String name) => PendingCall.fromJson(_json(name));

class _Host {
  _Host(String fixture, {List<(Matcher, Grid)> script = const [], this.remote = false})
    : call = ValueNotifier(_call(fixture)),
      s = ScriptedGrids(script, _g(fixture)) {
    gate = WriteGate(grids: s, grid: () => s.grid, writer: () => s, remote: () => remote, blocked: () => null);
  }

  final ScriptedGrids s;
  final ValueNotifier<PendingCall> call;
  final bool remote;
  late final WriteGate gate;
  final events = <String>[];

  Widget app({Checks checks = checks, CardChecks cards = cardChecks}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ListenableBuilder(
          listenable: Listenable.merge([s, call]),
          builder: (context, _) {
            final g = s.grid, m = matchPrompt(PromptDialog.read(g), [call.value]);
            if (m == null) return const SizedBox();
            final c = ChatPromptContext(
              screen: ClaudeScreen.read(g),
              grid: g,
              pending: [call.value],
              gate: gate,
              remote: remote,
              openPanel: (why) => events.add('panel:$why'),
            );
            void done() => events.add('done');
            void stop() => events.add('stop');
            return switch (m.kind) {
              PromptKind.ask => AskCard(c: c, m: m, onDone: done, onStop: stop, checks: checks, cards: cards),
              PromptKind.permission => PermissionCard(c: c, m: m, onDone: done, onStop: stop, checks: checks, cards: cards),
              PromptKind.plan => PlanCard(c: c, m: m, onDone: done, onStop: stop, checks: checks, cards: cards),
            };
          },
        ),
      ),
    ),
  );

  Future<void> show(WidgetTester t, {Checks checks = checks, CardChecks cards = cardChecks}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(checks: checks, cards: cards));
  }
}

Future<void> _tap(WidgetTester t, String label) async {
  final f = find.text(label).last;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
}

// lets each gate step see its grid change
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 10));
  }
}

CardButton _button(WidgetTester t, String label) =>
    t.widget<CardButton>(find.ancestor(of: find.text(label).last, matching: find.byType(CardButton)));

List<String> _labels(WidgetTester t, {required bool secondTap}) => [
  for (final b in t.widgetList<CardButton>(find.byType(CardButton)))
    if (b.secondTap == secondTap) b.label,
];

List<String> _rows(String fixture) => [
  for (final o in PromptDialog.read(_g(fixture))!.options)
    if (o.number != null) o.label,
];

bool _enabled(WidgetTester t, String label) => t
    .widget<ButtonStyleButton>(find.ancestor(of: find.text(label).last, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
    .enabled;

void main() {
  testWidgets('singleQuestionTapSends', (t) async {
    final h = _Host('card-ask-single', script: [(equals('2'), _g('idle-placeholder'))]);
    await h.show(t);
    await _tap(t, _harbour);
    await _settle(t);
    expect(h.s.sentWrites, ['2']);
    expect(h.events, ['done']);
  });

  testWidgets('multiQuestionCollectsThenReviews', (t) async {
    final h = _Host(
      'card-ask-two',
      script: [(equals('1'), _g('card-ask-two-second')), (equals('1'), _g('card-ask-review')), (equals('1'), _g('idle-placeholder'))],
    );
    await h.show(t);
    expect(find.text('1/2'), findsOneWidget);
    await _tap(t, 'Staging');
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('Which shift should the keeper take?'), findsOneWidget);
    await _tap(t, 'Night');
    expect(find.text('→ Staging'), findsOneWidget);
    expect(find.text('→ Night'), findsOneWidget);
    expect(h.s.sentWrites, isEmpty);
    var runs = 0;
    h.gate.addListener(() => runs += h.gate.running && h.gate.step == 0 ? 1 : 0);
    await _tap(t, 'Send');
    await _settle(t);
    expect(h.s.sentWrites, ['1', '1', '1']);
    expect(runs, 1);
    expect(h.events, ['done']);
  });

  testWidgets('otherFieldCollectsText', (t) async {
    final h = _Host(
      'card-ask-single',
      script: [
        (equals('4'), _g('card-ask-other-open')),
        (equals('paste:two\nlines'), _g('card-ask-other-filled')),
        (equals('enter'), _g('idle-placeholder')),
      ],
    );
    await h.show(t);
    expect(find.byKey(const Key('askOther')), findsNothing);
    await h.show(t, cards: const CardChecks(singleOther: true));
    expect(_enabled(t, 'Send'), isFalse);
    await t.enterText(find.byKey(const Key('askOther')), 'two\nlines');
    await t.pump();
    await _tap(t, 'Send');
    await _settle(t);
    expect(h.s.sentWrites, ['4', 'paste:two\nlines', 'enter']);
    expect(h.events, ['done']);
  });

  testWidgets('previewIsMono', (t) async {
    await _Host('card-ask-preview').show(t);
    final preview = find.text('lamp\n  ring\n    lens');
    expect(t.widget<Text>(preview).style?.fontFamily, mono);
    expect(
      find.ancestor(
        of: preview,
        matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
      ),
      findsOneWidget,
    );
  });

  // one tick, Tab, Submit
  testWidgets('progressLocksButtons', (t) async {
    final h = _Host('card-ask-multi');
    final steps = cardSteps(
      matchPrompt(PromptDialog.read(h.s.grid), [h.call.value])!,
      AskAnswer([
        const QuestionAnswer(labels: ['Oil']),
      ]),
    );
    expect(steps, hasLength(3));
    await h.show(t);
    await _tap(t, 'Oil');
    await _tap(t, 'Send');
    await _settle(t);
    expect(h.s.sentWrites, ['1']);
    expect(find.text('Sending 1/3'), findsOneWidget);
    expect(_enabled(t, 'Bread'), isFalse);
    expect(_enabled(t, 'Cancel'), isFalse);
    await t.tap(find.text('Sending 1/3'));
    await t.tap(find.text('Bread'));
    await t.pump();
    expect(h.s.sentWrites, ['1']);
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('remoteRowDisabledUntilProven', (t) async {
    final h = _Host('card-ask-single', remote: true);
    await h.show(t);
    expect(find.text('Answering is off on remote rows until checked'), findsOneWidget);
    expect(_enabled(t, _harbour), isFalse);
    expect(find.text('Answer in panel'), findsOneWidget);
    await h.show(t, checks: const Checks(keys: true, paste: true, remote: true));
    expect(find.text('Answering is off on remote rows until checked'), findsNothing);
    expect(_enabled(t, _harbour), isTrue);
  });

  testWidgets('stopOpensPanelWithMessage', (t) async {
    final h = _Host('card-ask-multi');
    await h.show(t);
    await _tap(t, 'Oil');
    await _tap(t, 'Send');
    await t.pump(const Duration(seconds: 3));
    expect(h.s.sentWrites, ['1']);
    expect(h.events, ['stop', 'panel:$_stopped']);
  });

  testWidgets('blockedShowsReasonAndPanelButton', (t) async {
    final h = _Host('card-ask-single');
    await h.show(t, checks: const Checks());
    expect(find.text('Sending from the phone is not verified yet'), findsOneWidget);
    expect(_enabled(t, _harbour), isFalse);
    expect(_enabled(t, 'Cancel'), isFalse);
    await _tap(t, 'Answer in panel');
    expect(h.events, ['panel:null']);
    expect(h.s.sentWrites, isEmpty);
  });

  testWidgets('notesHiddenUntilProven', (t) async {
    final h = _Host('card-ask-preview');
    await h.show(t);
    expect(find.text('Notes'), findsNothing);
    await h.show(t, cards: const CardChecks(previewNotes: true));
    expect(find.text('Notes'), findsOneWidget);
  });

  testWidgets('answersSurviveRebuild', (t) async {
    final h = _Host('card-ask-two');
    await h.show(t);
    await _tap(t, 'Staging');
    h.s
      ..grid = _g('card-ask-two-second')
      ..notifyListeners();
    await t.pump();
    expect(find.text('2/2'), findsOneWidget);
    await _tap(t, 'Night');
    expect(find.text('→ Staging'), findsOneWidget);

    h.call.value = PendingCall.fromJson({..._json('card-ask-two'), 'id': 'toolu_another'});
    await t.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('→ Staging'), findsNothing);
  });

  testWidgets('secondTapConfirms', (t) async {
    var taps = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [CardButton(label: 'Yes, and always allow', secondTap: true, onPressed: () => taps++)],
          ),
        ),
      ),
    );
    await t.tap(find.text('Yes, and always allow'));
    await t.pump();
    expect(find.text('Tap again to confirm'), findsOneWidget);
    expect(taps, 0);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('Yes, and always allow'), findsOneWidget);
    await t.tap(find.text('Yes, and always allow'));
    await t.pump();
    await t.tap(find.text('Tap again to confirm'));
    await t.pump();
    expect(taps, 1);
  });

  testWidgets('bashCardYesNo', (t) async {
    final h = _Host('card-bash', script: [(equals('1'), _g('idle-placeholder'))]);
    await h.show(t);
    expect(find.text(r'$ touch /tmp/elis-fixture-lantern-keeper-notebook-entry.txt'), findsOneWidget);
    expect(find.text('Create empty fixture file in /tmp'), findsOneWidget);
    expect((_button(t, 'Yes').primary, _button(t, 'Yes').secondTap), (true, false));
    expect((_button(t, 'No').primary, _button(t, 'No').secondTap), (false, false));
    await _tap(t, 'Yes');
    await _settle(t);
    expect(h.s.sentWrites, ['1']);
    expect(h.events, ['done']);
  });

  testWidgets('persistRowsAbsentUntilProven', (t) async {
    final h = _Host('card-bash');
    final rows = _rows('card-bash');
    await h.show(t);
    expect(_labels(t, secondTap: false), ['Yes', 'More options in panel', 'No', 'Yes with a note', 'No with a reason']);
    expect(_labels(t, secondTap: true), isEmpty);
    await _tap(t, 'More options in panel');
    expect(h.events, ['panel:null']);

    await h.show(t, cards: const CardChecks(persistOptions: true));
    expect(_labels(t, secondTap: true), [rows[1], rows[2]]);
    expect(find.text('More options in panel'), findsNothing);
    expect(find.ancestor(of: find.text(rows[1]), matching: find.byType(OutlinedButton)), findsOneWidget);
    await _tap(t, rows[1]);
    expect(find.text('Tap again to confirm'), findsOneWidget);
    expect(h.s.sentWrites, isEmpty);
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('noteOnBashOnly', (t) async {
    final write = _Host('card-write');
    await write.show(t);
    expect(find.text('Yes with a note'), findsNothing);
    expect(find.text('No with a reason'), findsNothing);
    await write.show(t, cards: const CardChecks(fileAndMcpNotes: true));
    expect(find.text('Yes with a note'), findsOneWidget);
    expect(find.text('No with a reason'), findsOneWidget);

    final amend = _g('card-bash-amend');
    Future<_Host> note(List<(Matcher, Grid)> script) async {
      final h = _Host('card-bash', script: [(equals('tab'), amend), ...script]);
      await h.show(t);
      expect(find.byKey(const Key('cardField')), findsNothing);
      await _tap(t, 'Yes with a note');
      expect(_enabled(t, 'Send'), isFalse);
      await t.enterText(find.byKey(const Key('cardField')), 'mind the stairs');
      await t.pump();
      await _tap(t, 'Send');
      await _settle(t);
      return h;
    }

    final h = await note([
      (equals('paste:mind the stairs'), retext(amend, 'Yes, and tell Claude what to do next', 'Yes, mind the stairs')),
      (equals('enter'), _g('idle-placeholder')),
    ]);
    expect(h.s.sentWrites, ['tab', 'paste:mind the stairs', 'enter']);
    expect(h.events, ['done']);

    final stalled = await note([]);
    expect(stalled.s.sentWrites, ['tab', 'paste:mind the stairs']);
    expect(find.text('Sending 2/3'), findsOneWidget, reason: 'the amend grid relabels Yes, but the rows stay as read');
    expect(find.byKey(const Key('cardField')), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    expect(stalled.events.first, 'stop');
  });

  testWidgets('webFetchPanelOnly', (t) async {
    final h = _Host('card-webfetch');
    await h.show(t);
    expect(find.text('from a subagent'), findsOneWidget);
    expect(find.text('https://example.org/'), findsOneWidget);
    expect(_labels(t, secondTap: false), ['Answer in panel']);
    await _tap(t, 'Answer in panel');
    expect(h.events, ['panel:null']);
    await h.show(t, cards: const CardChecks(webFetch: true));
    expect(_labels(t, secondTap: false), ['Yes', 'More options in panel']);
  });

  testWidgets('planCardMarkdownAndChange', (t) async {
    final change = _g('card-plan-change');
    final h = _Host(
      'card-plan',
      script: [
        (equals('3'), change),
        (equals('paste:two lanterns'), retext(change, 'Tell Claude what to change', 'two lanterns')),
        (equals('enter'), _g('idle-placeholder')),
      ],
    );
    await h.show(t);
    expect(find.text('Lantern log', findRichText: true), findsOneWidget);
    expect(_button(t, 'Yes, manually approve edits').primary, isTrue);
    await _tap(t, 'Change');
    await t.enterText(find.byKey(const Key('cardField')), 'two lanterns');
    await t.pump();
    await _tap(t, 'Send');
    await _settle(t);
    expect(h.s.sentWrites, ['3', 'paste:two lanterns', 'enter']);
    expect(h.events, ['done']);
  });

  testWidgets('planAutoAbsentUntilProven', (t) async {
    final h = _Host('card-plan');
    await h.show(t);
    expect(find.text('Yes, and use auto mode'), findsNothing);
    expect(_labels(t, secondTap: false), ['More options in panel', 'Yes, manually approve edits', 'Change']);
    await h.show(t, cards: const CardChecks(persistOptions: true));
    expect(_labels(t, secondTap: true), ['Yes, and use auto mode']);
    expect(find.text('More options in panel'), findsNothing);
  });
}
