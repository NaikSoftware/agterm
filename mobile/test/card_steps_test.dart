import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/card_steps.dart';
import 'package:elis_mobile/chat/checks.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/prompt_dialog.dart';
import 'package:elis_mobile/chat/prompt_match.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/chat/write_gate.dart';
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
