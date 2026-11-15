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
  }

  @override
  void dispose() {
    poll?.cancel();
    m.removeListener(_onModel);
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
      final r = await m.call('session.text', target: widget.sessionId, args: {'pane': pane, if (scrollback) 'lines': 2000});
      final t = _trimEnd('${r['text'] ?? ''}');
      if (mounted && (t != text || error != null)) setState(() => (text = t, error = null));
      if (s != null && s!.unseen > 0) unawaited(m.act('session.seen', target: widget.sessionId));
    } on AgtermError catch (e) {
      if (mounted) setState(() => error = e.message);
    } on TimeoutException {
      // keep the last screen
    } finally {
      polling = false;
    }
  }

  // "Fit to phone": the computer's pane zooms until it is as narrow as this screen shows at a readable size, so the
  // program redraws at that width and nothing wraps; the button then puts back the size it had (0 = its default)
  static const readable = 12.0;
  String get _fitKey => '${widget.sessionId}/$pane';

  Future<void> toggleFit() async {
    setState(() => fitting = true);
    final key = _fitKey;
    try {
      if (m.fitted.containsKey(key)) {
        await m.call('font.set', target: widget.sessionId, args: {'pane': pane, 'size': m.fitted[key]});
        m.fitted.remove(key);
      } else {
        final columns = max(20, (_width / (readable * 0.6)).floor()); // JetBrains Mono advances 0.6 em
        final r = await m.call('font.fit', target: widget.sessionId, args: {'pane': pane, 'columns': columns});
        m.fitted[key] = (r['previousFontSize'] as num?)?.toDouble() ?? 0;
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

  double _fit = 11, _width = 360;

  Widget _terminal() => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        decoration: BoxDecoration(color: C.term, border: Border.all(color: const Color(0xFF1A1C24)), borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (context, box) {
          final cols = text.split('\n').fold<int>(20, (a, l) => max(a, l.runes.length));
          // JetBrains Mono advances 0.6 em
          _width = box.maxWidth - 24;
          _fit = (_width / (cols * 0.6)).clamp(5.5, 13).toDouble();
          final size = _fit;
          final body = SelectableText(
            error != null && text.isEmpty ? error! : withGridGlyphs(text),
            key: const Key('screen'),
            style: TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: size, height: 1.3, color: error != null && text.isEmpty ? C.danger : C.termText),
          );
          return SingleChildScrollView(
            controller: vScroll,
            reverse: true, // the newest rows stay in view
            padding: const EdgeInsets.all(12),
            child: SizedBox(width: double.infinity, child: body),
          );
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
