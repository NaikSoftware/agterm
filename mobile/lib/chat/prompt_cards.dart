import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'card_checks.dart';
import 'card_steps.dart';
import 'chat_view.dart';
import 'checks.dart';
import 'grid.dart';
import 'items.dart';
import 'prompt_match.dart';
import 'write_gate.dart';

String stopMessage(GateResult r) => 'Stopped at step ${r.step} of ${r.total}: ${r.reason}. The prompt may be half answered.';

String? _blocked(Checks checks, ChatPromptContext c) =>
    checks.writeBlocked ?? (c.remote && !checks.remote ? 'Answering is off on remote rows until checked' : null);

Future<void> sendAnswer(
  ChatPromptContext c,
  PromptMatch m,
  CardAnswer a, {
  required VoidCallback onDone,
  required VoidCallback onStop,
}) async {
  final steps = cardSteps(m, a);
  final r = await c.gate.run(steps.length, (s) async {
    for (final st in steps) {
      await s.send(st);
    }
  });
  if (r.ok) return onDone();
  if (r.outcome == GateOutcome.busy) return;
  onStop();
  c.openPanel(stopMessage(r));
}

/// A full-width card answer: filled when primary, outlined and confirmed by a second tap when it persists a rule or mode.
class CardButton extends StatefulWidget {
  const CardButton({
    super.key,
    required this.label,
    this.description,
    this.onPressed,
    this.primary = false,
    this.secondTap = false,
    this.checked,
    this.busy,
  });

  final String label;
  final String? description;
  final VoidCallback? onPressed;
  final bool primary, secondTap;
  final bool? checked; // a multiSelect toggle
  final String? busy; // the gate's progress, shown in place of the label

  @override
  State<CardButton> createState() => _CardButtonState();
}

class _CardButtonState extends State<CardButton> {
  Timer? _armed;

  @override
  void dispose() {
    _armed?.cancel();
    super.dispose();
  }

  void _tap() {
    if (widget.secondTap && _armed == null) {
      setState(
        () => _armed = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _armed = null);
        }),
      );
      return;
    }
    _armed?.cancel();
    setState(() => _armed = null);
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.onPressed == null ? null : _tap;
    final label = widget.busy ?? (_armed != null ? 'Tap again to confirm' : widget.label);
    final desc = widget.busy == null && _armed == null ? widget.description : null;
    final child = Row(
      children: [
        if (widget.checked case final c?)
          Padding(padding: const EdgeInsets.only(right: 8), child: Icon(c ? Icons.check_box : Icons.check_box_outline_blank, size: 20)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              if (desc != null) Text(desc, style: const TextStyle(fontSize: 12, color: C.muted)),
            ],
          ),
        ),
      ],
    );
    const pad = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        width: double.infinity,
        child: widget.primary
            ? FilledButton(
                style: FilledButton.styleFrom(padding: pad),
                onPressed: on,
                child: child,
              )
            : widget.secondTap
            ? OutlinedButton(
                style: OutlinedButton.styleFrom(padding: pad),
                onPressed: on,
                child: child,
              )
            : FilledButton.tonal(
                style: FilledButton.styleFrom(padding: pad),
                onPressed: on,
                child: child,
              ),
      ),
    );
  }
}

/// The docked card: "`<Tool>` · needs you", scrolling content, a reason line, then the buttons, the primary last.
class CardFrame extends StatelessWidget {
  const CardFrame({
    super.key,
    required this.title,
    required this.content,
    required this.buttons,
    this.reason,
    this.onPanel,
    this.step,
    this.locked = false,
  });

  final String title;
  final Widget content;
  final List<Widget> buttons;
  final String? reason; // why the buttons are disabled
  final VoidCallback? onPanel; // shows "Answer in panel"
  final String? step; // "1/2"
  final bool locked; // an answer is being sent

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('promptCard'),
    color: C.surface,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('$title · needs you', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (step case final s?) Text(s, style: const TextStyle(color: C.muted)),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(flex: 2, child: SingleChildScrollView(child: content)),
            if (reason case final r?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  r,
                  key: const Key('cardReason'),
                  style: const TextStyle(color: C.blockedText),
                ),
              ),
            Flexible(
              flex: 3,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onPanel != null) CardButton(label: 'Answer in panel', onPressed: locked ? null : onPanel),
                    ...buttons,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

typedef _Option = ({String label, String? description, String? preview});

class _Question {
  _Question(Map q)
    : question = q['question'] is String ? q['question'] as String : '',
      header = q['header'] is String ? q['header'] as String : '',
      multi = q['multiSelect'] == true,
      options = [
        for (final o in q['options'] is List ? q['options'] as List : const [])
          if (o is Map)
            (
              label: o['label'] is String ? o['label'] as String : '',
              description: o['description'] is String ? o['description'] as String : null,
              preview: o['preview'] is String ? o['preview'] as String : null,
            ),
      ];

  final String question, header;
  final bool multi;
  final List<_Option> options;
  final picked = <String>{};
  final other = TextEditingController(), notes = TextEditingController();
  bool notesOpen = false;
  QuestionAnswer? answer;

  bool get preview => options.any((o) => o.preview != null);

  String? get otherText => other.text.trim().isEmpty ? null : other.text;

  void dispose() {
    other.dispose();
    notes.dispose();
  }
}

const _proven = checks; // the field below shadows the global

/// AskUserQuestion: one step per question, then a Review step when there are two or more.
class AskCard extends StatefulWidget {
  const AskCard({
    super.key,
    required this.c,
    required this.m,
    required this.onDone,
    required this.onStop,
    this.checks = _proven,
    this.cards = cardChecks,
  });

  final ChatPromptContext c;
  final PromptMatch m;
  final VoidCallback onDone, onStop;
  final Checks checks;
  final CardChecks cards;

  @override
  State<AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<AskCard> {
  late List<_Question> _qs;
  var _step = 0;
  String? _sender; // the button that started the run shows its progress

  @override
  void initState() {
    super.initState();
    _qs = _read();
  }

  @override
  void didUpdateWidget(AskCard old) {
    super.didUpdateWidget(old);
    if (old.m.call.id == widget.m.call.id) return;
    for (final q in _qs) {
      q.dispose();
    }
    _qs = _read();
    _step = 0;
    _sender = null;
  }

  @override
  void dispose() {
    for (final q in _qs) {
      q.dispose();
    }
    super.dispose();
  }

  List<_Question> _read() => [
    for (final q in widget.m.call.input?['questions'] is List ? widget.m.call.input!['questions'] as List : const [])
      if (q is Map) _Question(q),
  ];

  void _send(String sender, CardAnswer a) {
    setState(() => _sender = sender);
    unawaited(sendAnswer(widget.c, widget.m, a, onDone: widget.onDone, onStop: widget.onStop));
  }

  void _answer(String sender, int i, QuestionAnswer a) {
    _qs[i].answer = a;
    if (_qs.length == 1) return _send(sender, AskAnswer([a]));
    setState(() => _step = i + 1);
  }

  QuestionAnswer _multiAnswer(_Question q) => QuestionAnswer(
    labels: [
      for (final o in q.options)
        if (q.picked.contains(o.label)) o.label,
    ],
    other: q.otherText,
  );

  static String _shown(QuestionAnswer? a) => [...?a?.labels, ?a?.other].join(', ');

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.c.gate, builder: (context, _) => _build());

  Widget _build() {
    final running = widget.c.gate.running, blocked = _blocked(widget.checks, widget.c), locked = running || blocked != null;
    VoidCallback? act(VoidCallback f) => locked ? null : f;
    String? busy(String label) => running && _sender == label ? widget.c.gate.progress : null;
    CardButton button(String label, VoidCallback f, {String? description, bool primary = false, bool? checked}) =>
        CardButton(label: label, description: description, primary: primary, checked: checked, busy: busy(label), onPressed: act(f));

    final review = _step >= _qs.length;
    final q = review ? null : _qs[_step];
    final discuss = widget.m.dialog.options.any((o) => o.belowRule && o.number != null);
    // an unproven step is reached through the panel (rule 14)
    final unproven = q != null && !q.multi && (!widget.cards.singleOther || (q.preview && !widget.cards.previewNotes));
    final go = _qs.length == 1 ? 'Send' : 'Next';

    final Widget content;
    final buttons = <Widget>[
      if (discuss) button('Chat about this', () => _send('Chat about this', AskDiscuss())),
      button('Cancel', () => _send('Cancel', AskCancel())),
    ];
    if (q == null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final q in _qs) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(q.question, style: const TextStyle(color: C.muted)),
            ),
            Text('→ ${_shown(q.answer)}'),
          ],
        ],
      );
      buttons.add(button('Send', () => _send('Send', AskAnswer([for (final q in _qs) q.answer ?? const QuestionAnswer()])), primary: true));
    } else {
      final i = _step;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (q.header.isNotEmpty) Text(q.header, style: const TextStyle(fontSize: 12, color: C.muted)),
          Text(q.question, style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final o in q.options)
            if (o.preview case final p?) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(o.label, style: const TextStyle(fontSize: 12, color: C.muted)),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  p,
                  style: const TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 12),
                ),
              ),
            ],
        ],
      );
      final field = TextField(
        key: const Key('askOther'),
        controller: q.other,
        enabled: !locked,
        minLines: 1,
        maxLines: 4,
        decoration: const InputDecoration(hintText: 'Other'),
        onChanged: (_) => setState(() {}),
      );
      if (q.multi) {
        buttons.addAll([
          for (final o in q.options)
            button(
              o.label,
              () => setState(() => q.picked.contains(o.label) ? q.picked.remove(o.label) : q.picked.add(o.label)),
              description: o.description,
              checked: q.picked.contains(o.label),
            ),
          field,
          button(go, () => _answer(go, i, _multiAnswer(q)), primary: true),
        ]);
      } else {
        final notes = q.preview && widget.cards.previewNotes;
        String? note() => notes && q.notesOpen && q.notes.text.trim().isNotEmpty ? q.notes.text : null;
        buttons.addAll([
          for (final o in q.options)
            button(
              o.label,
              () => _answer(o.label, i, QuestionAnswer(labels: [o.label], notes: note())),
              description: o.description,
            ),
          if (notes) ...[
            button('Notes', () => setState(() => q.notesOpen = !q.notesOpen)),
            if (q.notesOpen)
              TextField(
                key: const Key('askNotes'),
                controller: q.notes,
                enabled: !locked,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'Notes'),
              ),
          ],
          if (widget.cards.singleOther) ...[
            field,
            CardButton(
              label: go,
              primary: true,
              busy: busy(go),
              onPressed: q.otherText == null ? null : act(() => _answer(go, i, QuestionAnswer(other: q.otherText))),
            ),
          ],
        ]);
      }
    }
    return CardFrame(
      title: widget.m.call.name,
      step: _qs.length > 1 && !review ? '${_step + 1}/${_qs.length}' : null,
      content: content,
      buttons: buttons,
      reason: blocked,
      locked: running,
      onPanel: blocked != null || unproven ? () => widget.c.openPanel(null) : null,
    );
  }
}

/// [text]'s first [lines] lines, then a `More` button that shows the rest.
class _More extends StatefulWidget {
  const _More(this.text, this.lines, this.show);

  final String text;
  final int lines;
  final Widget Function(String) show;

  @override
  State<_More> createState() => _MoreState();
}

class _MoreState extends State<_More> {
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final ls = widget.text.split('\n'), cut = !_all && ls.length > widget.lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.show(cut ? ls.take(widget.lines).join('\n') : widget.text),
        if (cut) TextButton(onPressed: () => setState(() => _all = true), child: const Text('More')),
      ],
    );
  }
}

Text _code(String t, {Color? color}) => Text(
  t,
  style: TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 12, color: color),
);

const _muted = TextStyle(color: C.muted);

/// A card button; [answer] null opens the panel, and [field] opens a text field whose text [answer] takes.
typedef _Row = ({String label, CardAnswer Function(String text)? answer, bool field, bool primary, bool secondTap});

const _Row _morePanel = (label: 'More options in panel', answer: null, field: false, primary: false, secondTap: false);

/// The numbered rows in screen order; rows that persist a rule or mode collapse into one panel button until proven (rule 14).
List<_Row> _screenRows(PromptMatch m, CardChecks cards, String primary, {String? change}) {
  final rows = <_Row>[];
  for (final o in m.dialog.options) {
    if (o.number == null) continue;
    final l = o.label, second = needsSecondTap(m.kind, l);
    if (change != null && norm(l) == norm(change)) {
      rows.add((label: 'Change', answer: PlanChange.new, field: true, primary: false, secondTap: false));
    } else if (second && !cards.persistOptions) {
      if (!rows.contains(_morePanel)) rows.add(_morePanel);
    } else {
      rows.add((label: l, answer: (_) => OptionAnswer(l), field: false, primary: norm(l) == norm(primary), secondTap: second));
    }
  }
  return rows;
}

/// Permission and plan cards: the call's content, then one button per row, the primary last as in [CardFrame].
class _RowsCard extends StatefulWidget {
  const _RowsCard({
    required this.c,
    required this.m,
    required this.onDone,
    required this.onStop,
    required this.checks,
    required this.title,
    required this.content,
    required this.rows,
  });

  final ChatPromptContext c;
  final PromptMatch m;
  final VoidCallback onDone, onStop;
  final Checks checks;
  final String title;
  final Widget content;
  final List<_Row>? Function() rows; // null: answered only in the panel

  @override
  State<_RowsCard> createState() => _RowsCardState();
}

class _RowsCardState extends State<_RowsCard> {
  List<_Row>? _rows;
  final _text = TextEditingController();
  String? _open, _sender;

  @override
  void didUpdateWidget(_RowsCard old) {
    super.didUpdateWidget(old);
    if (old.m.call.id == widget.m.call.id) return;
    _text.clear();
    _open = _sender = null;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send(String sender, CardAnswer a) {
    setState(() => _sender = sender);
    unawaited(sendAnswer(widget.c, widget.m, a, onDone: widget.onDone, onStop: widget.onStop));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.c.gate, builder: (context, _) => _build());

  Widget _build() {
    final running = widget.c.gate.running, blocked = _blocked(widget.checks, widget.c), locked = running || blocked != null;
    VoidCallback? act(VoidCallback f) => locked ? null : f;
    String? busy(String label) => running && _sender == label ? widget.c.gate.progress : null;
    // frozen while sending: Tab and a paste relabel the rows under the running card
    if (!running || _rows == null) _rows = widget.rows();
    final rows = _rows ?? const <_Row>[];
    final buttons = <Widget>[
      for (final r in [...rows.where((r) => !r.primary), ...rows.where((r) => r.primary)])
        if (r.answer case final answer?) ...[
          CardButton(
            // a second tap armed on one prompt never confirms the next
            key: ValueKey('${widget.m.call.id}|${r.label}'),
            label: r.label,
            primary: r.primary,
            secondTap: r.secondTap,
            busy: busy(r.label),
            onPressed: act(() => r.field ? setState(() => _open = _open == r.label ? null : r.label) : _send(r.label, answer(''))),
          ),
          if (r.field && _open == r.label) ...[
            TextField(
              key: const Key('cardField'),
              controller: _text,
              enabled: !locked,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
            ),
            CardButton(
              label: 'Send',
              busy: busy('Send'),
              onPressed: _text.text.trim().isEmpty ? null : act(() => _send('Send', answer(_text.text))),
            ),
          ],
        ] else
          CardButton(label: r.label, onPressed: running ? null : () => widget.c.openPanel(null)),
    ];
    return CardFrame(
      title: widget.title,
      content: widget.content,
      buttons: buttons,
      reason: blocked,
      locked: running,
      onPanel: blocked != null || _rows == null ? () => widget.c.openPanel(null) : null,
    );
  }
}

/// Bash, Write, Edit, WebFetch and MCP permission prompts.
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    super.key,
    required this.c,
    required this.m,
    required this.onDone,
    required this.onStop,
    this.checks = _proven,
    this.cards = cardChecks,
  });

  final ChatPromptContext c;
  final PromptMatch m;
  final VoidCallback onDone, onStop;
  final Checks checks;
  final CardChecks cards;

  @override
  Widget build(BuildContext context) {
    final call = m.call, name = call.name, input = call.input ?? const {};
    String s(String k) => input[k] is String ? input[k] as String : '';
    final mcp = name.startsWith('mcp__') ? name.substring(5) : null, cut = mcp?.indexOf('__') ?? -1;
    final (server, tool) = cut < 0 ? (mcp, mcp) : (mcp!.substring(0, cut), mcp.substring(cut + 2));
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (call.source != 'main') const Text('from a subagent', style: _muted),
        ...switch (name) {
          'Bash' => [_code('\$ ${s('command')}'), if (s('description').isNotEmpty) Text(s('description'), style: _muted)],
          'Write' => [Text(s('file_path'), style: _muted), _More(s('content'), 20, _code)],
          'Edit' => [
            Text(s('file_path'), style: _muted),
            for (final l in s('old_string').split('\n')) _code('-$l', color: C.danger),
            for (final l in s('new_string').split('\n')) _code('+$l', color: C.completedText),
          ],
          'WebFetch' => [Text(s('url')), Text(s('prompt'), style: _muted)],
          _ => [
            Text('$server · $tool', style: _muted),
            for (final MapEntry(:key, :value) in input.entries) _code('$key: ${value is String ? value : jsonEncode(value)}'),
          ],
        },
      ],
    );
    final notes = name == 'Bash' || (name != 'WebFetch' && cards.fileAndMcpNotes);
    // a note needs the exact Yes or No row: with the amend field already open on the computer there is none
    _Row note(String label, String word) =>
        (label: label, answer: (t) => NoteAnswer(yes: word == 'Yes', text: t), field: true, primary: false, secondTap: false);
    return _RowsCard(
      c: c,
      m: m,
      onDone: onDone,
      onStop: onStop,
      checks: checks,
      title: tool ?? name,
      content: content,
      rows: () => name == 'WebFetch' && !cards.webFetch
          ? null
          : [
              ..._screenRows(m, cards, 'Yes'),
              if (notes && m.dialog.numbered('Yes') != null) note('Yes with a note', 'Yes'),
              if (notes && m.dialog.numbered('No') != null) note('No with a reason', 'No'),
            ],
    );
  }
}

/// ExitPlanMode: the plan as markdown, the approval rows and a Change field.
class PlanCard extends StatelessWidget {
  const PlanCard({
    super.key,
    required this.c,
    required this.m,
    required this.onDone,
    required this.onStop,
    this.checks = _proven,
    this.cards = cardChecks,
  });

  final ChatPromptContext c;
  final PromptMatch m;
  final VoidCallback onDone, onStop;
  final Checks checks;
  final CardChecks cards;

  @override
  Widget build(BuildContext context) {
    final plan = m.call.input?['plan'];
    return _RowsCard(
      c: c,
      m: m,
      onDone: onDone,
      onStop: onStop,
      checks: checks,
      title: m.call.name,
      content: _More(plan is String ? plan : '', 12, chatMarkdown),
      rows: () => _screenRows(m, cards, 'Yes, manually approve edits', change: 'Tell Claude what to change'),
    );
  }
}
