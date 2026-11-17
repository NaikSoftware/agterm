import 'dart:async';

import 'package:flutter/material.dart';

import '../ble_transport.dart';
import '../client.dart';
import '../main.dart';
import '../model.dart';
import '../notice.dart';
import '../theme.dart';
import '../watch.dart';
import 'actions.dart';
import 'new_session.dart';
import 'pair.dart';
import 'prompt.dart';
import 'session.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.model, required this.computers});
  final AgtermModel model;
  final Computers computers;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  String filter = 'all';
  final collapsed = <String>{};
  final snippets = <String, String>{}; // blocked session id → the last rows of its screen
  StreamSubscription<Alert>? alerts;
  Timer? snippetTimer;
  late final wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 4800));

  AgtermModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    alerts = m.alerts.listen(_onAlert);
    snippetTimer = Timer.periodic(const Duration(seconds: 2), (_) => _loadSnippets());
  }

  @override
  void dispose() {
    alerts?.cancel();
    snippetTimer?.cancel();
    wave.dispose();
    super.dispose();
  }

  void _onAlert(Alert a) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    showNotice(context, '${a.title}: ${a.body}',
        action: a.sessionId.isEmpty ? null : 'Open', onAction: () => mounted ? open(a.sessionId) : null);
  }

  // only for the blocked cards on screen: their prompt is what the quick answers act on
  Future<void> _loadSnippets() async {
    if (m.state != LinkState.connected || m.background || ModalRoute.of(context)?.isCurrent != true) return;
    for (final s in m.sessions.where((s) => s.status == 'blocked')) {
      try {
        final r = await m.call('session.text', target: s.id, args: {'lines': 12});
        if (mounted) setState(() => snippets[s.id] = '${r['text'] ?? ''}');
      } catch (_) {}
    }
  }

  void open(String id) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionScreen(model: m, sessionId: id)));

  void showComputers() => showModalBottomSheet(
        context: context,
        builder: (sheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Computers', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
            for (final p in widget.computers.all)
              ListTile(
                minTileHeight: 56,
                leading: Icon(p.key == m.pairing.key ? Icons.radio_button_checked : Icons.radio_button_off, color: C.accent),
                title: Text(p.name),
                subtitle: Text([if (p.host != null) p.address, if (p.bluetooth) 'Bluetooth'].join(' · '), style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.muted)),
                trailing: IconButton(
                  tooltip: 'Forget',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    Navigator.pop(sheet);
                    if (await confirm(context, 'Forget ${p.name}?', 'You will need its pairing code to connect again.', 'Forget')) {
                      await widget.computers.forget(p);
                    }
                  },
                ),
                onTap: () {
                  Navigator.pop(sheet);
                  if (p.key != m.pairing.key) widget.computers.open(p);
                },
              ),
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.add, color: C.accent),
              title: const Text('Pair another computer'),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => PairScreen(onPaired: widget.computers.add, canGoBack: true)));
              },
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );

  void showMenuSheet() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m.windows.where((w) => w.open).length > 1) ...[
                const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 4), child: Text('WINDOWS', style: sectionLabel)),
                for (final w in m.windows.where((w) => w.open))
                  ListTile(
                    minTileHeight: 52,
                    leading: Icon(w.id == m.window?.id ? Icons.radio_button_checked : Icons.radio_button_off, color: C.accent),
                    title: Text(w.name.isEmpty ? w.id : w.name),
                    onTap: () {
                      Navigator.pop(sheet);
                      m.selectWindow(w.id);
                    },
                  ),
                const Divider(),
              ],
              ListTile(
                  minTileHeight: 52,
                  leading: const Icon(Icons.create_new_folder_outlined, color: C.muted),
                  title: const Text('New workspace'),
                  onTap: () async {
                    Navigator.pop(sheet);
                    final n = await promptText(context, 'New workspace', hint: 'Name', action: 'Create');
                    if (n != null && n.trim().isNotEmpty && mounted) reportOf(context, m.act('workspace.new', args: {'name': n.trim()}));
                  }),
              ListTile(
                  minTileHeight: 52,
                  leading: const Icon(Icons.history, color: C.muted),
                  title: const Text('Reopen a closed session'),
                  onTap: () {
                    Navigator.pop(sheet);
                    showRecent();
                  }),
              ListTile(
                  minTileHeight: 52,
                  leading: const Icon(Icons.notifications_none, color: C.muted),
                  title: const Text('Send a desktop notification'),
                  onTap: () async {
                    Navigator.pop(sheet);
                    final body = await promptText(context, 'Notify the computer', hint: 'Message', action: 'Send');
                    if (body != null && body.trim().isNotEmpty && mounted) {
                      reportOf(context, m.act('notify', args: {'body': body.trim(), 'title': 'Agterm2'}));
                    }
                  }),
              StatefulBuilder(
                  builder: (context, setSheet) => SwitchListTile(
                        key: const Key('watch'),
                        secondary: const Icon(Icons.notifications_active_outlined, color: C.muted),
                        title: const Text('Alerts in the background'),
                        subtitle: Text(Watch.enabled && !Watch.permitted ? 'Notifications are off for Agterm2 in Android settings' : 'When an agent needs you',
                            style: const TextStyle(fontSize: 12, color: C.muted)),
                        value: Watch.enabled,
                        onChanged: (v) async {
                          await Watch.setEnabled(v);
                          setSheet(() {});
                        },
                      )),
              StatefulBuilder(
                  builder: (context, setSheet) => SwitchListTile(
                        key: const Key('preferBluetooth'),
                        secondary: const Icon(Icons.bluetooth, color: C.muted),
                        title: const Text('Prefer Bluetooth'),
                        subtitle: Text(
                            m.pairing.bluetooth && m.pairing.host != null
                                ? 'Try Bluetooth before Wi-Fi'
                                : 'This pairing has one way to connect',
                            style: const TextStyle(fontSize: 12, color: C.muted)),
                        value: BluetoothPref.prefer,
                        onChanged: m.pairing.bluetooth && m.pairing.host != null
                            ? (v) async {
                                if (v) await requestBluetooth();
                                await BluetoothPref.set(v);
                                setSheet(() {});
                              }
                            : null,
                      )),
              ListTile(
                  minTileHeight: 52,
                  leading: const Icon(Icons.computer, color: C.muted),
                  title: const Text('Computers'),
                  onTap: () {
                    Navigator.pop(sheet);
                    showComputers();
                  }),
              const SizedBox(height: 8),
            ]),
          ),
        ),
      );

  Future<void> showRecent() async {
    List items;
    try {
      items = (await m.call('recent.list', windowed: false))['recent'] as List? ?? const [];
    } on AgtermError catch (e) {
      if (mounted) report(context, e.message);
      return;
    }
    if (!mounted) return;
    if (items.isEmpty) return report(context, 'No recently closed sessions');
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Recently closed', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
          for (final e in items.cast<Map>())
            ListTile(
              minTileHeight: 52,
              title: Text('${e['title'] ?? e['id']}'),
              subtitle: Text(shortHome('${e['subtitle'] ?? ''}'), style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.muted)),
              onTap: () => Navigator.pop(c, '${e['id']}'),
            ),
        ]),
      ),
    );
    if (id != null && mounted) reportOf(context, m.act('recent.open', target: id));
  }

  // the session rows the list draws: a filter's matches, or the tree minus folded workspaces and folded companions
  Iterable<Session> _shownRows(List<Session> all) => filter != 'all'
      ? all.where((s) => filter == 'flagged' ? s.flagged : s.status == filter)
      : m.workspaces.where((w) => !collapsed.contains(w.id)).expand((w) {
          final folded = {for (final s in w.sessions) if (s.collapsed) s.id};
          return w.sessions.where((s) => s.parent.isEmpty || !folded.contains(s.parent));
        });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final all = m.sessions.toList();
          final needs = all.where((s) => s.needsYou).toList()..sort((a, b) => a.status == b.status ? 0 : (a.status == 'blocked' ? -1 : 1));
          // one ticker drives every running row; it sleeps while none is on screen, and stands still with animations off
          if (!MediaQuery.disableAnimationsOf(context) && _shownRows(all).any((s) => s.status == 'active')) {
            if (!wave.isAnimating) wave.repeat();
          } else {
            wave.value = 0;
          }
          return Scaffold(
            floatingActionButton: m.state == LinkState.connected && m.workspaces.isNotEmpty
                ? FloatingActionButton.extended(
                    key: const Key('newSession'),
                    onPressed: () => showNewSession(context, m),
                    backgroundColor: C.text,
                    foregroundColor: C.bg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    icon: const Icon(Icons.add),
                    label: const Text('New session', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  )
                : null,
            body: SafeArea(
              child: RefreshIndicator(
                onRefresh: m.refresh,
                child: CustomScrollView(slivers: [
                  SliverToBoxAdapter(child: _header(all)),
                  if (m.state != LinkState.connected) SliverToBoxAdapter(child: _offline()),
                  if (m.state == LinkState.connected && !m.loaded)
                    const SliverFillRemaining(child: Center(child: CircularProgressIndicator())),
                  if (m.loaded) ..._body(all, needs),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ]),
              ),
            ),
          );
        },
      );

  Widget _header(List<Session> all) {
    final line = switch (m.state) {
      LinkState.connected => m.via == 'BT' ? 'Bluetooth' : '${m.pairing.host}',
      LinkState.connecting => 'Connecting…',
      LinkState.offline => 'Offline',
    };
    final blocked = all.where((s) => s.status == 'blocked').length, done = all.where((s) => s.status == 'completed').length;
    Widget chip(String id, String label, {Widget? avatar}) {
      final on = filter == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: Key('filter-$id'),
          selected: on,
          showCheckmark: false,
          onSelected: (_) => setState(() => filter = on ? 'all' : id),
          avatar: avatar,
          label: Text(label),
          labelStyle: TextStyle(fontSize: 13, color: on ? C.bg : C.text, fontWeight: on ? FontWeight.w600 : null),
          selectedColor: C.text,
          backgroundColor: C.hover,
          side: on ? BorderSide.none : const BorderSide(color: C.line),
          shape: const StadiumBorder(),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: showComputers,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(children: [
                  const AppMark(),
                  const SizedBox(width: 11),
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Agterm2', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      Text('${m.pairing.name} · $line', style: const TextStyle(fontSize: 12.5, color: C.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            key: const Key('menu'),
            tooltip: 'More',
            onPressed: showMenuSheet,
            style: IconButton.styleFrom(
                backgroundColor: C.hover,
                side: const BorderSide(color: C.line),
                fixedSize: const Size(44, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            icon: const Icon(Icons.more_horiz, color: C.muted),
          ),
        ]),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            chip('all', 'All'),
            chip('blocked', 'Blocked $blocked', avatar: const StatusShape('blocked', size: 9, still: true)),
            chip('completed', 'Done $done', avatar: const StatusShape('completed', size: 9)),
            chip('flagged', 'Flagged', avatar: const Lucide(lucideFlag, size: 14, color: C.indigo)),
          ]),
        ),
      ]),
    );
  }

  Widget _offline() => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          if (m.state == LinkState.connecting)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            const Icon(Icons.cloud_off, color: C.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(m.error ?? 'Connecting to ${m.pairing.host == null ? m.pairing.name : m.pairing.address}…', style: const TextStyle(color: C.muted, height: 1.4))),
        ]),
      );

  List<Widget> _body(List<Session> all, List<Session> needs) {
    if (filter != 'all') {
      final list = all.where((s) => filter == 'flagged' ? s.flagged : s.status == filter).toList();
      final byId = {for (final w in m.workspaces) w.id: w};
      return [
        if (list.isEmpty)
          SliverToBoxAdapter(
              child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Text(filter == 'flagged' ? 'No flagged sessions' : 'Nothing ${statusLabel(filter).toLowerCase()} right now',
                      textAlign: TextAlign.center, style: const TextStyle(color: C.muted)))),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          sliver: SliverList.list(children: [
            for (final s in list)
              _row(s, byId[s.workspaceId], tint: tintColor(byId[s.workspaceId]?.tint ?? '') ?? C.active, indent: 10, showWorkspace: true),
          ]),
        ),
      ];
    }
    return [
      if (needs.isNotEmpty) ...[
        const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, 10), child: Text('NEEDS YOU', style: sectionLabel))),
        SliverList.list(children: [for (final s in needs) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 8), child: _card(s))]),
      ],
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: Row(children: [
            const Expanded(child: Text('WORKSPACES', style: sectionLabel)),
            if (m.windows.where((w) => w.open).length > 1) Text('Window: ${m.window?.name ?? ''}', style: const TextStyle(fontSize: 12, color: C.muted)),
          ]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        sliver: SliverList.list(children: [
          for (final w in m.workspaces.where((w) => w.sessions.isNotEmpty)) Padding(padding: const EdgeInsets.only(bottom: 10), child: _group(w)),
          if (m.workspaces.where((w) => w.sessions.isEmpty).toList() case final empty when empty.isNotEmpty)
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              mainAxisExtent: 52,
              children: [for (final w in empty) _emptyTile(w)],
            ),
        ]),
      ),
    ];
  }

  // an empty workspace has nothing to fold, so it is a tile; a tap opens its actions, where a new session starts
  Widget _emptyTile(Workspace w) => Material(
        color: C.hover,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.line)),
        child: InkWell(
          key: Key('wsTile-${w.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => showWorkspaceActions(context, m, w),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              SizedBox(width: 20, child: Lucide(lucideSquareStack, color: tintColor(w.tint) ?? C.muted)),
              const SizedBox(width: 9),
              Expanded(child: Text(w.name, style: const TextStyle(fontSize: 14, color: C.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
      );

  // the most urgent status among a folded workspace's sessions (blocked > active > completed), the first on a tie
  static Session? _urgent(Iterable<Session> sessions) {
    const rank = {'blocked': 0, 'active': 1, 'completed': 2};
    Session? best;
    for (final s in sessions) {
      if (rank[s.status] case final r? when best == null || r < rank[best.status]!) best = s;
    }
    return best;
  }

  Widget _group(Workspace w) {
    final own = tintColor(w.tint);
    final tint = own ?? C.active;
    final open = !collapsed.contains(w.id);
    final folded = {for (final s in w.sessions) if (s.collapsed) s.id};
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: own == null
          ? null
          : BoxDecoration(color: own.withValues(alpha: 0.10), border: Border.all(color: own.withValues(alpha: 0.16)), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 2, children: [
        _workspaceRow(w, tint: tint, tinted: own != null, open: open),
        if (open)
          for (final s in w.sessions)
            if (s.parent.isEmpty)
              _row(s, w, tint: tint, indent: 22, chevronSlot: true, hiddenBlocked: s.collapsed && w.sessions.any((c) => c.parent == s.id && c.status == 'blocked'))
            else if (!folded.contains(s.parent))
              _row(s, w, tint: tint, indent: 46),
      ]),
    );
  }

  Widget _workspaceRow(Workspace w, {required Color tint, required bool tinted, required bool open}) {
    final urgent = open ? null : _urgent(w.sessions);
    return Row(children: [
      Expanded(
        child: InkWell(
          key: Key('ws-${w.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => open ? collapsed.add(w.id) : collapsed.remove(w.id)),
          onLongPress: () => showWorkspaceActions(context, m, w),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                SizedBox(width: 14, child: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: C.dim)),
                const SizedBox(width: 10),
                SizedBox(width: 20, child: Lucide(lucideSquareStack, color: tinted ? tint : C.muted)),
                const SizedBox(width: 10),
                Expanded(child: Text(w.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (urgent != null) Padding(padding: const EdgeInsets.only(left: 8), child: StatusShape(urgent.status, blink: urgent.blink)),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(width: 4),
      IconButton(
        key: Key('wsMenu-${w.id}'),
        tooltip: 'Workspace actions',
        onPressed: () => showWorkspaceActions(context, m, w),
        style: IconButton.styleFrom(fixedSize: const Size(44, 44)),
        icon: const Icon(Icons.more_vert, color: C.muted),
      ),
      const SizedBox(width: 4),
    ]);
  }

  Widget _row(Session s, Workspace? w,
      {required Color tint, required double indent, bool chevronSlot = false, bool hiddenBlocked = false, bool showWorkspace = false}) {
    final own = tintColor(s.tint);
    final t = own ?? tint;
    final running = s.status == 'active';
    final info = showWorkspace ? s.workspaceName : (s.context.isNotEmpty ? s.context : s.shortCwd);
    final hasCompanions = chevronSlot && (w?.sessions.any((c) => c.parent == s.id) ?? false);
    final radius = BorderRadius.circular(running ? 0 : 12);
    // no selected-session highlight: a tap opens a new screen, so "current" means nothing in this list.
    // The wave sits under the Material and the tint is Ink, so neither hides the tap ripple.
    // its own layer, so a wave frame repaints this row and not the whole workspace group
    return RepaintBoundary(
     child: CustomPaint(
      painter: running ? _WavePainter(wave, t) : null,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('row-${s.id}'),
          borderRadius: radius,
          onTap: () => open(s.id),
          onLongPress: () => showSessionActions(context, m, s),
          child: Ink(
            decoration: BoxDecoration(color: own?.withValues(alpha: 0.09), borderRadius: radius),
            child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: EdgeInsets.fromLTRB(chevronSlot ? 0 : indent, 6, 12, 6),
            child: Row(children: [
              if (chevronSlot)
                // the whole lead-in is the fold control: a 14 px chevron alone is too small to hit
                Semantics(
                  button: hasCompanions,
                  label: hasCompanions ? (s.collapsed ? 'Show companions' : 'Hide companions') : null,
                  child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: hasCompanions ? () => reportOf(context, m.act(s.collapsed ? 'session.expand' : 'session.collapse', target: s.id)) : null,
                  child: SizedBox(
                    width: indent + 14,
                    height: 40,
                    child: hasCompanions
                        ? Align(alignment: Alignment.centerRight, child: Icon(s.collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: C.dim))
                        : null,
                  ),
                )),
              if (chevronSlot) const SizedBox(width: 10),
              SizedBox(width: 20, child: Center(child: AgentLogo(s.agent, color: own ?? (s.agent.isEmpty ? C.muted : null)))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, spacing: 1, children: [
                  Text(s.name, style: TextStyle(fontSize: 15, color: own ?? C.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (info.isNotEmpty) Text(info, style: const TextStyle(fontSize: 12.5, color: C.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (s.flagged) const Padding(padding: EdgeInsets.only(left: 10), child: Lucide(lucideFlag, size: 14, color: C.indigo)),
              if (s.unseen > 0)
                Container(
                  margin: const EdgeInsets.only(left: 10),
                  constraints: const BoxConstraints(minWidth: 20),
                  height: 20,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: C.unseen, borderRadius: BorderRadius.circular(10)),
                  child: Text('${s.unseen}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              if (hiddenBlocked)
                Semantics(
                  label: 'A hidden companion is blocked',
                  child: Container(
                      key: Key('hiddenBlocked-${s.id}'),
                      margin: const EdgeInsets.only(left: 10), width: 7, height: 7, decoration: const BoxDecoration(color: C.blocked, shape: BoxShape.circle)),
                ),
              // idle shows no mark, as on the desktop
              if (s.status.isNotEmpty && s.status != 'idle') Padding(padding: const EdgeInsets.only(left: 10), child: StatusShape(s.status, blink: s.blink)),
            ]),
          ),
        ),
      ),
      ),
     ),
    );
  }

  Widget _card(Session s) {
    final blocked = s.status == 'blocked';
    final snippet = snippets[s.id] ?? '';
    final options = blocked ? promptOptions(snippet) : const <PromptOption>[];
    // the card's text is up to 2 s old: answer only if the question on screen is still the one shown
    Future<void> send(String keys) async {
      try {
        final now = '${(await m.call('session.text', target: s.id, args: {'lines': 12}))['text'] ?? ''}';
        if (promptTail(now) != promptTail(snippet)) {
          if (!mounted) return;
          setState(() => snippets[s.id] = now);
          return report(context, 'The question changed. Check it and answer again.');
        }
      } catch (_) {
        // can't re-read: the send below reports the same failure
      }
      if (mounted) await reportOf(context, m.act('session.type', target: s.id, args: {'text': keys}));
    }

    return Material(
      color: blocked ? C.blockedBg : C.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: blocked ? C.blockedLine : C.line)),
      child: InkWell(
        key: Key('card-${s.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => open(s.id),
        onLongPress: () => showSessionActions(context, m, s),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
            Row(children: [
              AgentIcon(s.agent, background: blocked ? C.blockedTile : C.surface2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 1, children: [
                  Text(s.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                      [s.workspaceName, if (s.agent.isNotEmpty) agentNames[s.agent] ?? s.agent, if (s.unseen > 0) '${s.unseen} new'].join(' · '),
                      style: const TextStyle(fontSize: 12.5, color: C.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (s.status != 'idle') ...[
                const SizedBox(width: 10),
                Semantics(label: statusLabel(s.status), child: StatusShape(s.status, blink: s.blink)),
              ],
            ]),
            if (blocked && snippet.trim().isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: C.term, borderRadius: BorderRadius.circular(10)),
                child: Text(promptTail(snippet), style: const TextStyle(fontFamily: mono, fontSize: 11.5, height: 1.5, color: C.termText), maxLines: 6),
              ),
            if (blocked)
              Row(children: [
                if (options.isNotEmpty)
                  for (final (i, o) in options.take(2).indexed) ...[
                    Expanded(child: _cardButton('${o.key} · ${o.label}', () => send(o.key), primary: i == 0)),
                    const SizedBox(width: 8),
                  ]
                else ...[
                  Expanded(child: _cardButton('⏎ Enter', () => send('\r'), primary: true)),
                  const SizedBox(width: 8),
                ],
                SizedBox(width: 72, child: _cardButton('Esc', () => send('\x1b'))),
              ]),
          ]),
        ),
      ),
    );
  }

  Widget _cardButton(String label, VoidCallback onTap, {bool primary = false}) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(11));
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: primary ? FontWeight.w600 : null));
    return SizedBox(
      height: 44,
      child: primary
          ? FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                  backgroundColor: C.blocked, foregroundColor: const Color(0xFF1A1206), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 8), shape: shape),
              child: text,
            )
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                  backgroundColor: C.blockedChip, side: const BorderSide(color: C.blockedLine), padding: const EdgeInsets.symmetric(horizontal: 8), shape: shape),
              child: text,
            ),
    );
  }
}

// agterm-qt's running-row wave: the tint, then the active blue, drifting one period (two row widths) every 4.8 s
class _WavePainter extends CustomPainter {
  _WavePainter(this.phase, this.tint) : super(repaint: phase);
  final Animation<double> phase;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final period = size.width * 2;
    final shader = LinearGradient(
      colors: [tint.withValues(alpha: 0.04), tint.withValues(alpha: 0.20), C.active.withValues(alpha: 0.16), tint.withValues(alpha: 0.04)],
      stops: const [0, 0.25, 0.55, 1],
      tileMode: TileMode.repeated,
    ).createShader(Rect.fromLTWH(-phase.value * period, 0, period, size.height));
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.tint != tint || old.phase != phase;
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.blink = false});
  final String status;
  final bool blink;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (status) {
      'blocked' => (C.blockedText, C.blockedChip),
      'completed' => (C.completedText, const Color(0xFF14241A)),
      'active' => (C.active, C.surface2),
      _ => (C.muted, C.surface2),
    };
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        StatusShape(status, size: 8, blink: blink),
        const SizedBox(width: 6),
        Text(statusLabel(status), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}
