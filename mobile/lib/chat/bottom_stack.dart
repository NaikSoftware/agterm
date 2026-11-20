import 'package:flutter/material.dart';

import '../terminal/vt.dart';
import '../theme.dart';
import 'checks.dart';
import 'claude_screen.dart';
import 'feed.dart';
import 'grid.dart';
import 'write_gate.dart';

const _checks = checks; // the field below shadows the constant in its own default
const _small = TextStyle(fontSize: 12, color: C.muted);
const _mono = TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 12, color: C.termText);

// markdown markers too: Claude's TUI draws `# Title` and `**bold**` without them
String _key(String s) => norm(s).replaceAll(RegExp(r'[#*_`>]'), '');

/// One Esc that ends once [showing] goes or a new `Interrupted` row appears (check 13: the queue may keep Claude busy).
GateStep _esc(bool Function(ClaudeScreen s) showing) {
  int? at;
  return GateStep(KeyWrite(VtKey.escape), ready: (g) {
    final s = ClaudeScreen.read(g);
    at = s.interrupted;
    return showing(s) && !s.dialog;
  }, done: (g) {
    final s = ClaudeScreen.read(g);
    return !showing(s) || s.interrupted != at;
  });
}

/// Claude's live state between the list and the composer: streaming rows, working line, limit, queue, statusline.
class BottomStack extends StatefulWidget {
  const BottomStack(
      {super.key,
      required this.screen,
      required this.grid,
      required this.feed,
      required this.gate,
      required this.stale,
      required this.remote,
      this.checks = _checks});

  final ClaudeScreen? screen;
  final Grid? grid;
  final TranscriptFeed feed;
  final WriteGate gate;
  final bool stale, remote;
  final Checks checks;

  @override
  State<BottomStack> createState() => _BottomStackState();
}

class _BottomStackState extends State<BottomStack> {
  List<VtRow> _status = const [];
  bool _colours = true, _expanded = false;
  String? _running; // the label of the button whose sequence the gate runs

  Future<void> _run(String label, int total, Future<void> Function(GateSequence s) body) async {
    setState(() => _running = label);
    final r = await widget.gate.run(total, body);
    if (!mounted) return;
    setState(() => _running = null);
    if (!r.ok) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(r.reason)));
  }

  Widget _button(String label, VoidCallback? onPressed) => FilledButton.tonal(
        style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 12), minimumSize: const Size(0, 32)),
        onPressed: widget.gate.running ? null : onPressed,
        child: Text(_running == label ? widget.gate.progress : label),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([widget.feed, widget.gate]),
        builder: (context, _) {
          final s = widget.screen, g = widget.grid;
          if (s == null || g == null) return const SizedBox.shrink();
          if (!s.dialog) {
            _status = [for (final r in s.statusRows) g.rows[r]];
            _colours = g.colours;
          }
          final live = !widget.stale;
          return Opacity(
            opacity: live ? 1 : 0.45,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _streaming(s, g),
              if (s.busy || s.working != null) _working(s, live),
              if (s.limit case final l?) _limit(s, l, live),
              ..._queued(s, live),
              if (_status.isNotEmpty) _statusline(s),
            ]),
          );
        },
      );

  Widget _streaming(ClaudeScreen s, Grid g) {
    final lines = switch (s.streaming) {
      (final a, final b) => [for (var r = a; r <= b; r++) g.text(r).trimRight()],
      null => const <String>[],
    };
    if (lines.isNotEmpty) lines[0] = lines[0].replaceFirst(RegExp(r'^⏺\s*'), '');
    final last = widget.feed.items.where((i) => i.kind == 'text').lastOrNull?.text ?? '';
    final show = s.busy &&
        lines.isNotEmpty &&
        !widget.stale &&
        !widget.feed.loading &&
        !_key(last).startsWith(_key(lines[0]));
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: show
          ? Padding(
              key: const ValueKey('streaming'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(withGridGlyphs(lines.join('\n')), style: const TextStyle(color: C.muted)),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _working(ClaudeScreen s, bool live) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(spacing: 8, children: [
          SizedBox.square(
              dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, value: live ? null : 0.25, color: C.accent)),
          Expanded(
              child: Text(s.working ?? 'Working…', style: _small, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false)),
          _button('Stop', live && s.busy && !s.dialog ? () => _run('Stop', 1, (q) => q.send(_esc((s) => s.busy))) : null),
        ]),
      );

  Widget _limit(ClaudeScreen s, String text, bool live) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        decoration: BoxDecoration(color: C.blockedBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.blockedLine)),
        child: Row(spacing: 8, children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: C.blockedText))),
          _button('Cancel', live && !s.dialog ? () => _run('Cancel', 1, (q) => q.send(_esc((s) => s.limit != null))) : null),
        ]),
      );

  List<Widget> _queued(ClaudeScreen s, bool live) {
    final shown = {for (final q in s.queued) norm(q)};
    final rows = [for (final q in widget.feed.meta?.queued ?? const <String>[]) if (shown.contains(norm(q))) q];
    final c = widget.checks;
    final blocked = c.writeBlockedOn(remote: widget.remote);
    return [
      for (final q in rows)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
          child: Row(spacing: 8, children: [
            const Icon(Icons.schedule, size: 14, color: C.dim),
            Expanded(child: Text(q, style: const TextStyle(color: C.dim), maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (c.sendNow)
              Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                _button('Send now', live && blocked == null && !s.dialog ? () => _run('Send now', 2, (g) => _sendNow(g, q)) : null),
                if (blocked != null) Text(blocked, style: const TextStyle(fontSize: 11, color: C.dim)),
              ]),
          ]),
        ),
    ];
  }

  Future<void> _sendNow(GateSequence q, String prompt) async {
    bool queued(ClaudeScreen s) => s.queued.any((x) => norm(x) == norm(prompt));
    String? before;
    String all(Grid g) => [for (var r = 0; r < g.rows.length; r++) g.text(r)].join('\n');
    // shortcut: check 12 has not run, so Ctrl+X ends on any screen change; set it from the check once it does
    await q.send(GateStep(KeyWrite(VtKey.x, vtCtrl), ready: (g) {
      before = all(g);
      final s = ClaudeScreen.read(g);
      return !s.dialog && queued(s);
    }, done: (g) => all(g) != before));
    await q.send(GateStep(KeyWrite(VtKey.s, vtCtrl), ready: (g) => !ClaudeScreen.read(g).dialog, done: (g) => !queued(ClaudeScreen.read(g))));
  }

  Widget _statusline(ClaudeScreen s) {
    final hidden = s.dialog; // a dialog covers them: the last seen rows, dimmed
    Widget row(VtRow r) => Text.rich(_colours ? _spans(r) : TextSpan(text: r.text.trim()),
        style: _mono, maxLines: _expanded ? null : 1, softWrap: _expanded, overflow: _expanded ? null : TextOverflow.ellipsis);
    return GestureDetector(
      key: const Key('statusline'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Opacity(
        opacity: hidden ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final r in _expanded ? _status : _status.take(1)) row(r)])),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: C.dim),
          ]),
        ),
      ),
    );
  }

  static TextSpan _spans(VtRow r) {
    final spans = <TextSpan>[];
    final cells = r.cells.where((c) => !c.spacer).toList();
    var end = cells.length;
    while (end > 0 && cells[end - 1].text.trim().isEmpty) {
      end--;
    }
    for (var i = 0; i < end;) {
      final c = cells[i];
      final b = StringBuffer();
      while (i < end && cells[i].fg == c.fg && cells[i].flags == c.flags) {
        b.write(cells[i].text.isEmpty ? ' ' : cells[i].text);
        i++;
      }
      spans.add(TextSpan(
        text: b.toString().replaceAll(' ', ' '),
        style: TextStyle(
          color: (c.fg == null ? _mono.color! : Color(c.fg!)).withValues(alpha: c.faint ? 0.6 : 1),
          fontWeight: c.bold ? FontWeight.w700 : null,
          fontStyle: c.italic ? FontStyle.italic : null,
        ),
      ));
    }
    return TextSpan(children: spans);
  }
}
