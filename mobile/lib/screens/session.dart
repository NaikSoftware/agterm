import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../client.dart';
import '../model.dart';
import '../theme.dart';
import 'actions.dart';
import 'home.dart' show StatusChip;
import 'prompt.dart';

// what each key-bar key types into the pane: xterm sequences, as Konsole sends them
const keys = [
  ('esc', '\x1b', 'Escape'),
  ('tab', '\t', 'Tab'),
  ('⇧tab', '\x1b[Z', 'Shift Tab'),
  ('^C', '\x03', 'Control C'),
  ('↑', '\x1b[A', 'Up'),
  ('↓', '\x1b[B', 'Down'),
  ('←', '\x1b[D', 'Left'),
  ('→', '\x1b[C', 'Right'),
  ('⏎', '\r', 'Enter'),
  ('^D', '\x04', 'Control D'),
  ('^L', '\x0c', 'Control L'),
  ('^R', '\x12', 'Control R'),
  ('^Z', '\x1a', 'Control Z'),
  ('^U', '\x15', 'Control U'),
  ('home', '\x1b[H', 'Home'),
  ('end', '\x1b[F', 'End'),
  ('pgup', '\x1b[5~', 'Page up'),
  ('pgdn', '\x1b[6~', 'Page down'),
];

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.model, required this.sessionId});
  final AgtermModel model;
  final String sessionId;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final vScroll = ScrollController();
  String pane = 'left';
  bool scrollback = false, sending = false;
  String text = '';
  String? error;
  bool fitting = false;
  Timer? poll;
  double _dragRows = 0; // a drag's distance in rows not sent yet
  bool _scrolling = false;
  bool polling = false;

  AgtermModel get m => widget.model;
  Session? get s => m.session(widget.sessionId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load()); // _load asks the route, which initState may not
    // shortcut: polls the plain-text screen; a streamed, coloured terminal needs a pty tap in agterm-qt
    poll = Timer.periodic(const Duration(milliseconds: 700), (_) => _load());
    m.addListener(_onModel);
    _visit();
  }

  // a visit as on the computer: an auto-reset status (an agent's Done) clears on the way in and on the way out
  void _visit() => unawaited(m.act('session.seen', target: widget.sessionId));

  @override
  void dispose() {
    poll?.cancel();
    m.removeListener(_onModel);
    _visit();
    input.dispose();
    inputFocus.dispose();
    vScroll.dispose();
    super.dispose();
  }

  void _onModel() {
    if (!mounted) return;
    if (m.loaded && s == null) {
      Navigator.of(context).maybePop(); // closed on the computer
      return;
    }
    if (pane == 'right' && s?.hasSplit != true) pane = 'left';
    setState(() {});
  }

  Future<void> _load() async {
    if (polling || m.state != LinkState.connected || m.background || ModalRoute.of(context)?.isCurrent != true) return;
    polling = true;
    try {
      // fitted, the grid has more rows than the computer's view shows; reading the last ones gets all of them
      final rows = scrollback ? 2000 : m.fitted[_fitKey]?.$2 ?? 0;
      final r = await m.call('session.text', target: widget.sessionId, args: {'pane': pane, if (rows > 0) 'lines': rows});
      final t = _trimEnd('${r['text'] ?? ''}');
      final columns = (r['columns'] as num?)?.toInt();
      // the computer took the grid back (Restore Terminal Size, or its window resized): no longer fitted
      final lost = columns != null && m.fitted[_fitKey] != null && m.fitted[_fitKey]!.$1 != columns;
      if (lost) m.fitted.remove(_fitKey);
      // a new grid width resizes the text even when the screen's text is the same (an idle shell)
      if (mounted && (t != text || error != null || columns != _columns || lost)) setState(() => (text = t, error = null, _columns = columns));
      if (s != null && s!.unseen > 0) unawaited(m.act('session.seen', target: widget.sessionId));
    } on AgtermError catch (e) {
      if (mounted) setState(() => error = e.message);
    } on TimeoutException {
      // keep the last screen
    } finally {
      polling = false;
    }
  }

  // "Fit to phone": the program's grid becomes what this screen shows at a readable size (session grid), apart from the
  // computer's view, so it redraws for the phone; the button then gives the grid back to the computer's view
  static const readable = 12.0;
  String get _fitKey => '${widget.sessionId}/$pane';
  int _fitColumns() => max(20, (_width / _advance(MediaQuery.textScalerOf(context).scale(readable))).floor());

  // one column's width at this size as the engine lays it out: glyph advances snap to device pixels, so 0.6 em is not
  // exact and a full row could wrap
  static double _advance(double size) {
    final tp = TextPainter(
        text: TextSpan(text: 'M' * 100, style: TextStyle(fontFamily: mono, fontSize: size)), textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling)
      ..layout();
    return tp.width / 100;
  }

  // the largest size, from `top` down, at which `cols` columns fit the width; half a column spare for the caret
  // SelectableText keeps at the line's end
  double _sizeFor(int cols, double top) {
    var size = top;
    while (size > 2 && _advance(size) * (cols + 0.5) > _width) {
      size -= 0.1;
    }
    return size;
  }

  Future<void> toggleFit() async {
    setState(() => fitting = true);
    final key = _fitKey;
    try {
      if (m.fitted.containsKey(key)) {
        await m.call('session.grid', target: widget.sessionId, args: {'pane': pane, 'reset': true});
        m.fitted.remove(key);
      } else {
        // JetBrains Mono advances 0.6 em; a larger system font size asks for fewer, bigger columns
        final columns = _fitColumns();
        final size = _sizeFor(columns, 13);
        final rows = max(5, (_height / (size * 1.3)).floor()); // the text's line height is 1.3
        await m.call('session.grid', target: widget.sessionId, args: {'pane': pane, 'columns': columns, 'rows': rows});
        m.fitted[key] = (columns, rows);
      }
    } on AgtermError catch (e) {
      if (mounted) report(context, e.message);
    } on TimeoutException {
      if (mounted) report(context, 'The computer did not answer.');
    }
    if (!mounted) return;
    setState(() => fitting = false);
    Future.delayed(const Duration(milliseconds: 300), _load); // the program redraws at its new width
  }

  String _trimEnd(String t) => t.split('\n').map((l) => l.trimRight()).join('\n').replaceFirst(RegExp(r'\n+$'), '');

  Future<void> type(String keys) async {
    HapticFeedback.selectionClick();
    final err = await m.act('session.type', target: widget.sessionId, args: {'text': keys, 'pane': pane});
    if (mounted) report(context, err);
    Future.delayed(const Duration(milliseconds: 150), _load);
  }

  Future<void> sendInput() async {
    final t = input.text;
    if (t.isEmpty) return type('\r');
    setState(() => sending = true);
    // the text, then the Enter on its own: Claude Code reads a pasted "...\r" as one paste, not a submit
    final err = await m.act('session.type', target: widget.sessionId, args: {'text': t, 'pane': pane}) ??
        await m.act('session.type', target: widget.sessionId, args: {'text': '\r', 'pane': pane});
    if (!mounted) return;
    setState(() => sending = false);
    report(context, err);
    if (err == null) input.clear();
    Future.delayed(const Duration(milliseconds: 200), _load);
  }

  @override
  Widget build(BuildContext context) {
    final s = this.s;
    if (s == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final options = promptOptions(text);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text([s.shortCwd, if (s.agent.isNotEmpty) s.agent].join(' · '),
              style: const TextStyle(fontSize: 12, color: C.muted, fontFamily: mono), overflow: TextOverflow.ellipsis),
        ]),
        actions: [
          if (m.state == LinkState.connected && m.via.isNotEmpty)
            Container(
              key: const Key('via'),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(6)),
              child: Text(m.via, style: const TextStyle(fontSize: 11, color: C.muted, fontWeight: FontWeight.w600)),
            ),
          StatusChip(s.status, blink: s.blink),
          IconButton(
            key: const Key('sessionMenu'),
            tooltip: 'Session actions',
            icon: const Icon(Icons.more_vert),
            onPressed: () => showSessionActions(context, m, s, onClosed: () => Navigator.of(context).maybePop()),
          ),
        ],
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1), child: Divider()),
      ),
      body: SafeArea(
        child: Column(children: [
          // the buttons float over the screen's top edge, so the terminal takes the whole height
          Expanded(child: Stack(children: [Positioned.fill(child: _terminal()), Positioned(top: 14, right: 18, child: _toolbar(s))])),
          if (options.isNotEmpty) _answers(options),
          _keyBar(),
          _composer(),
        ]),
      ),
    );
  }

  Widget _toolbar(Session s) {
    Widget seg(String label, bool on, VoidCallback onTap, {Key? key}) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: OutlinedButton(
            key: key,
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: (on ? C.surface2 : C.surface).withValues(alpha: 0.92),
              foregroundColor: on ? C.text : C.muted,
              side: BorderSide(color: on ? C.line : C.surface2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w600 : null)),
          ),
        );
    void setPane(String p) {
      setState(() {
        pane = p;
        text = '';
      });
      _load();
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
        if (s.hasSplit) ...[
          seg('Left pane', pane == 'left', () => setPane('left')),
          seg('Right pane', pane == 'right', () => setPane('right'), key: const Key('rightPane')),
        ],
        seg('Scrollback', scrollback, () {
          setState(() => scrollback = !scrollback);
          _load();
        }, key: const Key('scrollback')),
        seg(m.fitted.containsKey(_fitKey) ? 'Restore PC size' : 'Fit to phone', m.fitted.containsKey(_fitKey), fitting ? () {} : toggleFit,
            key: const Key('fitPhone')),
    ]);
  }

  double _fit = 11, _width = 360, _height = 600;
  int? _columns; // the computer's grid width, from session.text; older agterm-qt sends none

  // fitted, the phone shows the program's whole grid, so a drag scrolls the program itself: it reaches the computer as
  // wheel notches (session scroll), which a TUI such as Claude Code reads as its own scrolling
  bool get _remoteScroll => !scrollback && m.fitted.containsKey(_fitKey);

  void _drag(DragUpdateDetails d) {
    _dragRows += d.delta.dy / (_fit * 1.3);
    if (!_scrolling) _sendScroll();
  }

  Future<void> _sendScroll() async {
    final rows = _dragRows.truncate(); // dragging down shows older rows: up in the terminal
    if (rows == 0) return;
    _dragRows -= rows;
    _scrolling = true;
    final err = await m.act('session.scroll', target: widget.sessionId, args: {'pane': pane, 'lines': -rows});
    _scrolling = false;
    if (!mounted) return;
    if (err != null) return report(context, err);
    unawaited(_load());
    _sendScroll(); // what the finger moved meanwhile
  }

  Widget _terminal() => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        decoration: BoxDecoration(color: C.term, border: Border.all(color: const Color(0xFF1A1C24)), borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (context, box) {
          // the computer's own grid width, so a full-width row fills one phone row exactly; history written at a wider
          // size (before Fit to phone) wraps rather than shrinking everything
          final cols = max(20, _columns ?? text.split('\n').fold<int>(20, (a, l) => max(a, l.runes.length)));
          // JetBrains Mono advances 0.6 em
          _width = box.maxWidth - 24;
          _height = box.maxHeight - 24;
          // tiny when the computer's grid is wide, but whole rows, so the layout stays the program's (Fit to phone reads it)
          _fit = _sizeFor(cols, min(13, _width / (cols * 0.6)));
          final size = _fit;
          final body = SelectableText(
            error != null && text.isEmpty ? error! : withGridGlyphs(text),
            key: const Key('screen'),
            // the size above is already the one whose rows fit; Android's font scale on top would wrap every full row
            textScaler: TextScaler.noScaling,
            // letterSpacing 0: the theme's body text adds 0.25 per glyph, which would wrap every full row
            style: TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: size, height: 1.3, letterSpacing: 0, color: error != null && text.isEmpty ? C.danger : C.termText),
          );
          final view = SingleChildScrollView(
            controller: vScroll,
            reverse: true, // the newest rows stay in view
            physics: _remoteScroll ? const NeverScrollableScrollPhysics() : null,
            padding: const EdgeInsets.all(12),
            child: SizedBox(width: double.infinity, child: body),
          );
          return _remoteScroll ? GestureDetector(onVerticalDragUpdate: _drag, child: view) : view;
        }),
      );

  Widget _answers(List<PromptOption> options) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Row(children: [
          for (final (i, o) in options.take(4).indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: o.label,
                child: SizedBox(
                  height: 40,
                  child: i == 0
                      ? FilledButton(
                          key: Key('answer-${o.key}'),
                          onPressed: () => type(o.key),
                          style: FilledButton.styleFrom(
                              backgroundColor: C.blocked,
                              foregroundColor: const Color(0xFF1A1206),
                              minimumSize: const Size(0, 40),
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                          child: Text(options.length > 2 ? o.key : '${o.key} · ${o.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        )
                      : OutlinedButton(
                          key: Key('answer-${o.key}'),
                          onPressed: () => type(o.key),
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), padding: EdgeInsets.zero),
                          child: Text(options.length > 2 ? o.key : '${o.key} · ${o.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                ),
              ),
            ),
          ],
        ]),
      );

  Widget _keyBar() => SizedBox(
        height: 52,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          scrollDirection: Axis.horizontal,
          itemCount: keys.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) {
            final (label, seq, name) = keys[i];
            return Semantics(
              label: name,
              button: true,
              excludeSemantics: true,
              child: OutlinedButton(
                key: Key('key-$name'),
                onPressed: () => type(seq),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: label == '⏎' ? C.accent : C.text,
                  backgroundColor: label == '⏎' ? C.surface2 : C.surface,
                ),
                child: Text(label, style: const TextStyle(fontFamily: mono, fontSize: 13)),
              ),
            );
          },
        ),
      );

  Widget _composer() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('composer'),
              controller: input,
              focusNode: inputFocus,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => sendInput(),
              autocorrect: false,
              style: const TextStyle(fontFamily: mono, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Type, then send with Enter',
                fillColor: C.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 48,
            height: 48,
            child: FilledButton(
              key: const Key('send'),
              onPressed: sending ? null : sendInput,
              style: FilledButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: const Icon(Icons.arrow_forward, semanticLabel: 'Send'),
            ),
          ),
        ]),
      );
}
