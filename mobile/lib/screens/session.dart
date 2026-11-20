import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show kDoubleTapSlop, kDoubleTapTimeout, kLongPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_composer.dart';
import '../chat/chat_view.dart';
import '../chat/checks.dart';
import '../chat/claude_screen.dart';
import '../chat/feed.dart';
import '../chat/grid.dart';
import '../chat/mode.dart';
import '../chat/prompt_ledger.dart';
import '../chat/transcript.dart';
import '../chat/write_gate.dart';
import '../client.dart';
import '../model.dart';
import '../terminal/key_bar.dart';
import '../terminal/row_cache.dart';
import '../terminal/term_gestures.dart';
import '../terminal/term_keyboard.dart';
import '../terminal/term_session.dart';
import '../terminal/terminal_view.dart';
import '../terminal/vt.dart';
import '../theme.dart';
import 'actions.dart';
import 'answer_bar.dart';
import 'composer.dart';
import 'prompt.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.model, required this.sessionId, @visibleForTesting this.vt = openVt, @visibleForTesting this.onKeyboard});
  final ElisModel model;
  final String sessionId;
  final Vt Function(int cols, int rows) vt;
  final VoidCallback? onKeyboard; // told each time a tap asks for the soft keyboard

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final _keyboard = FocusNode(); // the hidden field typing goes through
  // the history's text never takes the focus: a tap on it would close the keyboard; its selection works without
  final _textFocus = FocusNode(canRequestFocus: false);
  final vScroll = ScrollController();
  String pane = 'left';
  bool scrollback = false, sending = false;
  bool? _alt; // the screen the last frame showed; scrollback follows each switch
  String text = '';
  String? error;
  Future<void>? _fitCall; // the fit call in flight and the re-runs it chains
  final autoFit = AutoFit();
  bool _foreground = true;
  late final AppLifecycleListener _lifecycle;
  Timer? poll;
  double _dragRows = 0; // a drag's distance in rows not sent yet
  Offset _finger = Offset.zero; // where the finger is on screen; [_cellUnder] maps it onto the grid, zoom and pan undone
  bool _stale = false; // the finger that was down when the Mac took the lead back: its drag claims nothing
  final _grid = GlobalKey();
  final _text = GlobalKey(); // the history's text
  final _answersBox = GlobalKey(), _composerBox = GlobalKey();
  double? _composerLine; // the composer's height at one line
  bool _answersShown = false; // a removed row's key still finds its inactive element during the layout
  late CellMetrics _cell; // the Term view's, as last laid out
  bool _scrolling = false;
  bool polling = false;
  TermSession? term; // a Live pane watched as a terminal; the text poll stops meanwhile
  TermSession? _claimed; // the term the lead was asked on: a replaced term (pause, pane, reconnect) is not claimed
  final _noClaim = <String>{}; // panes whose claim was refused on this visit: they type indirectly
  bool _macTookBack = false; // a term opened since claims on the next input, not at once
  TermSession? _openClaim; // the term whose OPENED was answered with a claim, once per term
  TermSession? _quiet; // claimed on OPENED with no input since: a refusal is said at the pane's first input
  final _unsaid = <String, String>{};
  Future<void>? _replay; // a refused claim's input on its way through session.type; later input waits for it
  (int, int)? _leadGrid, _seenGrid; // the grid the lead was given, and the one the screen shows now
  Timer? _leadResize;
  // the relay gives the lead back to the Mac only once the claiming attach exits, so a fit right after the phone's own
  // lead ends can be refused as covered: that many refusals retry quietly, [_fitRetry] apart
  int _coveredTries = 0;
  int? _resetTries; // after a refused reset, the retries left
  Timer? _fitRetry;
  bool _quietFit = false; // the refit after a refused claim: a refusal of it repeats the claim's, already said
  final _refused = <String>{}; // panes whose terminal the relay refused on this visit: text view until they stop being Live
  final _closedRecently = <String, Timer>{}; // a pane's channel closed mid-stream: a second close soon falls back to text
  final _openedPanes = <String>{}; // panes whose terminal was OPENED on this visit: before that Chat is connecting, not stale
  // latched, not shownMode on each build: Chat stays when Claude exits, until the user leaves it
  bool _inChat = false;
  bool _picked = false; // the opening pane and mode, picked once the session is known
  TranscriptFeed? _feed;
  PromptLedger? _ledger;
  final _grids = ValueNotifier(0); // bumped whenever the grid Chat reads may have changed
  late final WriteGate _gate;
  final _composer = GlobalKey<ChatComposerState>();
  Future<void>? _taking; // the claim [_takeOver] is making
  StreamSubscription<Map<String, dynamic>>? _events;
  String? _agentSessionId;

  ElisModel get m => widget.model;
  Session? get s => m.session(widget.sessionId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load()); // _load asks the route, which initState may not
    // shortcut: polls the plain-text screen; a streamed, coloured terminal needs a pty tap in elis
    poll = Timer.periodic(const Duration(milliseconds: 700), (_) => _load());
    m.addListener(_onModel);
    _lifecycle = AppLifecycleListener(onPause: () => _setForeground(false), onResume: () => _setForeground(true));
    _gate = WriteGate(
        grids: _grids, grid: _chatGrid, writer: _writer, remote: () => s?.remote ?? false, blocked: () => _chatBlocked ?? checks.writeBlockedOn(remote: s?.remote ?? false));
    _events = m.events.listen((e) {
      if (e['kind'] == 'status' && e['session'] == widget.sessionId) _feed?.pollNow();
    });
    _pickStart();
    _syncTerm();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncFit(); // the first layout gives the screen's size
      _syncFeed(); // canPoll asks the route, which initState may not
    });
    _visit();
  }

  void _setForeground(bool on) {
    _foreground = on;
    _syncTerm();
    _syncFit();
    _syncFeed();
  }

  /// Opens on the agent's pane when Chat shows there, else on the left pane.
  void _pickStart() {
    final s = this.s;
    if (_picked || s == null) return;
    _picked = true;
    _agentSessionId = s.agentSessionId;
    if (shownMode(s, s.agentPane) != ViewMode.chat) return;
    pane = s.agentPane;
    _inChat = true;
  }

  TranscriptFeed get _chatFeed => _feed ??= TranscriptFeed(
      call: (args) => m.call('session.transcript', target: widget.sessionId, args: {...args, 'pane': s?.agentPane ?? pane}),
      canPoll: () => mounted && _foreground && !m.background && m.state == LinkState.connected && ModalRoute.of(context)?.isCurrent == true,
      remote: s?.remote ?? false)
    ..addListener(_onFeed);

  PromptLedger get _prompts => _ledger ??= PromptLedger(grids: _grids, grid: _chatGrid, feed: _chatFeed, blocked: () => _chatBlocked);

  void _syncFeed() {
    if (!mounted) return;
    if (_inChat && _foreground) return _chatFeed.start();
    _feed?.stop();
  }

  void _onFeed() {
    if (_feed?.error != TranscriptError.hostTooOld || !ModePicks.tooOld.add(widget.sessionId)) return;
    _syncMode();
    if (s case final s?) report(context, _tooOld(s));
  }

  String _tooOld(Session s) => 'Update Elis on ${s.remoteHost.isEmpty ? 'the computer' : s.remoteHost}';

  bool _exited(Session s) => s.liveAgent != 'claude';

  // a Live pane that showed its terminal this visit and has no running one now
  bool get _termLost =>
      _openedPanes.contains(pane) && s?.livePanes.contains(pane) == true && !_refused.contains(pane) && term?.opened != true;

  bool get _chatStale => _feed?.stale == true || m.state != LinkState.connected || _termLost;

  String? get _chatBlocked => switch (s) {
        final s? => ChatView.blockedReason(exited: _exited(s), stale: _chatStale),
        null => null,
      };

  void _pickMode(ViewMode mode) {
    ModePicks.pick(widget.sessionId, mode);
    _syncMode();
  }

  void _syncMode() {
    if (s case final s?) _setMode(shownMode(s, pane) == ViewMode.chat);
  }

  void _setMode(bool chat) {
    if (chat == _inChat) return;
    setState(() => _inChat = chat);
    _syncFeed();
    if (chat) return;
    // Term's fit, claim and resize, once Term has laid out: the phone grid reads its size
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _inChat) return;
      unawaited(_syncFit());
      _onTerm();
      unawaited(_load());
    });
  }

  bool get _chatIdle => _chatBlocked == null && _chatGrid() != null && ClaudeScreen.read(_chatGrid()!).idle;

  Grid? _chatGrid() {
    if (term case final t?) return t.frame == null ? null : Grid.of(t.frame!);
    return text.isEmpty ? null : Grid.text(text);
  }

  GateWriter _writer() => _PaneWriter(
      () => _direct,
      LeadWriter(() => term, _gateClaim),
      TypeWriter((text) async {
        await _replay;
        return m.act('session.type', target: widget.sessionId, args: {'text': text, 'pane': pane});
      }));

  // false as soon as the claim is refused, so the gate does not wait out the lead's deadline
  Future<bool> _gateClaim() async {
    if (!mounted) return false; // a gate run can outlive the screen
    _claim();
    final t = _claimed;
    await _taking;
    return t != null && _claimed == t;
  }

  // a visit as on the computer: an auto-reset status (an agent's Done) clears on the way in and on the way out
  void _visit() => unawaited(m.act('session.seen', target: widget.sessionId));

  @override
  void dispose() {
    poll?.cancel();
    _leadResize?.cancel();
    _fitRetry?.cancel();
    term?.removeListener(_onTerm);
    term?.close();
    for (final t in _closedRecently.values) {
      t.cancel();
    }
    m.removeListener(_onModel);
    unawaited(_events?.cancel());
    _ledger?.dispose();
    _feed?.dispose();
    _gate.dispose();
    _grids.dispose();
    _lifecycle.dispose();
    _release(pane);
    _visit();
    input.dispose();
    inputFocus.dispose();
    _keyboard.dispose();
    _textFocus.dispose();
    vScroll.dispose();
    super.dispose();
  }

  void _onModel() {
    if (!mounted) return;
    if (m.loaded && s == null) {
      Navigator.of(context).maybePop(); // closed on the computer
      return;
    }
    _pickStart();
    _syncFeed(); // a session that loaded after initState may open in Chat
    if (s?.agentSessionId != _agentSessionId) {
      _agentSessionId = s?.agentSessionId;
      _feed?.pollNow();
    }
    if (pane == 'right' && s?.hasSplit != true) pane = 'left';
    _syncTerm(); // a reconnect brings a new mux; a pane can stop being Live
    setState(() {});
    _syncFit(); // a reconnect cleared the fits the computer gave back
  }

  /// Watch the pane as a terminal when it is Live, the relay has the mux and the screen is in front; else the text view.
  void _syncTerm() {
    _refused.removeWhere((p) => s?.livePanes.contains(p) != true); // a restarted session gets another try
    final want = _foreground &&
        !m.background &&
        m.state == LinkState.connected &&
        m.mux != null &&
        s?.livePanes.contains(pane) == true &&
        !_refused.contains(pane);
    final t = term;
    if (t != null && (!want || t.pane != pane || t.mux != m.mux)) {
      if (_lead) _coveredTries = 3;
      t.removeListener(_onTerm);
      t.close(); // CLOSE: the Mac's viewer count drops; a resume opens a fresh channel
      term = null;
      _alt = null; // the next stream picks the view again
    }
    if (want && term == null) term = TermSession(m.mux!, widget.sessionId, pane, vt: widget.vt)..addListener(_onTerm);
  }

  void _onTerm() {
    final t = term;
    if (!mounted || t == null) return;
    _grids.value++;
    if (t.opened) _openedPanes.add(t.pane);
    if (t.ended case final reason?) {
      t.removeListener(_onTerm);
      if (_claimed == t) _coveredTries = 3;
      term = null;
      _alt = null; // the next stream picks the view again
      _claimed = null;
      _typeAll(t.takeUnsent(), t.pane); // input queued for a lead that will not come: never lost silently
      if (reason == 'Disconnected' || reason == revokedMessage) {
        // the disconnected state shows; the next mux reopens
      } else if (!t.opened) {
        _refused.add(t.pane); // the relay's refusal is already readable: said once
        report(context, reason);
      } else if (_closedRecently[t.pane] == null) {
        // closed mid-stream (`stalled`, `pane moved`, `session ended`): open once more, quietly
        _closedRecently[t.pane] = Timer(const Duration(seconds: 10), () => _closedRecently.remove(t.pane));
        _syncTerm();
      } else {
        _refused.add(t.pane);
        report(context, 'The live terminal closed (${reason == 'stalled' ? 'the phone fell behind' : reason}). Showing the text view.');
      }
      unawaited(_load());
      unawaited(_syncFit());
    } else {
      // on OPENED, not before: the relay pins the claim to the pane the watch resolved
      if (!_inChat && t.opened && _openClaim != t) {
        _openClaim = t;
        if (!_macTookBack) _claim(open: true);
      }
      if (t.leadLost case final r? when _claimed == t) {
        _claimed = null;
        if (r != 'Disconnected' && r != revokedMessage && r.isNotEmpty) {
          autoFit.wanted = false; // the Mac took control: refitting would resize its terminal under its user
          _macTookBack = true;
          _stale = true;
          report(context, '${r[0].toUpperCase()}${r.substring(1)}${r.endsWith('.') ? '' : '.'}');
        } else {
          _coveredTries = 3;
        }
        unawaited(_syncFit());
      }
      if (t.inputLost case final lost?) report(context, lost);
      if (_leadResize?.isActive != true) _resizeLead(); // the screen changed while the claim waited for its LEAD
      if (text.isNotEmpty && _termShown && t.snapshot!.altScreen) {
        text = ''; // shown from now on; a fallback later starts from a fresh read, not this one
      }
    }
    setState(() {});
  }

  // asked for, the lead is pending (the relay can wait 10 s for zmx) or held; input goes to it only once [leading]
  bool get _lead => _claimed != null && _claimed == term;
  bool get _leading => _lead && term!.leading;
  // the lead, or one asked once the term opens: the claim brings the grid, so a fit would only be reset
  bool get _leadsGrid =>
      (term != null || m.mux == null && m.muxing && s?.livePanes.contains(pane) == true) && !_macTookBack && !_noClaim.contains(pane);

  // the program runs at what the screen shows at a readable size, as the fit sizes it
  (int, int) _phoneGrid() {
    final cols = _fitColumns();
    return (cols, max(1, (_fullHeight / CellMetrics.fit(_width, cols).h).floor()));
  }

  // the box's height without the soft keyboard, the answer row and the composer's extra lines, none of which resizes
  // the program: they cover its top rows. The keyboard also covers the bottom safe area the box leaves out without it
  double get _fullHeight {
    final q = MediaQuery.of(context);
    final composer = _seeComposer();
    final extra = composer > 0 ? composer - _composerLine! : 0;
    return _height + (_answersShown ? _heightOf(_answersBox) : 0) + extra + q.viewInsets.bottom - (q.viewPadding.bottom - q.padding.bottom);
  }

  static double _heightOf(GlobalKey k) => switch (k.currentContext?.findRenderObject()) {
        RenderBox b when b.hasSize => b.size.height,
        _ => 0,
      };

  /// The composer's height now, 0 before it is laid out; keeps its one-line height from the first layout on.
  double _seeComposer() {
    if (!ComposerPref.shown) return 0; // a removed composer's key still finds its inactive element during the layout
    final h = _heightOf(_composerBox);
    if (h > 0) _composerLine = min(_composerLine ?? h, h);
    return h;
  }

  bool get _direct => term != null && !_noClaim.contains(pane);

  /// Opening a Live pane, or input on it, asks for the lead; input queues on the term until it leads.
  void _claim({bool open = false}) {
    _macTookBack = false;
    if (!open) {
      _quiet = null;
      report(context, _unsaid.remove(pane));
    }
    final t = term;
    if (t == null || _lead || _noClaim.contains(pane)) return;
    t.leadLost = null; // a lead lost earlier was said then
    t.arm();
    if (open) _quiet = t;
    setState(() => _claimed = t);
    unawaited(_taking = _takeOver(t));
  }

  Future<void> _takeOver(TermSession t) async {
    bool mine() => mounted && _lead && _claimed == t; // a pause or pane switch meanwhile closed [t]: nothing to say
    await _replay; // a lead taken before the Mac typed the replay would have zmx drop it
    if (!mine()) return;
    final (int, int) g;
    if (_inChat && t.snapshot != null) {
      g = (t.snapshot!.cols, t.snapshot!.rows); // Chat keeps the grid it found, a Term fit included
    } else {
      // the computer's grid back first, after any fit in flight (auto-fit stands down while [_lead]): a session grid
      // would fight the phone's
      await _syncFit();
      if (!mine()) return;
      if (m.fitted.containsKey(_fitKey)) return _abandon(t, null); // the reset was refused, and said
      g = _seenGrid = _phoneGrid();
    }
    _leadGrid = g;
    final err = await t.takeOver(g.$1, g.$2);
    if (err != null && mine()) _abandon(t, err);
  }

  /// Types [unsent] through session.type one at a time, in order; later indirect input waits for it.
  void _typeAll(List<String> unsent, String pane) {
    if (unsent.isEmpty) return;
    final before = _replay;
    _replay = () async {
      await before;
      for (final text in unsent) {
        final e = await m.act('session.type', target: widget.sessionId, args: {'text': text, 'pane': pane});
        if (e != null) return mounted ? report(context, e) : null;
      }
    }();
  }

  /// The pane types indirectly for the rest of the visit; the input queued for the lead goes first, in order.
  void _abandon(TermSession t, String? err) {
    _noClaim.add(t.pane);
    setState(() => _claimed = null);
    _typeAll(t.takeUnsent(), t.pane);
    t.release();
    if (err == null) return; // a refused reset: a refit now would only be refused and said again
    if (_quiet == t) {
      _unsaid[t.pane] = err;
    } else {
      report(context, err);
    }
    _quietFit = true;
    unawaited(_syncFit());
  }

  // a layout change (a rotation, not the keyboard) resizes the lead, or refits, once it settles
  void _layoutGrid() {
    if (_inChat) return;
    final g = _phoneGrid();
    if (g == _seenGrid) return;
    _seenGrid = g;
    _leadResize?.cancel();
    _leadResize = Timer(const Duration(milliseconds: 300), () => _lead ? _resizeLead() : unawaited(_syncFit()));
  }

  // only once leading: before that TermSession drops a resize while the claim waits for OPENED
  void _resizeLead() {
    final g = _seenGrid;
    if (_inChat || !_leading || g == null || g == _leadGrid) return;
    _leadGrid = g;
    term!.resizeLead(g.$1, g.$2);
  }

  // the text view stays until the terminal has a first frame: no blank screen while the channel opens
  bool get _termShown => !scrollback && term?.snapshot != null;

  // without a terminal stream there is no screen to follow: the history, always
  bool get _history => scrollback || term == null;

  // the main screen (a shell, a command printing lines) shows its history; a full-screen program shows Term.
  // Called from build, before anything reads [scrollback]: the frame that shows the switch already picks.
  void _pickView(VtSnapshot? snap) {
    if (snap == null || snap.altScreen == _alt) return;
    _alt = snap.altScreen;
    scrollback = !snap.altScreen;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    // a delayed read (after a fit, a key) can fire after the screen closed
    if (!mounted || polling || m.state != LinkState.connected || m.background || ModalRoute.of(context)?.isCurrent != true) return;
    if (_inChat ? term != null : _termShown) {
      if (s != null && s!.unseen > 0) unawaited(m.act('session.seen', target: widget.sessionId));
      return;
    }
    polling = true;
    try {
      // fitted, the grid has more rows than the computer's view shows; reading the last ones gets all of them
      final fit = m.fitted[_fitKey];
      final rows = _inChat ? 0 : _history ? 2000 : fit?.$2 ?? 0; // Chat reads the screen only
      final r = await m.call('session.text', target: widget.sessionId, args: {'pane': pane, if (rows > 0) 'lines': rows});
      final t = _trimEnd('${r['text'] ?? ''}');
      final columns = (r['columns'] as num?)?.toInt();
      // the computer took the grid back (Restore Terminal Size, or its window resized): no longer fitted. Only a fit
      // older than this read counts: one made while it was in flight would read as lost
      final lost = columns != null && fit != null && m.fitted[_fitKey] == fit && fit.$1 != columns;
      if (lost) {
        m.fitted.remove(_fitKey);
        autoFit.wanted = false; // the computer took the grid back: do not take it again on this visit
      }
      // a new grid width resizes the text even when the screen's text is the same (an idle shell)
      if (mounted && (t != text || error != null || columns != _columns || lost)) {
        setState(() => (text = t, error = null, _columns = columns));
        _grids.value++;
      }
      if (s != null && s!.unseen > 0) unawaited(m.act('session.seen', target: widget.sessionId));
    } on ElisError catch (e) {
      if (mounted) setState(() => error = e.message);
    } on TimeoutException {
      // keep the last screen
    } finally {
      polling = false;
    }
  }

  // the fit: while this screen shows the pane, the program's grid is what it shows at a readable size (session grid),
  // apart from the computer's view, so it redraws for the phone; leaving gives the grid back
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

  /// Fits or gives back the grid as [autoFit] says for the screen's state now; a change during a call runs after it,
  /// and a caller during a call gets that call with its re-runs.
  Future<void> _syncFit() {
    if (_fitCall case final f?) return f;
    final done = Completer<void>();
    _fitCall = done.future;
    () async {
      try {
        // the app paused, resumed or changed pane during a call; after a failure, the next change retries (a refused
        // reset keeps its record, so leaving still gives the grid back)
        while (await _fitOnce()) {}
      } finally {
        _fitCall = null;
        _quietFit = false;
        done.complete();
      }
    }();
    return done.future;
  }

  /// True when a call was made and succeeded.
  Future<bool> _fitOnce() async {
    if (!mounted || _inChat) return false; // Chat never resizes Claude
    final visible = _foreground && !m.background && m.state == LinkState.connected;
    final fit = m.fitted[_fitKey];
    // a fit at another grid than the screen's now (a rotation) is made again
    final on = autoFit.next(fitted: fit != null, visible: visible && !_leadsGrid) ??
        (fit != null && autoFit.wanted && visible && !_leadsGrid && fit != _phoneGrid() ? true : null);
    if (on == null || _fitRetry?.isActive == true || !on && _resetTries == 0) return false;
    final key = _fitKey;
    final quiet = on && _quietFit;
    if (on) _quietFit = false;
    var ok = false;
    try {
      if (on) {
        final (columns, rows) = _phoneGrid(); // the lead's grid, so a claim changes nothing the program shows
        await m.call('session.grid', target: widget.sessionId, args: {'pane': pane, 'columns': columns, 'rows': rows});
        _coveredTries = 0;
        m.fitted[key] = (columns, rows);
        if (term case final t? when '${widget.sessionId}/${t.pane}' == key) t.fitted(columns, rows); // not a pane switched to meanwhile
      } else {
        await m.call('session.grid', target: widget.sessionId, args: {'pane': pane, 'reset': true});
        _resetTries = null;
        m.fitted.remove(key);
      }
      ok = true;
    } on ElisError catch (e) {
      final first = _resetTries == null;
      if (quiet) {
        autoFit.wanted = false;
      } else if (on && _coveredTries > 0) {
        _coveredTries--; // covered just after the phone's own lead: quietly, and still wanted
        _fitRetry = Timer(const Duration(seconds: 1), _syncFit);
      } else {
        autoFit.wanted = false; // a refused fit (a pane another Mac leads) is not retried on every change
        if (!on) _resetTries = (_resetTries ?? 4) - 1; // a refused reset: said once, retried 3 times
        if (!on && _resetTries! > 0) _fitRetry = Timer(const Duration(seconds: 1), _syncFit);
        if (mounted && (on || first)) report(context, e.message);
      }
    } on TimeoutException {
      autoFit.wanted = false;
      if (mounted) report(context, 'The computer did not answer.');
    }
    // the screen closed or moved to the other pane during the call: that fit has no viewer any more
    if (!mounted || key != _fitKey) _release(key.split('/').last);
    if (!mounted) return false;
    setState(() {});
    Future.delayed(const Duration(milliseconds: 300), _load); // the program redraws at its new width
    return ok;
  }

  /// Gives back [p]'s grid without waiting: the screen is closing or moving to the other pane.
  void _release(String p) {
    if (m.fitted.remove('${widget.sessionId}/$p') == null) return;
    unawaited(m.call('session.grid', target: widget.sessionId, args: {'pane': p, 'reset': true}).then((_) {}, onError: (_) {}));
  }

  String _trimEnd(String t) => t.split('\n').map((l) => l.trimRight()).join('\n').replaceFirst(RegExp(r'\n+$'), '');

  static const _busy = 'The computer has not taken the earlier input yet.';

  // a direct send reads the history back as soon as the indirect path does
  void _sent(bool ok) {
    if (!ok) return report(context, _busy);
    Future.delayed(const Duration(milliseconds: 150), _load);
  }

  Future<void> type(String keys) async {
    HapticFeedback.selectionClick();
    _claim();
    if (_direct) return _sent(term!.text(keys));
    await _replay;
    final err = await m.act('session.type', target: widget.sessionId, args: {'text': keys, 'pane': pane});
    if (mounted) report(context, err);
    Future.delayed(const Duration(milliseconds: 150), _load);
  }

  void _press(String? seq, VtKey? key, int mods) {
    if (key == null || seq == null) return unawaited(_paste());
    _claim();
    if (!_direct) return unawaited(type(seq));
    HapticFeedback.selectionClick();
    _sent(term!.key(key, mods: mods, seq: seq));
  }

  Future<void> _paste() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (clip == null || clip.isEmpty || !mounted) return;
    _claim();
    if (!_direct) return type(clip);
    HapticFeedback.selectionClick();
    _sent(term!.paste(clip));
  }

  // the soft keyboard's input routes as the key bar's, without its haptic (the keyboard has its own); indirect, one
  // session.type at a time so the keystrokes keep their order
  void _softKey(VtKey key, int mods) {
    _claim();
    if (!_direct) return _typeSoft(xtermSeq(key, mods));
    _sent(term!.key(key, mods: mods, seq: xtermSeq(key, mods)));
  }

  void _softText(String text, {bool paste = false}) {
    _claim();
    if (!_direct) return _typeSoft(text);
    _sent(paste ? term!.paste(text) : term!.text(text));
  }

  void _typeSoft(String text) {
    _typeAll([text], pane);
    Future.delayed(const Duration(milliseconds: 150), _load);
  }

  Future<void> sendInput() async {
    final t = input.text;
    _claim();
    if (_direct) {
      final ok = term!.line(t);
      _sent(ok);
      if (ok) input.clear(); // refused, the composer keeps the text
      return;
    }
    if (t.isEmpty) return type('\r');
    setState(() => sending = true);
    await _replay;
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
    final t = term;
    _pickView(t?.frame); // a reset's main screen is not the program's
    final chat = _inChat;
    final options = chat ? const <PromptOption>[] : promptOptions(_termShown ? t!.snapshot!.lines.map((l) => l.text).join('\n') : text);
    _answersShown = options.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: chat
            ? ChatTitle(feed: _chatFeed, s: s)
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text([s.shortCwd, if (s.agent.isNotEmpty) s.agent].join(' · '),
              style: const TextStyle(fontSize: 12, color: C.muted, fontFamily: mono), overflow: TextOverflow.ellipsis),
        ]),
        actions: [
          if (_lead) _Tag(_leading ? 'Leading' : 'Leading…', key: const Key('lead')),
          if (m.state == LinkState.connected && m.via.isNotEmpty) _Tag(m.via, key: const Key('via')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Semantics(
                key: const Key('status'), label: statusLabel(s.status), child: StatusShape(s.status, size: 10, blink: s.blink)),
          ),
          IconButton(
            key: const Key('sessionMenu'),
            tooltip: 'Session actions',
            icon: const Icon(Icons.more_vert),
            onPressed: () => showSessionActions(context, m, s,
                onClosed: () => Navigator.of(context).maybePop(),
                onComposer: () => setState(() {}),
                autoMode: ModePicks.of(s.id) == null,
                onAutoMode: () {
                  ModePicks.pick(s.id, null);
                  _syncMode();
                }),
          ),
        ],
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1), child: Divider()),
      ),
      body: SafeArea(
        child: Column(children: [
          // the buttons float over the screen's top edge, so the terminal takes the whole height
          Expanded(
              child: Stack(children: [
            // Chat holds the toolbar in its header; over the terminal it floats
            Positioned.fill(child: chat ? _chatView(s) : _terminal()),
            if (!chat) ...[
              Positioned(left: 0, bottom: 0, child: TermKeyboard(focus: _keyboard, onKey: _softKey, onText: _softText, onPaste: (t) => _softText(t, paste: true))),
              Positioned(top: 6, right: 6, child: _toolbar(s)),
            ],
            if (m.state != LinkState.connected)
              Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                // why it cannot connect when known (a revoked pairing does not reconnect)
                child: Text(m.error ?? 'Disconnected. Reconnecting…',
                    key: const Key('disconnected'), textAlign: TextAlign.center, style: const TextStyle(color: C.danger, fontWeight: FontWeight.w600)),
              )),
          ])),
          if (options.isNotEmpty) AnswerBar(key: _answersBox, options: options, onAnswer: type),
          if (!chat) KeyBar(onKey: _press, onKeyboard: _toggleKeyboard),
          if (!chat && ComposerPref.shown) Composer(key: _composerBox, controller: input, focus: inputFocus, onSend: sending ? null : sendInput),
        ]),
      ),
    );
  }

  Widget _chatView(Session s) {
    final f = _chatFeed;
    return ListenableBuilder(
        listenable: f,
        builder: (context, _) => ChatView(
            feed: f,
            grid: _chatGrid,
            grids: _grids,
            gate: _gate,
            s: s,
            exited: _exited(s),
            stale: _chatStale,
            onTerm: () => _pickMode(ViewMode.term),
            switcher: _toolbar(s),
            model: ListenableBuilder(
                listenable: _grids,
                builder: (context, _) =>
                    ChatModelChip(feed: f, onChangeModel: _chatIdle ? () => _composer.currentState?.send('/model') : null)),
            composer: _composer,
            promptCard: promptCardBuilder(_prompts),
            prompts: _prompts,
            onKey: _press,
            onAnswer: type));
  }

  Widget _toolbar(Session s) {
    Widget seg(String label, bool on, VoidCallback? onTap, {Key? key}) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: OutlinedButton(
            key: key,
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: (on ? C.surface2 : C.surface).withValues(alpha: 0.92),
              foregroundColor: on ? C.text : C.muted,
              disabledForegroundColor: on ? C.muted : C.dim,
              side: BorderSide(color: on ? C.line : C.surface2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w600 : null)),
          ),
        );
    void setPane(String p) {
      if (p == pane) return;
      _release(pane);
      _macTookBack = false; // a switch claims
      setState(() {
        pane = p;
        text = '';
      });
      _syncMode(); // Chat shows only on the agent's pane
      _syncTerm(); // closes the other pane's channel, opens this one's when it is Live
      _load();
      _syncFit();
    }
    return Row(key: const Key('toolbar'), mainAxisSize: MainAxisSize.min, children: [
      if (ModePicks.tooOld.contains(s.id))
        Tooltip(message: _tooOld(s), child: seg('Chat', false, null, key: const Key('modeChat')))
      else
        seg('Chat', _inChat, chatAvailable(s, pane) ? () => _pickMode(ViewMode.chat) : null, key: const Key('modeChat')),
      seg('Term', !_inChat, () => _pickMode(ViewMode.term), key: const Key('modeTerm')),
      if (s.hasSplit) ...[
        seg('Left pane', pane == 'left', () => setPane('left')),
        seg('Right pane', pane == 'right', () => setPane('right'), key: const Key('rightPane')),
      ],
    ]);
  }

  double _fit = 11, _width = 360, _height = 600;
  int? _columns; // the computer's grid width, from session.text; older elis sends none

  // fitted, the phone shows the program's whole grid, so a drag scrolls the program itself: it reaches the computer as
  // wheel notches (session scroll), which a TUI such as Claude Code reads as its own scrolling
  bool get _remoteScroll => !_history && m.fitted.containsKey(_fitKey);

  void _drag(double rows) {
    _dragRows += rows;
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
    if (err != null) {
      _dragRows = 0;
      return report(context, err);
    }
    unawaited(_load());
    _sendScroll(); // what the finger moved meanwhile
  }

  // edge to edge, no padding: every pixel counts on a phone
  // outside the zoom, so a touch beside a short grid still counts
  Widget _terminal() => Listener(
        onPointerDown: (e) {
          _finger = e.position;
          _stale = false;
        },
        onPointerMove: (e) => _finger = e.position,
        child: ClipRect(child: ColoredBox(color: C.term, child: _termShown ? _termView(term!) : _textView())),
      );

  // the grid scaled to the width; taller than the box, the bottom rows (the cursor's) stay in view
  // a live stream has no phone-side history, so a drag always scrolls the program; two fingers zoom
  Widget _termView(TermSession t) {
    final columns = _lead ? null : m.fitted[_fitKey]?.$1 ?? (autoFit.wanted ? _fitColumns() : null);
    return LayoutBuilder(builder: (context, box) {
      _width = box.maxWidth;
      _height = box.maxHeight;
      _seeComposer();
      _layoutGrid();
      final cell = _cell = CellMetrics.fit(_width, columns ?? t.snapshot!.cols);
      return TermGestures(
        key: const Key('term'),
        content: Size(box.maxWidth, t.snapshot!.rows * cell.h),
        rowHeight: cell.h,
        onScroll: (rows) => _scroll(t, rows),
        onTap: _tap,
        child: TerminalView(key: _grid, snapshot: t.snapshot, hold: t.hold, columns: columns),
      );
    });
  }

  // notches made before the lead are dropped: the reset and the claim change what is under the finger
  void _scroll(TermSession t, int rows) {
    if (_stale) return;
    if (!_direct) return _drag(rows.toDouble());
    _claim();
    if (_leading) _wheel(t, rows);
  }

  /// The cell under the finger, zoom and pan undone; outside the grid when the finger is.
  (int, int) _cellUnder() {
    final at = (_grid.currentContext!.findRenderObject() as RenderBox).globalToLocal(_finger);
    return ((at.dx / _cell.w).floor(), (at.dy / _cell.h).floor());
  }

  // leading, the phone is the program's mouse: a notch per row the finger moved, at the nearest cell
  void _wheel(TermSession t, int rows) {
    final snap = t.snapshot!;
    final (c, r) = _cellUnder();
    final col = c.clamp(0, snap.cols - 1), row = r.clamp(0, snap.rows - 1);
    for (var i = 0; i < rows.abs(); i++) {
      t.wheel(up: rows > 0, col: col, row: row); // dragging down shows older rows: wheel up
    }
  }

  /// Any single tap on the terminal claims; on the Term view it also clicks the cell under the finger, the claiming
  /// tap once the lead arrives.
  void _tap() {
    _claim();
    if (_termShown && _lead) {
      final snap = term!.snapshot!;
      final (col, row) = _cellUnder();
      if (col >= 0 && row >= 0 && col < snap.cols && row < snap.rows) term!.click(col: col, row: row);
    }
    if (_onCursorRow) return _showKeyboard();
    // typing comes back from the composer to the program, but a hidden keyboard opens only on the cursor row
    if (inputFocus.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0) _keyboard.requestFocus();
  }

  // the visible caret's whole row (plan decisions 24, 25); the history is reflowed, so there it is the last line,
  // and only while the history is at its bottom
  bool get _onCursorRow {
    final snap = term?.snapshot;
    if (snap == null || !snap.cursorVisible) return false;
    if (_termShown) return _cellUnder().$2 == snap.cursorY;
    final box = _text.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !vScroll.hasClients || vScroll.offset != 0) return false;
    return box.globalToLocal(_finger).dy >= box.size.height - _fit * 1.3;
  }

  // a focused field whose keyboard the user hid gets it back only by asking the platform
  void _showKeyboard() {
    widget.onKeyboard?.call();
    if (!_keyboard.hasPrimaryFocus) return _keyboard.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  // not input: it never claims
  void _toggleKeyboard() {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return FocusManager.instance.primaryFocus?.unfocus();
    _showKeyboard();
  }

  Widget _textView() => LayoutBuilder(builder: (context, box) {
          // the computer's own grid width, so a full-width row fills one phone row exactly; history written at a wider
          // size (before the fit) wraps rather than shrinking everything
          final cols = max(20, _columns ?? text.split('\n').fold<int>(20, (a, l) => max(a, l.runes.length)));
          // JetBrains Mono advances 0.6 em
          _width = box.maxWidth;
          _height = box.maxHeight;
          _seeComposer();
          _layoutGrid();
          // tiny when the computer's grid is wide, but whole rows, so the layout stays the program's (the fit reads it)
          _fit = _sizeFor(cols, min(13, _width / (cols * 0.6)));
          final size = _fit;
          final body = SelectableText(
            error != null && text.isEmpty ? error! : withGridGlyphs(text),
            key: const Key('screen'),
            focusNode: _textFocus,
            selectionControls: _noCaretHandle,
            // the size above is already the one whose rows fit; Android's font scale on top would wrap every full row
            textScaler: TextScaler.noScaling,
            // letterSpacing 0: the theme's body text adds 0.25 per glyph, which would wrap every full row
            style: TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: size, height: 1.3, letterSpacing: 0, color: error != null && text.isEmpty ? C.danger : C.termText),
          );
          final view = SingleChildScrollView(
            controller: vScroll,
            reverse: true, // the newest rows stay in view
            physics: _remoteScroll ? const NeverScrollableScrollPhysics() : null,
            child: SizedBox(key: _text, width: double.infinity, child: body),
          );
          return _SingleTap(
              onTap: _tap,
              child: _remoteScroll ? GestureDetector(onVerticalDragUpdate: (d) => _drag(d.delta.dy / (_fit * 1.3)), child: view) : view);
        });
}

// read-only text has no caret, but SelectableText shows a tap's collapsed selection as a caret handle whenever its
// field lacks the focus, which [_textFocus] always does
final _noCaretHandle = _NoCaretHandle();

class _NoCaretHandle extends MaterialTextSelectionControls {
  @override
  Widget buildHandle(BuildContext context, TextSelectionHandleType type, double textLineHeight, [VoidCallback? onTap]) =>
      type == TextSelectionHandleType.collapsed ? const SizedBox.shrink() : super.buildHandle(context, type, textLineHeight, onTap);
}

/// A single tap anywhere in [child], told after the double-tap timeout, as the Term view's: a double tap, a long press,
/// a drag or a second finger is not one. A Listener, outside the arena, so the text selection and the scroll inside
/// keep their gestures; the text's own tap would win the arena at once, before a double tap could be told apart.
class _SingleTap extends StatefulWidget {
  const _SingleTap({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_SingleTap> createState() => _SingleTapState();
}

class _SingleTapState extends State<_SingleTap> {
  int _fingers = 0;
  Offset? _down; // the touch that can still be a tap
  Offset _last = Offset.zero; // the tap that waits for a second one
  Timer? _wait, _hold, _triple; // timers, not event time stamps, so fake time in tests counts
  bool _long = false;

  @override
  void dispose() {
    _wait?.cancel();
    _hold?.cancel();
    _triple?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          _down = _fingers++ == 0 ? e.position : null;
          _long = false;
          _hold?.cancel();
          _hold = Timer(kLongPressTimeout, () => _long = true);
        },
        onPointerMove: (e) {
          if (_down case final d? when (e.position - d).distance > kTouchSlop) _down = null;
        },
        onPointerUp: (e) {
          _fingers--;
          final d = _down;
          _down = null;
          _hold?.cancel();
          if (d == null || _long) return;
          // a third tap is the text's paragraph selection: looking too
          if (_triple?.isActive == true) return _triple!.cancel();
          if (_wait?.isActive == true && (d - _last).distance < kDoubleTapSlop) {
            _wait!.cancel();
            _triple = Timer(kDoubleTapTimeout, () {});
            return;
          }
          _last = d;
          _wait = Timer(kDoubleTapTimeout, widget.onTap);
        },
        onPointerCancel: (_) {
          _fingers--;
          _down = null;
        },
        child: widget.child,
      );
}

/// The `_direct` rule at each write: leads while the pane is direct, `session.type` once it is not, so a claim refused
/// during [lead] sends this write indirectly as Term's input does.
class _PaneWriter implements GateWriter {
  _PaneWriter(this._direct, this._leader, this._typer);
  final bool Function() _direct;
  final GateWriter _leader, _typer;

  GateWriter get _now => _direct() ? _leader : _typer;

  @override
  Future<bool> lead() async => !_direct() || await _leader.lead() || !_direct();

  @override
  Future<bool> write(GateWrite w) => _now.write(w);

  @override
  bool pasteSafe(String text) => _now.pasteSafe(text);
}

/// A small bordered label in the app bar: the link the phone uses, the lead.
class _Tag extends StatelessWidget {
  const _Tag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: const TextStyle(fontSize: 11, color: C.muted, fontWeight: FontWeight.w600)),
      );
}
