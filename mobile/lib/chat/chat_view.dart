import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../model.dart';
import '../terminal/vt.dart';
import '../theme.dart';
import 'bottom_stack.dart';
import 'chat_composer.dart';
import 'claude_screen.dart';
import 'feed.dart';
import 'grid.dart';
import 'items.dart';
import 'panel_sheet.dart';
import 'rows.dart';
import 'transcript.dart';
import 'write_gate.dart';

/// What a prompt card reads and writes through, for plan C's builder.
class ChatPromptContext {
  const ChatPromptContext(
      {required this.screen, required this.grid, required this.pending, required this.gate, required this.remote, required this.openPanel});

  final ClaudeScreen screen;
  final Grid grid;
  final List<PendingCall> pending;
  final WriteGate gate;
  final bool remote;
  final void Function(String? stopped) openPanel;
}

/// The card for the dialog on screen, or null for the panel sheet.
typedef PromptCardBuilder = Widget? Function(BuildContext context, ChatPromptContext c);

void _noKey(String? seq, VtKey? key, int mods) {}
void _noAnswer(String key) {}

Widget _chip(String label, {Key? key, VoidCallback? onTap}) => GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: const TextStyle(fontSize: 12, color: C.text)),
      ),
    );

/// The app bar's title in Chat: the transcript's title, else the session's name, and the model chip.
class ChatTitle extends StatelessWidget {
  const ChatTitle({super.key, required this.feed, required this.s, this.onChangeModel});

  final TranscriptFeed feed;
  final Session s;
  final VoidCallback? onChangeModel; // null while Claude is not idle

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: feed,
        builder: (context, _) {
          final m = feed.meta;
          final title = m?.title ?? '';
          final model = modelLabel(m?.model, m?.effort);
          return Row(spacing: 8, children: [
            Flexible(
                child: Text(title.isEmpty ? s.name : title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            // a `/model` since Claude's last answer: the transcript has not caught up yet
            if (model.isNotEmpty)
              PopupMenuButton<void>(
                tooltip: '',
                itemBuilder: (_) => [PopupMenuItem(enabled: onChangeModel != null, onTap: onChangeModel, child: const Text('Change model…'))],
                child: Opacity(opacity: modelPending(feed.items) ? 0.45 : 1, child: _chip(model, key: const Key('modelChip'))),
              ),
          ]);
        },
      );
}

/// Claude's session as a chat: the transcript's items over the live grid; every write goes through [gate].
class ChatView extends StatefulWidget {
  const ChatView(
      {super.key,
      required this.feed,
      required this.grid,
      required this.grids,
      required this.gate,
      required this.s,
      required this.exited,
      required this.stale,
      required this.onTerm,
      required this.switcher,
      this.composer,
      this.promptCard,
      this.onKey = _noKey,
      this.onAnswer = _noAnswer});

  static const exitedText = 'Claude exited', staleText = 'Reconnecting…';

  /// Why every Chat write is blocked; the screen's [WriteGate] returns it.
  static String? blockedReason({required bool exited, required bool stale}) => exited ? exitedText : stale ? staleText : null;

  final TranscriptFeed feed;
  final Grid? Function() grid;
  final Listenable grids;
  final WriteGate gate;
  final Session s;
  final bool exited, stale;
  final VoidCallback onTerm;
  final Widget switcher;
  final GlobalKey<ChatComposerState>? composer; // for the model chip's `send`
  final PromptCardBuilder? promptCard;
  final void Function(String? seq, VtKey? key, int mods) onKey; // the panel's keys: straight to the program, past the gate
  final void Function(String key) onAnswer;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  static const _bottomSlack = 24.0;
  final _scroll = ScrollController();
  List<ChatRow> _rows = const [];
  Map<String, int> _index = const {};
  final Map<String, BuildContext> _built = {};
  final Set<String> _gone = {}; // rows built once: scrolling back to a fresh row does not fade it in again
  int _newCount = 0;
  String? _sticky; // a row key: an index would point at another row for the frame after an append
  bool _away = false, _header = true, _todos = false;
  int _switches = 0;
  late final _composer = widget.composer ?? GlobalKey<ChatComposerState>();
  int _dialogReads = 0; // consecutive grid reads showing a dialog; a blank or replaying grid neither counts nor resets
  Timer? _reread;
  bool _panelHidden = false, _panelForced = false;
  String? _stopped;

  TranscriptFeed get feed => widget.feed;

  @override
  void initState() {
    super.initState();
    _setRows(chatRows(feed.items));
    _switches = feed.switches;
    feed.addListener(_changed);
    _scroll.addListener(_onScroll);
    widget.grids.addListener(_onGrid);
    _readGrid();
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (old.grids != widget.grids) {
      old.grids.removeListener(_onGrid);
      widget.grids.addListener(_onGrid);
    }
    if (widget.exited || widget.stale) _clearPanel();
    if (old.feed == feed) return;
    old.feed.removeListener(_changed);
    feed.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    _reread?.cancel();
    widget.grids.removeListener(_onGrid);
    feed.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _onGrid() {
    final before = (_counts, _panelForced);
    _readGrid();
    // while a dialog counts, its card and panel follow every frame
    if (mounted && (_counts || before != (_counts, _panelForced))) setState(() {});
  }

  void _readGrid() {
    final g = widget.grid();
    final s = g == null ? null : ClaudeScreen.read(g);
    if (s == null || !(s.bottomStack || s.dialog)) return;
    if (s.bottomStack) return _clearPanel();
    _dialogReads++;
    // a dialog drawn once may bring no further frame: a re-read stands in for the second update
    if (_dialogReads == 1) _reread = Timer(const Duration(milliseconds: 400), _onGrid);
  }

  bool get _counts => _dialogReads >= 2 && !widget.exited && !widget.stale;

  // everything the dialog left: its count, a swipe, a forced open and the stopped text
  void _clearPanel() {
    _reread?.cancel();
    _dialogReads = 0;
    _panelHidden = _panelForced = false;
    _stopped = null;
  }

  void _openPanel(String? stopped) {
    if (!mounted) return;
    setState(() {
      _panelForced = true;
      _panelHidden = false;
      _stopped = stopped;
    });
  }

  void _hidePanel() => setState(() {
        _panelHidden = true;
        _panelForced = false;
        _stopped = null;
      });

  void _setRows(List<ChatRow> rows) {
    _rows = rows;
    _index = {for (final (n, r) in rows.indexed) r.key: n};
  }

  // a row's top on screen, or null when it is not laid out
  double? _top(String key) {
    final c = _built[key];
    final box = c != null && c.mounted ? c.findRenderObject() as RenderBox? : null;
    return box != null && box.attached && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;
  }

  // a row's place in the list's content, so the user's own scrolling does not count as a shift
  double? _offset(String key) {
    final box = _top(key) == null ? null : _built[key]!.findRenderObject() as RenderBox;
    return box == null ? null : RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
  }

  Rect? get _viewport {
    if (!_scroll.hasClients) return null;
    final box = _scroll.position.context.notificationContext?.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  // the built rows on screen, by index
  Iterable<(int, String)> get _visible sync* {
    final vp = _viewport;
    if (vp == null) return;
    for (final key in _built.keys) {
      final top = _top(key), n = _index[key];
      if (top == null || n == null) continue;
      final h = (_built[key]!.findRenderObject() as RenderBox).size.height;
      if (top < vp.bottom && top + h > vp.top) yield (n, key);
    }
  }

  void _changed() {
    if (!mounted) return;
    final rows = chatRows(feed.items);
    final old = _rows;
    final k = old.isEmpty ? -1 : rows.indexWhere((r) => r.key == old.first.key);
    final added = k <= 0 ? 0 : rows.take(k).where((r) => r.day == null).length;
    // away from the bottom, any change keeps the row the user is reading where it is
    final anchor = _away ? _visible.firstOrNull?.$2 : null;
    final at = anchor == null ? null : _offset(anchor);
    final switched = feed.switches != _switches;
    setState(() {
      _setRows(rows);
      if (_away) _newCount += added;
      // a new transcript: nothing above or below the old rows describes it
      if (switched) {
        _clearPanel();
        _switches = feed.switches;
        _away = false;
        _newCount = 0;
        _header = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final now = anchor == null ? null : _offset(anchor);
      if (at != null && now != null && now != at) _shift(now - at, _built[anchor]!.findRenderObject()!);
      _onScroll(load: rows.length != old.length);
    });
  }

  void _shift(double by, RenderObject row) {
    final p = _scroll.position;
    if (!p.isScrollingNotifier.value) return _scroll.jumpTo(p.pixels + by);
    // a jump would end the user's drag or fling
    p.correctBy(by);
    RenderAbstractViewport.of(row).markNeedsLayout();
  }

  void _onScroll({bool load = true}) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final away = p.pixels > _bottomSlack;
    final top = _visible.fold(0, (m, v) => max(m, v.$1));
    final n = stickyPrompt(_rows, top), sticky = n == null ? null : _rows[n].key;
    if (load && p.extentAfter < 400) feed.loadEarlier();
    if (away == _away && sticky == _sticky && (away || _newCount == 0)) return;
    setState(() {
      _away = away;
      _sticky = sticky;
      if (!away) _newCount = 0;
    });
  }

  bool _onUserScroll(UserScrollNotification n) {
    // `forward` lowers pixels: toward the newest row, at the bottom of this reversed list
    final show = switch (n.direction) {
      ScrollDirection.forward => true,
      ScrollDirection.reverse => n.metrics.maxScrollExtent <= 0, // a list too short to scroll moves nothing
      ScrollDirection.idle => _header,
    };
    if (show != _header) setState(() => _header = show);
    return false;
  }

  /// Scrolls up until [key]'s row is built, then brings it on screen.
  Future<void> _reveal(String key) async {
    for (var n = 0; n < 100 && mounted && _scroll.hasClients; n++) {
      final c = _built[key];
      if (c != null && c.mounted) return Scrollable.ensureVisible(c, alignment: 1, duration: const Duration(milliseconds: 200));
      final p = _scroll.position;
      if (p.pixels >= p.maxScrollExtent) return;
      _scroll.jumpTo(min(p.pixels + p.viewportDimension, p.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Widget _headerRow() {
    final pr = feed.meta?.pr;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 6, children: [
        Row(spacing: 8, children: [
          Flexible(
              child: Text(widget.s.shortCwd,
                  style: const TextStyle(fontSize: 12, color: C.muted, fontFamily: mono), overflow: TextOverflow.ellipsis)),
          if (pr?.prNumber != null && pr?.prUrl != null)
            _chip('PR #${pr!.prNumber}', key: const Key('prChip'), onTap: () => openWebLink(pr.prUrl)),
        ]),
        widget.switcher,
      ]),
    );
  }

  Widget? _todoStrip() {
    final todos = feed.meta?.todos ?? const [];
    if (todos.every((t) => t.status == 'completed')) return null;
    final done = todos.where((t) => t.status == 'completed').length;
    final active = todos.where((t) => t.status == 'in_progress').firstOrNull;
    return InkWell(
      key: const Key('todoStrip'),
      onTap: () => setState(() => _todos = !_todos),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
          Row(children: [
            Expanded(
                child: Text('☐ $done/${todos.length}${active == null ? '' : ' · ${active.content}'}',
                    style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Icon(_todos ? Icons.expand_less : Icons.expand_more, size: 18, color: C.muted),
          ]),
          if (_todos)
            for (final t in todos)
              Text('${switch (t.status) { 'completed' => '☑', 'in_progress' => '▸', _ => '☐' }} ${t.content}',
                  style: const TextStyle(fontSize: 13, color: C.muted)),
        ]),
      ),
    );
  }

  Widget _row(BuildContext c, int n) {
    if (n == _rows.length) {
      return const Padding(
          key: ValueKey('loadingEarlier'),
          padding: EdgeInsets.all(8),
          child: Center(child: Text('Loading earlier…', style: TextStyle(color: C.muted))));
    }
    final r = _rows[n];
    final fresh = feed.fresh.contains(r.item?.uuid) && !_gone.contains(r.key);
    return _Tracked(
      key: ValueKey(r.key),
      onBuilt: (c) => _built[r.key] = c,
      onGone: (c) {
        if (_built[r.key] == c) _built.remove(r.key);
        _gone.add(r.key);
      },
      child: chatRowWidget(c, r, fresh: fresh, exited: widget.exited, stale: widget.stale),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.grid();
    final live = !widget.exited && !widget.stale;
    final card = _counts && !_panelForced && g != null
        ? widget.promptCard?.call(
            context,
            ChatPromptContext(
                screen: ClaudeScreen.read(g), grid: g, pending: feed.pending, gate: widget.gate, remote: widget.s.remote, openPanel: _openPanel))
        : null;
    final panel = live && (_panelForced || (_counts && card == null));
    final held = card != null ? 'Answer the prompt above' : panel ? 'Claude shows a panel' : null;
    final n = _index[_sticky], sticky = n == null ? null : _rows[n];
    final todos = _todoStrip();
    final state = _state();
    final top = [
      AnimatedSize(
        key: const Key('chatHeader'),
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        // without the list there is no scroll to bring the header back
        child: _header || state != null ? _headerRow() : const SizedBox(width: double.infinity),
      ),
      if (widget.exited)
        ListTile(
            key: const Key('chatExited'),
            title: const Text(ChatView.exitedText),
            trailing: TextButton(onPressed: widget.onTerm, child: const Text('Term'))),
      if (widget.stale) const Padding(padding: EdgeInsets.all(8), child: Text(ChatView.staleText, style: TextStyle(color: C.muted))),
      if (sticky != null)
        InkWell(
          key: const Key('stickyPrompt'),
          onTap: () => _reveal(sticky.key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Text('❯ ${sticky.item?.text ?? ''}', style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ),
        ),
      ?todos,
      if (sticky != null || todos != null) const Divider(height: 1),
    ];
    final list = Stack(children: [
      NotificationListener<UserScrollNotification>(
        onNotification: _onUserScroll,
        child: ListView.builder(
          key: const Key('chatList'),
          controller: _scroll,
          reverse: true,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          itemCount: _rows.length + (feed.loadingEarlier ? 1 : 0),
          findChildIndexCallback: (k) => k is ValueKey<String> ? _index[k.value] : null,
          itemBuilder: _row,
        ),
      ),
      if (_away)
        Positioned(
          right: 12,
          bottom: 12,
          child: ActionChip(
            key: const Key('jumpToBottom'),
            onPressed: () => _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut),
            label: Text(_newCount == 0 ? '↓' : '↓ $_newCount new'),
          ),
        ),
    ]);
    return ColoredBox(
      color: C.bg,
      child: LayoutBuilder(
        builder: (context, box) => Stack(children: [
          Column(children: [
            // at most half the height (a quarter beside a card): an open todo list or a landscape keyboard scrolls here
            // and never squeezes out the list
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * (card == null ? 0.5 : 0.25)),
              child: SingleChildScrollView(primary: false, child: Column(children: top)),
            ),
            Expanded(child: state ?? list),
            // the rest: a landscape keyboard scrolls the card and the composer here too
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * (card == null ? 0.5 : 0.75)),
              child: SingleChildScrollView(
                  primary: false,
                  reverse: true,
                  child: _bottom(
                      card: card == null
                          ? null
                          : ConstrainedBox(
                              key: const Key('promptCard'),
                              constraints: BoxConstraints(maxHeight: box.maxHeight * 0.6),
                              child: SingleChildScrollView(primary: false, child: card)),
                      held: held,
                      onOpen: panel && _panelHidden ? () => setState(() => _panelHidden = false) : null)),
            ),
          ]),
          if (panel && !_panelHidden)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              top: box.maxHeight * 0.1,
              child: PanelSheet(grid: g, stopped: _stopped, onKey: widget.onKey, onAnswer: widget.onAnswer, onHide: _hidePanel),
            ),
        ]),
      ),
    );
  }
}

/// What shows in place of the list, or null for the list; an exited Claude keeps its history.
extension on _ChatViewState {
  Widget? _state() {
    final error = feed.error;
    if (!widget.exited && error != null && error != TranscriptError.hostTooOld) return _unreadable(error);
    if (feed.loading) return const _Skeleton();
    if (_rows.isEmpty && !widget.exited) return _empty();
    return null;
  }

  // both scroll when a landscape keyboard leaves less height than they need
  Widget _unreadable(TranscriptError error) => Center(
        key: const Key('chatUnreadable'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
            Text(error == TranscriptError.notFound ? 'Claude\'s transcript was not found.' : 'Claude\'s transcript could not be read.',
                textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
            Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
              OutlinedButton(key: const Key('chatRetry'), onPressed: feed.retry, child: const Text('Retry')),
              OutlinedButton(key: const Key('chatTerm'), onPressed: widget.onTerm, child: const Text('Term')),
            ]),
          ]),
        ),
      );

  Widget _bottom({Widget? card, String? held, VoidCallback? onOpen}) => ListenableBuilder(
        listenable: widget.grids,
        builder: (context, _) {
          final g = widget.grid();
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            BottomStack(
                screen: g == null ? null : ClaudeScreen.read(g),
                grid: g,
                feed: feed,
                gate: widget.gate,
                stale: widget.stale,
                remote: widget.s.remote),
            ?card,
            ChatComposer(
                key: _composer,
                feed: feed,
                screen: () => switch (widget.grid()) {
                      final g? => ClaudeScreen.read(g),
                      null => null,
                    },
                colours: g?.colours ?? false,
                remote: widget.s.remote,
                gate: widget.gate,
                disabledBy: ChatView.blockedReason(exited: widget.exited, stale: widget.stale),
                held: held,
                onOpen: onOpen),
          ]);
        },
      );

  Widget _empty() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
            const Text('Claude is ready', style: TextStyle(fontSize: 16, color: C.muted)),
            Wrap(spacing: 8, children: [
              for (final c in ['help', 'model', 'usage'])
                OutlinedButton(
                    key: Key('emptyCommand-$c'),
                    onPressed: () => _composer.currentState?.insert('/$c '),
                    child: Text('/$c', style: const TextStyle(fontFamily: mono))),
            ]),
          ]),
        ),
      );
}

/// Placeholder bubbles until the first page; static, so a held page never keeps a frame scheduled.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        key: const Key('chatSkeleton'),
        reverse: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          for (final (w, right) in [(0.55, true), (0.8, false), (0.4, true), (0.7, false)])
            Align(
              alignment: right ? Alignment.centerRight : Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: w,
                child: Container(
                    height: right ? 36 : 64,
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12))),
              ),
            ),
        ],
      );
}

/// Reports its row's context while the row is built, so the list can find what is on screen.
class _Tracked extends StatefulWidget {
  const _Tracked({super.key, required this.onBuilt, required this.onGone, required this.child});

  final void Function(BuildContext) onBuilt, onGone;
  final Widget child;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  @override
  Widget build(BuildContext context) {
    widget.onBuilt(context);
    return widget.child;
  }

  @override
  void dispose() {
    widget.onGone(context);
    super.dispose();
  }
}
