import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/card_steps.dart';
import 'package:elis_mobile/chat/checks.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/prompt_dialog.dart';
import 'package:elis_mobile/chat/prompt_match.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';
import 'support/fake_claude.dart';

const _dir = 'test/fixtures/grid';
const _supplies = 'Which supplies should the keeper carry?';

Grid _g(String name) => gridFromAnsi(File('$_dir/$name.ansi').readAsStringSync());

Map<String, dynamic> _json(String name) =>
    (jsonDecode(File('$_dir/$name.pending.json').readAsStringSync()) as List).first as Map<String, dynamic>;

PendingCall _call(String name) => PendingCall.fromJson(_json(name));

PromptMatch _match(Grid g, PendingCall c) => matchPrompt(PromptDialog.read(g), [c])!;

AskAnswer _ask(List<QuestionAnswer> qs) => AskAnswer(qs);

/// A Review screen; no capture has a multiSelect question's Review, and its rows need no colours.
Grid _review(String tabs, List<(String, String)> lines) => Grid.text(
  [
    '─' * 45,
    tabs,
    '',
    'Review your answers',
    '',
    for (final (q, a) in lines) ...[' ● $q', '   → $a'],
    '',
    '❯ 1. Submit answers',
    '  2. Cancel',
    '─' * 45,
  ].join('\n'),
);

GateResult? _send(ScriptedGrids s, List<GateStep> steps) => fakeAsync((a) {
  final gate = WriteGate(
    grids: s,
    grid: () => s.grid,
    writer: () => s,
    remote: () => false,
    blocked: () => null,
    checks: const Checks(keys: true, paste: true),
  );
  GateResult? r;
  gate
      .run(steps.length, (q) async {
        for (final st in steps) {
          await q.send(st);
        }
      })
      .then((v) => r = v);
  a.elapse(const Duration(seconds: 30));
  return r;
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final w in [45, 100]) {
    final idle = _g('idle-placeholder-$w');

    test('singleChoiceIsOneDigit $w', () {
      final start = _g('card-ask-single-$w');
      final steps = cardSteps(
        _match(start, _call('card-ask-single')),
        _ask([
          const QuestionAnswer(labels: ['Harbour light on the long southern breakwater']),
        ]),
      );
      final s = ScriptedGrids([(equals('2'), idle)], start);
      expect(_send(s, steps)?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['2']);
    });

    test('numericLabelsUseRowNumbers $w', () {
      final start = _g('card-ask-numbers-$w');
      final steps = cardSteps(
        _match(start, _call('card-ask-numbers')),
        _ask([
          const QuestionAnswer(labels: ['42']),
        ]),
      );
      final s = ScriptedGrids([(equals('2'), idle)], start);
      expect(_send(s, steps)?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['2']);
    });

    test('otherIsDigitPasteEnter $w', () {
      final start = _g('card-ask-single-$w');
      final steps = cardSteps(_match(start, _call('card-ask-single')), _ask([const QuestionAnswer(other: 'two\nlines')]));
      final s = ScriptedGrids([
        (equals('4'), _g('card-ask-other-open-$w')),
        (equals('paste:two\nlines'), _g('card-ask-other-filled-$w')),
        (equals('enter'), idle),
      ], start);
      expect(_send(s, steps)?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['4', 'paste:two\nlines', 'enter']);

      final unfilled = ScriptedGrids([(equals('4'), _g('card-ask-other-open-$w'))], start);
      expect(_send(unfilled, steps)?.outcome, GateOutcome.timeout);
      expect(unfilled.sentWrites, ['4', 'paste:two\nlines']);
    });

    final ticked = _g('card-ask-multi-ticked-$w');
    final bread = retext(ticked, '[ ] Bread', '[✔] Bread');
    List<GateStep> oilAndBread() => cardSteps(
      _match(ticked, _call('card-ask-multi-ticked')),
      _ask([
        const QuestionAnswer(labels: ['Oil', 'Bread']),
      ]),
    );

    test('multiSelectSendsOnlyDifferingRows $w', () {
      final s = ScriptedGrids([
        (equals('2'), bread),
        (equals('3'), retext(bread, '[✔] Rope', '[ ] Rope')),
        (equals('tab'), _review('←  ☒ Supplies  ✔ Submit  →', [(_supplies, 'Oil, Bread')])),
        (equals('1'), idle),
      ], ticked);
      expect(_send(s, oilAndBread())?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['2', '3', 'tab', '1']);
    });

    test('macAnswerMidSequenceStops $w', () {
      final s = ScriptedGrids([(equals('2'), bread)], ticked, between: {1: idle});
      final r = _send(s, oilAndBread());
      expect((r?.outcome, r?.step), (GateOutcome.mismatch, 2));
      expect(s.sentWrites, ['2']);
    });

    test('twoQuestionsUseRight $w', () {
      final two = _g('card-ask-two-$w'), second = _g('card-ask-two-second-$w');
      final singles = cardSteps(
        _match(two, _call('card-ask-two')),
        _ask([
          const QuestionAnswer(labels: ['Staging']),
          const QuestionAnswer(labels: ['Night']),
        ]),
      );
      final s = ScriptedGrids([(equals('1'), second), (equals('1'), _g('card-ask-review-$w')), (equals('1'), idle)], two);
      expect(_send(s, singles)?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['1', '1', '1'], reason: 'a single-choice digit advances by itself');

      final m = _json('card-ask-multi-ticked');
      final input = m['input'] as Map<String, dynamic>;
      input['questions'] = [...input['questions'] as List, ...(_json('card-ask-two')['input']['questions'] as List).skip(1)];
      final shift = (input['questions'] as List)[1]['question'] as String;
      final steps = cardSteps(
        _match(ticked, PendingCall.fromJson(m)),
        _ask([
          const QuestionAnswer(labels: ['Oil', 'Rope']),
          const QuestionAnswer(labels: ['Night']),
        ]),
      );
      final right = ScriptedGrids([
        (equals('arrowRight'), second),
        (equals('1'), _review('←  ☒ Supplies  ☒ Watch schedule  ✔ Submit  →', [(_supplies, 'Oil, Rope'), (shift, 'Night')])),
        (equals('1'), idle),
      ], ticked);
      expect(_send(right, steps)?.outcome, GateOutcome.done);
      expect(right.sentWrites, ['arrowRight', '1', '1']);
    });

    test('reviewMismatchStops $w', () {
      final two = _g('card-ask-two-$w');
      final steps = cardSteps(
        _match(two, _call('card-ask-two')),
        _ask([
          const QuestionAnswer(labels: ['Production']),
          const QuestionAnswer(labels: ['Night']),
        ]),
      );
      final s = ScriptedGrids([(equals('2'), _g('card-ask-two-second-$w')), (equals('1'), _g('card-ask-review-$w'))], two);
      final r = _send(s, steps);
      expect((r?.outcome, r?.step), (GateOutcome.mismatch, 3));
      expect(s.sentWrites, ['2', '1']);
    });

    test('tabWaitsUntilCursorLeavesOther $w', () {
      final start = _g('card-ask-multi-other-$w');
      final steps = cardSteps(
        _match(start, _call('card-ask-multi-other')),
        _ask([
          const QuestionAnswer(labels: ['Oil', 'Rope'], other: 'a spare lens'),
        ]),
      );
      expect([for (final st in steps) sent(st.write)], ['arrowUp', 'tab', '1']);
      final s = ScriptedGrids(const [], start);
      expect(_send(s, steps)?.outcome, GateOutcome.timeout);
      expect(s.sentWrites, ['arrowUp']);

      final fresh = _g('card-ask-multi-$w');
      final all = cardSteps(
        _match(fresh, _call('card-ask-multi')),
        _ask([
          const QuestionAnswer(labels: ['Oil'], other: 'a spare lens'),
        ]),
      );
      expect(
        [for (final st in all) sent(st.write)],
        ['1', 'arrowDown', 'arrowDown', 'arrowDown', 'paste:a spare lens', 'arrowUp', 'tab', '1'],
      );
    });

    test('otherFilledOnTheComputerStops $w', () {
      final start = _g('card-ask-multi-other-$w');
      for (final other in [null, 'a brass lamp']) {
        final steps = cardSteps(
          _match(start, _call('card-ask-multi-other')),
          _ask([
            QuestionAnswer(labels: const ['Oil', 'Rope'], other: other),
          ]),
        );
        final s = ScriptedGrids(const [], start);
        final r = _send(s, steps);
        expect((r?.outcome, r?.step, r?.reason), (GateOutcome.mismatch, 1, 'Other is filled on the computer'));
        expect(s.sentWrites, isEmpty);
      }
    });

    test('digitRefusedWhileOtherFocused $w', () {
      final start = _g('card-ask-other-open-$w');
      final steps = cardSteps(
        _match(start, _call('card-ask-other-open')),
        _ask([
          const QuestionAnswer(labels: ['North Cape']),
        ]),
      );
      final s = ScriptedGrids([(equals('1'), idle)], start);
      expect(_send(s, steps)?.outcome, GateOutcome.mismatch);
      expect(s.sentWrites, isEmpty);
    });

    test('previewDigitThenEnter $w', () {
      final start = _g('card-ask-preview-$w');
      final m = _match(start, _call('card-ask-preview'));
      final stack = retext(retext(start, '❯ 1.', '  1.'), '  2. Stack', '❯ 2. Stack');
      final s = ScriptedGrids([(equals('2'), stack), (equals('enter'), idle)], start);
      expect(
        _send(
          s,
          cardSteps(
            m,
            _ask([
              const QuestionAnswer(labels: ['Stack']),
            ]),
          ),
        )?.outcome,
        GateOutcome.done,
      );
      expect(s.sentWrites, ['2', 'enter']);

      final ring = cardSteps(
        m,
        _ask([
          const QuestionAnswer(labels: ['Ring']),
        ]),
      );
      expect([for (final st in ring) sent(st.write)], ['enter'], reason: 'the cursor is already on Ring');
    });

    test('discussNeedsANumber $w', () {
      expect(cardSteps(_match(_g('card-ask-preview-$w'), _call('card-ask-preview')), AskDiscuss()), isEmpty);
      final start = _g('card-ask-single-$w');
      final s = ScriptedGrids([(equals('5'), idle)], start);
      expect(_send(s, cardSteps(_match(start, _call('card-ask-single')), AskDiscuss()))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['5']);
    });

    test('cancelUsesReviewRowOrLastEsc $w', () {
      final review = _g('card-ask-review-$w');
      final s = ScriptedGrids([(equals('2'), idle)], review);
      expect(_send(s, cardSteps(_match(review, _call('card-ask-review')), AskCancel()))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['2']);

      final single = _g('card-ask-single-$w');
      final esc = ScriptedGrids([(equals('escape'), idle)], single);
      final steps = cardSteps(_match(single, _call('card-ask-single')), AskCancel());
      expect([for (final st in steps) sent(st.write)], ['escape']);
      expect(_send(esc, steps)?.outcome, GateOutcome.done);
    });
  }

  for (final w in [45, 100]) {
    final idle = _g('idle-placeholder-$w');
    final bash = _g('card-bash-$w'), plan = _g('card-plan-$w');
    final bashCall = _call('card-bash'), planCall = _call('card-plan');
    Grid cursorTo(Grid g, int from, int to) => retext(retext(g, '❯ $from.', '  $from.'), '  $to. ', '❯ $to. ');

    test('yesIsOneDigit $w', () {
      final s = ScriptedGrids([(equals('1'), idle)], bash);
      expect(_send(s, cardSteps(_match(bash, bashCall), OptionAnswer('Yes')))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['1']);
    });

    test('noFindsItsRow $w', () {
      final s = ScriptedGrids([(equals('4'), idle)], bash);
      expect(_send(s, cardSteps(_match(bash, bashCall), OptionAnswer('No')))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['4']);

      final write = _g('card-write-$w');
      final ws = ScriptedGrids([(equals('3'), idle)], write);
      expect(_send(ws, cardSteps(_match(write, _call('card-write')), OptionAnswer('No')))?.outcome, GateOutcome.done);
      expect(ws.sentWrites, ['3']);
    });

    test('everyPermissionTakesYesAndNoDigits $w', () {
      for (final n in [
        'card-bash',
        'card-write',
        'card-edit',
        'card-mcp',
        'card-subagent-bash',
        'card-webfetch',
        if (w == 100) 'card-bash-classic',
      ]) {
        final g = _g('$n-$w'), m = _match(g, _call(n));
        for (final label in ['Yes', if (n != 'card-webfetch') 'No']) {
          expect(cardSteps(m, OptionAnswer(label)).single.ready(g), isTrue, reason: '$n $label');
        }
      }
    });

    test('yesWithNote $w', () {
      final amend = _g('card-bash-amend-$w');
      final s = ScriptedGrids([
        (equals('tab'), amend),
        (equals('paste:mind the stairs'), retext(amend, 'Yes, and tell Claude what to do next', 'Yes, mind the stairs')),
        (equals('enter'), idle),
      ], bash);
      expect(_send(s, cardSteps(_match(bash, bashCall), NoteAnswer(yes: true, text: 'mind the stairs')))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['tab', 'paste:mind the stairs', 'enter']);
    });

    test('noWithReasonWalksDown $w', () {
      final no = _g('card-bash-no-amend-$w');
      final two = cursorTo(bash, 1, 2), three = cursorTo(two, 2, 3);
      final s = ScriptedGrids([
        (equals('arrowDown'), two),
        (equals('arrowDown'), three),
        (equals('arrowDown'), cursorTo(three, 3, 4)),
        (equals('tab'), no),
        (equals('paste:too early'), retext(no, 'No, and tell Claude what to do differe', 'No, too early')),
        (equals('enter'), idle),
      ], bash);
      expect(_send(s, cardSteps(_match(bash, bashCall), NoteAnswer(yes: false, text: 'too early')))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['arrowDown', 'arrowDown', 'arrowDown', 'tab', 'paste:too early', 'enter']);

      final stuck = ScriptedGrids([(equals('arrowDown'), two)], bash);
      final r = _send(stuck, cardSteps(_match(bash, bashCall), NoteAnswer(yes: false, text: 'too early')));
      expect((r?.outcome, r?.step), (GateOutcome.timeout, 2));
      expect(stuck.sentWrites, ['arrowDown', 'arrowDown']);
    });

    test('noteNeedsCursorOnYes $w', () {
      final two = cursorTo(bash, 1, 2);
      final s = ScriptedGrids(const [], two);
      final r = _send(s, cardSteps(_match(two, bashCall), NoteAnswer(yes: true, text: 'mind the stairs')));
      expect((r?.outcome, r?.step), (GateOutcome.mismatch, 1));
      expect(s.sentWrites, isEmpty);
    });

    test('digitRefusedWhileAmending $w', () {
      final amend = _g('card-bash-amend-$w');
      final s = ScriptedGrids([(equals('4'), idle)], amend);
      expect(_send(s, cardSteps(_match(amend, bashCall), OptionAnswer('No')))?.outcome, GateOutcome.mismatch);
      expect(s.sentWrites, isEmpty);
    });

    test('secondTapRows $w', () {
      final rows = [for (final o in _match(bash, bashCall).dialog.options) o.label];
      expect([for (final l in rows) needsSecondTap(PromptKind.permission, l)], [false, true, true, false]);
      final planRows = {for (final o in _match(plan, planCall).dialog.options) o.label: needsSecondTap(PromptKind.plan, o.label)};
      expect(planRows, {'Yes, and use auto mode': true, 'Yes, manually approve edits': false, 'Tell Claude what to change': false});
      expect(needsSecondTap(PromptKind.permission, 'Sí'), isTrue);
      expect(needsSecondTap(PromptKind.plan, 'Sí, aprobar'), isTrue);
    });

    test('planNeverSendsBareEnter $w', () {
      final m = _match(plan, planCall);
      final answers = <CardAnswer>[for (final o in m.dialog.options.take(2)) OptionAnswer(o.label), PlanChange('two lanterns')];
      for (final a in answers) {
        final writes = [for (final st in cardSteps(m, a)) st.write];
        for (final (i, wr) in writes.indexed) {
          if (wr case KeyWrite(key: VtKey.enter)) expect(writes[i - 1], isA<PasteWrite>());
          expect(wr, isNot(isA<KeyWrite>().having((k) => k.key, 'key', VtKey.escape)));
        }
      }
      final s = ScriptedGrids([(equals('2'), idle)], plan);
      expect(_send(s, cardSteps(m, OptionAnswer('Yes, manually approve edits')))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['2']);
    });

    test('planChange $w', () {
      final change = _g('card-plan-change-$w');
      final s = ScriptedGrids([
        (equals('3'), change),
        (equals('paste:two lanterns'), retext(change, 'Tell Claude what to change', 'two lanterns')),
        (equals('enter'), idle),
      ], plan);
      expect(_send(s, cardSteps(_match(plan, planCall), PlanChange('two lanterns')))?.outcome, GateOutcome.done);
      expect(s.sentWrites, ['3', 'paste:two lanterns', 'enter']);

      final revised = ScriptedGrids([
        (equals('paste:two lanterns'), retext(change, 'Tell Claude what to change', 'two lanterns')),
        (equals('enter'), plan),
      ], change);
      expect(_send(revised, cardSteps(_match(change, planCall), PlanChange('two lanterns')))?.outcome, GateOutcome.done);

      final open = cardSteps(_match(change, planCall), PlanChange('two lanterns'));
      expect([for (final st in open) sent(st.write)], ['paste:two lanterns', 'enter'], reason: '❯ is already on the change row');
      final digit = ScriptedGrids([(equals('2'), idle)], change);
      expect(_send(digit, cardSteps(_match(change, planCall), OptionAnswer('Yes, manually approve edits')))?.outcome, GateOutcome.mismatch);
      expect(digit.sentWrites, isEmpty);
    });
  }

  test('previewNotesSteps', () {
    final start = _g('card-ask-preview-100'), notes = _g('card-ask-preview-notes-100');
    final steps = cardSteps(
      _match(start, _call('card-ask-preview')),
      _ask([
        const QuestionAnswer(labels: ['Ring'], notes: 'brass lamp'),
      ]),
    );
    final s = ScriptedGrids([
      (equals('n'), notes),
      (equals('paste:brass lamp'), retext(notes, 'Add notes on this design…', 'brass lamp')),
      (equals('enter'), _g('idle-placeholder-100')),
    ], start);
    expect(_send(s, steps)?.outcome, GateOutcome.done);
    expect(s.sentWrites, ['n', 'paste:brass lamp', 'enter']);
  });

  test('fieldShows', () {
    final filled = PromptDialog.read(_g('card-ask-other-filled-45'))!;
    expect(fieldShows(filled, 'two\nlines'), isTrue);
    expect(fieldShows(filled, 'three'), isFalse);
  });
}
