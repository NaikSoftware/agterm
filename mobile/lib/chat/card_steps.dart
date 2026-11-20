import 'dart:math';

import '../terminal/vt.dart';
import 'grid.dart';
import 'prompt_dialog.dart';
import 'prompt_match.dart';
import 'write_gate.dart';

sealed class CardAnswer {}

class QuestionAnswer {
  const QuestionAnswer({this.labels = const [], this.other, this.notes});
  final List<String> labels; // single choice: one label, or none with [other]
  final String? other;
  final String? notes;
}

class AskAnswer extends CardAnswer {
  AskAnswer(this.questions);
  final List<QuestionAnswer> questions;
}

class AskDiscuss extends CardAnswer {} // "Chat about this"

class AskCancel extends CardAnswer {}

class OptionAnswer extends CardAnswer {
  OptionAnswer(this.label);
  final String label; // a row by its verbatim screen label
}

class NoteAnswer extends CardAnswer {
  NoteAnswer({required this.yes, required this.text});
  final bool yes;
  final String text;
}

class PlanChange extends CardAnswer {
  PlanChange(this.text);
  final String text;
}

/// The whole key sequence for [a], fixed before the first write; each step re-reads the dialog and its anchor.
List<GateStep> cardSteps(PromptMatch m, CardAnswer a) => switch (m.kind) {
  PromptKind.ask => _Ask(m).steps(a),
  PromptKind.permission => _Permission(m).steps(a),
  PromptKind.plan => _Plan(m).steps(a),
};

/// Rows that persist a rule or change the mode need a second tap; a label the card does not know always does.
bool needsSecondTap(PromptKind k, String label) => switch (k) {
  PromptKind.permission => !['Yes', 'No'].any((l) => norm(l) == norm(label)),
  PromptKind.plan => !['Yes, manually approve edits', _Plan.change].any((l) => norm(l) == norm(label)),
  PromptKind.ask => false,
};

/// Whether the cursor option shows [text]: its first line's first 40 characters, or Claude's "[Pasted text" stand-in.
bool fieldShows(PromptDialog d, String text) => _shows(d.cursorOption?.label, text);

bool _shows(String? label, String text) {
  if (label == null) return false;
  final l = norm(label), needle = _needle(text);
  return (needle.isNotEmpty && l.contains(needle)) || l.contains('[Pastedtext');
}

String _needle(String text) {
  final n = norm(text.split(RegExp(r'[\r\n]')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => ''));
  return n.substring(0, min(40, n.length));
}

const _nano = 'ctrl+gtoeditinnano';

class _Card {
  _Card(this.m);

  final PromptMatch m;

  PromptDialog get d0 => m.dialog;

  PromptDialog? read(Grid g) {
    final d = PromptDialog.read(g);
    return d != null && anchored(d, m.call) ? d : null;
  }

  bool at(Grid g, bool Function(PromptDialog d) f) {
    final d = read(g);
    return d != null && f(d);
  }

  bool gone(Grid g) => read(g) == null;

  GateStep step(GateWrite w, bool Function(PromptDialog d) ready, bool Function(Grid g) done, {String? why}) =>
      GateStep(w, ready: (g) => at(g, ready), done: done, why: why);

  int number(String label) => d0.numbered(label)?.number ?? (throw ArgumentError('no row $label'));

  GateStep pick(String label, bool Function(PromptDialog d) keyable) {
    final k = number(label);
    return step(TextWrite('$k'), (d) => keyable(d) && _Ask.row(d, label)?.number == k, gone);
  }
}

class _Ask extends _Card {
  _Ask(super.m)
    : qs = [
        for (final q in m.call.input?['questions'] is List ? m.call.input!['questions'] as List : const [])
          if (q is Map) q,
      ];

  final List<Map> qs;

  List<String> labels(int i) => [
    for (final o in qs[i]['options'] is List ? qs[i]['options'] as List : const [])
      if (o is Map) o['label'] is String ? o['label'] as String : '',
  ];

  bool multi(int i) => qs[i]['multiSelect'] == true;

  bool preview(int i) => [
    for (final o in qs[i]['options'] is List ? qs[i]['options'] as List : const [])
      if (o is Map && o['preview'] != null) o,
  ].isNotEmpty;

  // the tab showing question i; a Review tab is never one
  bool on(int i, PromptDialog d) => !d.review && matchPrompt(d, [m.call])?.question == i;

  static bool field(PromptDialog d) => norm(d.footer).contains(_nano);

  static List<DialogOption> list(PromptDialog d) => [
    for (final o in d.options)
      if (o.number != null && !o.belowRule) o,
  ];

  static int cursorAt(PromptDialog d) => list(d).indexWhere((o) => o.cursor);

  static DialogOption? otherRow(PromptDialog d, int n) => list(d).length > n ? list(d)[n] : null;

  // a digit typed into a focused field becomes text
  static bool keyable(PromptDialog d) => !field(d) && cursorAt(d) >= 0;

  static String region(Grid g, PromptDialog d) => norm([for (var r = d.top; r < g.rows.length; r++) g.text(r)].join());

  static DialogOption? row(PromptDialog d, String label) =>
      d.options.where((o) => o.number != null && norm(o.label) == norm(label)).firstOrNull;

  // gone, the next question's text, or Review
  bool advanced(Grid g, int i) {
    final d = read(g);
    return d == null || d.review || matchPrompt(d, [m.call])?.question == i + 1;
  }

  // a tab not shown yet is assumed untouched: digits by position, verified on screen before each write
  int digit(PromptDialog? shown, int i, String label) {
    if (shown != null) return shown.numbered(label)?.number ?? (throw ArgumentError('no row $label'));
    final k = labels(i).indexWhere((l) => norm(l) == norm(label));
    if (k < 0) throw ArgumentError('no option $label');
    return k + 1;
  }

  List<GateStep> steps(CardAnswer a) => switch (a) {
    AskDiscuss() => [
      for (final o in d0.options.where((o) => o.belowRule && o.number != null).take(1))
        step(TextWrite('${o.number}'), (d) => keyable(d) && d.options.any((x) => x.belowRule && x.number == o.number), gone),
    ],
    AskCancel() => switch (d0.review ? row(d0, 'Cancel')?.number : null) {
      final n? => [step(TextWrite('$n'), (d) => d.review && row(d, 'Cancel')?.number == n, gone)],
      // the only Esc a card sends, always its last write
      null => [step(KeyWrite(VtKey.escape), (d) => !field(d), gone)],
    },
    AskAnswer(:final questions) => answer(questions),
    _ => throw ArgumentError('${a.runtimeType} does not answer AskUserQuestion'),
  };

  List<GateStep> answer(List<QuestionAnswer> answers) {
    if (answers.length != qs.length || qs.isEmpty) throw ArgumentError('${answers.length} answers for ${qs.length} questions');
    final out = <GateStep>[];
    final start = m.question ?? qs.length;
    for (var i = start; i < qs.length; i++) {
      final shown = i == start ? d0 : null;
      final tab = multi(i) ? multiSteps(i, answers[i], shown) : singleSteps(i, answers[i], shown);
      if (shown == null && tab.isNotEmpty) {
        final first = tab.first;
        tab[0] = GateStep(
          first.write,
          ready: (g) =>
              at(g, (d) => list(d).isNotEmpty && list(d).first.cursor && list(d).every((o) => o.checked != true)) && first.ready(g),
          done: first.done,
          why: first.why,
        );
      }
      out.addAll(tab);
    }
    if (qs.length > 1 || multi(0)) out.add(submit(answers));
    return out;
  }

  List<GateStep> singleSteps(int i, QuestionAnswer a, PromptDialog? shown) {
    bool next(Grid g) => advanced(g, i);
    final other = a.other;
    if (other != null) {
      if (a.labels.isNotEmpty || a.notes != null) throw ArgumentError('single choice takes one label or only other');
      final n = labels(i).length, k = shown != null ? otherRow(shown, n)?.number ?? (throw ArgumentError('no Other row')) : n + 1;
      bool open(PromptDialog d) => on(i, d) && otherRow(d, n)?.cursor == true && field(d);
      return [
        step(TextWrite('$k'), (d) => on(i, d) && keyable(d) && otherRow(d, n)?.number == k, (g) => at(g, open)),
        step(PasteWrite(other), open, (g) => at(g, (d) => on(i, d) && fieldShows(d, other))),
        step(KeyWrite(VtKey.enter), (d) => on(i, d) && fieldShows(d, other), next),
      ];
    }
    if (a.labels.length != 1) throw ArgumentError('single choice takes one label or only other');
    final label = a.labels.single, k = digit(shown, i, label);
    final pick = step(TextWrite('$k'), (d) => on(i, d) && keyable(d) && row(d, label)?.number == k, next);
    if (!preview(i)) {
      if (a.notes != null) throw ArgumentError('notes need a preview option');
      return [pick];
    }
    // a preview digit only moves the cursor; already there, it would change nothing and time out
    bool onK(PromptDialog d) => on(i, d) && d.cursorOption?.number == k;
    final notes = a.notes;
    return [
      if ((shown?.cursorOption?.number ?? 1) != k) GateStep(pick.write, ready: pick.ready, done: (g) => at(g, onK)),
      if (notes == null)
        step(KeyWrite(VtKey.enter), (d) => onK(d) && !field(d), next)
      else ...[
        // the pane's "press n to add notes" gives way to the field; the footer keeps "n to add notes"
        step(
          TextWrite('n'),
          (d) => onK(d) && !field(d) && norm(d.footer).contains('ntoaddnotes'),
          (g) => at(g, (d) => onK(d) && !region(g, d).contains('pressntoaddnotes')),
        ),
        GateStep(
          PasteWrite(notes),
          ready: (g) => at(g, (d) => onK(d) && !region(g, d).contains('pressntoaddnotes')),
          done: (g) => at(g, (d) => region(g, d).contains(_needle(notes))),
        ),
        GateStep(KeyWrite(VtKey.enter), ready: (g) => at(g, (d) => onK(d) && region(g, d).contains(_needle(notes))), done: next),
      ],
    ];
  }

  List<GateStep> multiSteps(int i, QuestionAnswer a, PromptDialog? shown) {
    if (a.notes != null) throw ArgumentError('notes need a preview option');
    final opts = labels(i), n = opts.length, other = a.other;
    bool wanted(String l) => a.labels.any((x) => norm(x) == norm(l));
    for (final l in a.labels) {
      if (!opts.any((o) => norm(o) == norm(l))) throw ArgumentError('no option $l');
    }
    final cursor = shown == null ? 0 : cursorAt(shown);
    final out = <GateStep>[];
    for (final label in opts) {
      final now = shown?.numbered(label)?.checked ?? false, want = wanted(label);
      if (now == want) continue;
      final k = digit(shown, i, label);
      out.add(
        step(
          TextWrite('$k'),
          (d) => on(i, d) && keyable(d) && row(d, label)?.number == k && row(d, label)?.checked == now && cursorAt(d) == cursor,
          (g) => at(g, (d) => on(i, d) && row(d, label)?.checked == want && cursorAt(d) == cursor),
        ),
      );
    }

    final filled = shown != null ? otherRow(shown, n) : null;
    final ticked = filled?.checked == true;
    // never paste into a ticked Other: the text would join what the computer typed
    final conflict = ticked && (other == null || !_shows(filled!.label, other));
    var at0 = cursor;
    if (other != null && !ticked) {
      for (var r = cursor; r < n; r++) {
        out.add(step(KeyWrite(VtKey.arrowDown), (d) => on(i, d) && cursorAt(d) == r, (g) => at(g, (d) => cursorAt(d) == r + 1)));
      }
      out.add(
        step(
          PasteWrite(other),
          (d) => on(i, d) && cursorAt(d) == n && field(d),
          (g) => at(g, (d) => otherRow(d, n)?.checked == true && fieldShows(d, other)),
        ),
      );
      at0 = n;
    }
    if (other != null && !conflict && at0 == n) {
      out.add(
        step(
          KeyWrite(VtKey.arrowUp),
          (d) => on(i, d) && cursorAt(d) == n && otherRow(d, n)?.checked == true && fieldShows(d, other),
          (g) => at(g, (d) => cursorAt(d) == n - 1 && _shows(otherRow(d, n)?.label, other)),
        ),
      );
    }

    // Tab and → do nothing on a filled Other row or on Next
    final one = qs.length == 1;
    out.add(
      step(
        KeyWrite(one ? VtKey.tab : VtKey.arrowRight),
        (d) => on(i, d) && !field(d) && cursorAt(d) >= 0 && cursorAt(d) < n,
        (g) => at(g, (d) => d.review || (!one && matchPrompt(d, [m.call])?.question == i + 1)),
      ),
    );

    if (conflict) {
      final first = out.first;
      out[0] = GateStep(
        first.write,
        ready: (g) => at(g, (d) => otherRow(d, n)?.checked != true) && first.ready(g),
        done: first.done,
        why: 'Other is filled on the computer',
      );
    }
    return out;
  }

  GateStep submit(List<QuestionAnswer> answers) {
    final k = (d0.review ? row(d0, 'Submit answers')?.number : null) ?? 1;
    bool same(PromptDialog d) {
      if (d.answers.length != answers.length) return false;
      for (final (i, a) in answers.indexed) {
        final parts = [...a.labels, ?a.other].map(norm).toList(), shown = norm(d.answers[i]);
        if (shown.length != parts.fold(parts.length - 1, (s, p) => s + p.length) || !parts.every(shown.contains)) return false;
      }
      return true;
    }

    return step(TextWrite('$k'), (d) => d.review && !field(d) && same(d) && row(d, 'Submit answers')?.number == k, gone);
  }
}

class _Permission extends _Card {
  _Permission(super.m);

  static const _amend = 'Tabtoamend';

  // an open amend field takes digits and Tab as text; WebFetch has no "Tab to amend" footer to lose
  static bool closed(PromptDialog d) => _Ask.keyable(d) && !amending(d, 'Yes') && !amending(d, 'No');

  static bool amending(PromptDialog d, String word) =>
      (d.cursorOption?.label.startsWith('$word,') ?? false) && !norm(d.footer).contains(_amend);

  List<GateStep> steps(CardAnswer a) => switch (a) {
    OptionAnswer(:final label) => [pick(label, closed)],
    NoteAnswer(:final yes, :final text) => note(yes ? 'Yes' : 'No', text),
    _ => throw ArgumentError('${a.runtimeType} does not answer a permission prompt'),
  };

  // Yes needs ❯ on its row already; No walks down to its row one key at a time
  List<GateStep> note(String word, String text) {
    final k = number(word), rows = _Ask.list(d0), target = rows.indexWhere((o) => o.number == k);
    bool on(PromptDialog d) => d.cursorOption?.number == k;
    return [
      if (word == 'No')
        for (var r = _Ask.cursorAt(d0); r >= 0 && r < target; r++)
          step(KeyWrite(VtKey.arrowDown), (d) => _Ask.cursorAt(d) == r && !_Ask.field(d), (g) => at(g, (d) => _Ask.cursorAt(d) == r + 1)),
      step(
        KeyWrite(VtKey.tab),
        (d) => closed(d) && on(d) && _Ask.row(d, word)?.number == k,
        (g) => at(g, (d) => on(d) && amending(d, word)),
      ),
      step(PasteWrite(text), (d) => on(d) && amending(d, word), (g) => at(g, (d) => on(d) && fieldShows(d, text))),
      step(KeyWrite(VtKey.enter), (d) => on(d) && fieldShows(d, text), gone),
    ];
  }
}

class _Plan extends _Card {
  _Plan(super.m);

  static const change = 'Tell Claude what to change';

  // ❯ on the change row focuses its field, and the plan footer always reads "ctrl+g to edit in nano"
  late final int changeRow = d0.numbered(change)?.number ?? _Ask.list(d0).last.number!;

  bool keyable(PromptDialog d) => _Ask.cursorAt(d) >= 0 && d.cursorOption!.number != changeRow;

  List<GateStep> steps(CardAnswer a) => switch (a) {
    // its digit only focuses the field
    OptionAnswer(:final label) when norm(label) == norm(change) => throw ArgumentError('$change takes a PlanChange'),
    OptionAnswer(:final label) => [pick(label, keyable)],
    PlanChange(:final text) => changeSteps(text),
    _ => throw ArgumentError('${a.runtimeType} does not answer a plan prompt'),
  };

  List<GateStep> changeSteps(String text) {
    final k = number(change);
    bool on(PromptDialog d) => d.cursorOption?.number == k;
    return [
      if (!on(d0)) step(TextWrite('$k'), (d) => keyable(d) && _Ask.row(d, change)?.number == k, (g) => at(g, on)),
      step(
        PasteWrite(text),
        (d) => on(d) && norm(d.cursorOption!.label) == norm(change),
        (g) => at(g, (d) => on(d) && fieldShows(d, text)),
      ),
      // a revised plan anchors to this call again, with an empty change row
      step(KeyWrite(VtKey.enter), (d) => on(d) && fieldShows(d, text), (g) => !at(g, (d) => fieldShows(d, text))),
    ];
  }
}
