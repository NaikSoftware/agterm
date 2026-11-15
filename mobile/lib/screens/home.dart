import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../main.dart';
import '../model.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  String filter = 'all';
  final collapsed = <String>{};
  final snippets = <String, String>{}; // blocked session id → the last rows of its screen
  StreamSubscription<Alert>? alerts;
  Timer? snippetTimer;

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
    super.dispose();
  }

  void _onAlert(Alert a) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${a.title}: ${a.body}', maxLines: 2, overflow: TextOverflow.ellipsis),
      action: a.sessionId.isEmpty ? null : SnackBarAction(label: 'Open', onPressed: () => open(a.sessionId)),
    ));
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
                subtitle: Text('${p.host}:${p.port}', style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.muted)),
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
                      reportOf(context, m.act('notify', args: {'body': body.trim(), 'title': 'agterm Mobile'}));
                    }
                  }),
              StatefulBuilder(
                  builder: (context, setSheet) => SwitchListTile(
                        key: const Key('watch'),
                        secondary: const Icon(Icons.notifications_active_outlined, color: C.muted),
                        title: const Text('Alerts in the background'),
                        subtitle: Text(Watch.enabled && !Watch.permitted ? 'Notifications are off for agterm in Android settings' : 'When an agent needs you',
                            style: const TextStyle(fontSize: 12, color: C.muted)),
                        value: Watch.enabled,
                        onChanged: (v) async {
                          await Watch.setEnabled(v);
                          setSheet(() {});
                        },
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
              subtitle: Text('${e['subtitle'] ?? ''}'.replaceFirst(RegExp(r'^/home/[^/]+'), '~'), style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.muted)),
              onTap: () => Navigator.pop(c, '${e['id']}'),
            ),
        ]),
      ),
    );
    if (id != null && mounted) reportOf(context, m.act('recent.open', target: id));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final all = m.sessions.toList();
          final needs = all.where((s) => s.needsYou).toList()..sort((a, b) => a.status == b.status ? 0 : (a.status == 'blocked' ? -1 : 1));
          return Scaffold(
            floatingActionButton: m.state == LinkState.connected && m.workspaces.isNotEmpty
                ? FloatingActionButton.extended(
                    key: const Key('newSession'),
                    onPressed: () => showNewSession(context, m),
                    backgroundColor: C.accent,
                    foregroundColor: C.bg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    icon: const Icon(Icons.add),
                    label: const Text('New session', style: TextStyle(fontWeight: FontWeight.w600)),
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
    final (dot, line) = switch (m.state) {
      LinkState.connected => (C.completed, 'Connected · ${m.pairing.host}'),
      LinkState.connecting => (C.blocked, 'Connecting…'),
      LinkState.offline => (C.danger, 'Offline'),
    };
    final blocked = all.where((s) => s.status == 'blocked').length, done = all.where((s) => s.status == 'completed').length;
    Widget chip(String id, String label, {Color? color}) {
      final on = filter == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: Key('filter-$id'),
          selected: on,
          showCheckmark: false,
          onSelected: (_) => setState(() => filter = on ? 'all' : id),
          avatar: color == null ? null : Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          label: Text(label),
          labelStyle: TextStyle(fontSize: 13, color: on ? C.bg : C.text, fontWeight: on ? FontWeight.w600 : null),
          selectedColor: C.text,
          backgroundColor: C.surface,
          side: BorderSide(color: on ? C.text : C.line),
          shape: const StadiumBorder(),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: showComputers,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: C.surface2, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(10)),
                    child: const Text('>_', style: TextStyle(fontFamily: mono, fontWeight: FontWeight.w700, color: C.accent)),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.pairing.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      Row(children: [
                        Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Flexible(child: Text(line, style: const TextStyle(fontSize: 12, color: C.muted), overflow: TextOverflow.ellipsis)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          IconButton(
            key: const Key('menu'),
            tooltip: 'More',
            onPressed: showMenuSheet,
            style: IconButton.styleFrom(backgroundColor: C.surface, side: const BorderSide(color: C.line), minimumSize: const Size(44, 44)),
            icon: const Icon(Icons.more_horiz, color: C.muted),
          ),
        ]),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            chip('all', 'All'),
            chip('blocked', 'Blocked $blocked', color: C.blocked),
            chip('completed', 'Done $done', color: C.completed),
            chip('flagged', 'Flagged'),
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
          Expanded(child: Text(m.error ?? 'Connecting to ${m.pairing.host}:${m.pairing.port}…', style: const TextStyle(color: C.muted, height: 1.4))),
        ]),
      );

  List<Widget> _body(List<Session> all, List<Session> needs) {
    if (filter != 'all') {
      final list = all.where((s) => filter == 'flagged' ? s.flagged : s.status == filter).toList();
      return [
        if (list.isEmpty)
          SliverToBoxAdapter(
              child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Text(filter == 'flagged' ? 'No flagged sessions' : 'Nothing ${statusLabel(filter).toLowerCase()} right now',
                      textAlign: TextAlign.center, style: const TextStyle(color: C.muted)))),
        SliverList.list(children: [for (final s in list) _row(s, indent: 16, showWorkspace: true)]),
      ];
    }
    return [
      if (needs.isNotEmpty) ...[
        const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, 8), child: Text('NEEDS YOU', style: sectionLabel))),
        SliverList.list(children: [for (final s in needs) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: _card(s))]),
      ],
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: Row(children: [
            const Expanded(child: Text('WORKSPACES', style: sectionLabel)),
            if (m.windows.where((w) => w.open).length > 1) Text('Window: ${m.window?.name ?? ''}', style: const TextStyle(fontSize: 12, color: C.muted)),
          ]),
        ),
      ),
      for (final w in m.workspaces) ...[
        SliverToBoxAdapter(child: _workspaceHeader(w)),
        if (!collapsed.contains(w.id)) SliverList.list(children: [for (final s in w.sessions) _row(s, indent: s.parent.isEmpty ? 32 : 52)]),
      ],
    ];
  }

  Widget _workspaceHeader(Workspace w) => InkWell(
        onTap: () => setState(() => collapsed.contains(w.id) ? collapsed.remove(w.id) : collapsed.add(w.id)),
        onLongPress: () => showWorkspaceActions(context, m, w),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: SizedBox(
            height: 44,
            child: Row(children: [
              Icon(collapsed.contains(w.id) ? Icons.chevron_right : Icons.expand_more, size: 18, color: C.muted),
              const SizedBox(width: 8),
              if (tints[w.tint] != null) ...[
                Container(width: 8, height: 8, decoration: BoxDecoration(color: tints[w.tint], borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(w.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              Text('${w.sessions.length}', style: const TextStyle(fontSize: 12, color: C.muted)),
              IconButton(
                tooltip: 'Workspace actions',
                icon: const Icon(Icons.more_vert, size: 18, color: C.muted),
                onPressed: () => showWorkspaceActions(context, m, w),
              ),
            ]),
          ),
        ),
      );

  Widget _row(Session s, {required double indent, bool showWorkspace = false}) {
    final sub = showWorkspace ? s.workspaceName : (s.context.isNotEmpty ? s.context : (s.parent.isNotEmpty ? 'companion · ${s.shortCwd}' : s.shortCwd));
    return InkWell(
      key: Key('row-${s.id}'),
      onTap: () => open(s.id),
      onLongPress: () => showSessionActions(context, m, s),
      child: Container(
        height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: EdgeInsets.only(left: indent - 8, right: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: s.active ? C.surface : null),
        child: Row(children: [
          StatusDot(s.status),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: TextStyle(fontSize: 14, color: tints[s.tint] ?? C.text), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(sub,
                  style: TextStyle(fontSize: 12, color: C.muted, fontFamily: s.context.isEmpty && !showWorkspace ? mono : null),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (s.flagged) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.flag, size: 16, color: C.accent)),
          if (s.agent.isNotEmpty)
            Padding(padding: const EdgeInsets.only(left: 8), child: Text(s.agent, style: const TextStyle(fontSize: 11, color: C.muted, fontFamily: mono))),
          if (s.unseen > 0)
            Container(
              margin: const EdgeInsets.only(left: 8),
              constraints: const BoxConstraints(minWidth: 20),
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(10)),
              child: Text('${s.unseen}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: C.bg)),
            ),
        ]),
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              AgentIcon(s.agent, background: blocked ? C.blockedChip : C.surface2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                      [s.workspaceName, if (s.agent.isNotEmpty) agentNames[s.agent] ?? s.agent, if (s.unseen > 0) '${s.unseen} new'].join(' · '),
                      style: const TextStyle(fontSize: 12, color: C.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
              StatusChip(s.status),
            ]),
            if (blocked && snippet.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(10)),
                child: Text(promptTail(snippet), style: const TextStyle(fontFamily: mono, fontSize: 11.5, height: 1.45, color: C.termText), maxLines: 6),
              ),
            ],
            if (blocked) ...[
              const SizedBox(height: 10),
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
                Expanded(child: _cardButton('Esc', () => send('\x1b'))),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _cardButton(String label, VoidCallback onTap, {bool primary = false}) => SizedBox(
        height: 44,
        child: primary
            ? FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                    backgroundColor: C.blocked, foregroundColor: const Color(0xFF1A1206), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
              )
            : OutlinedButton(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(
                    backgroundColor: C.blockedChip, side: const BorderSide(color: C.blockedLine), padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
              ),
      );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

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
        StatusDot(status, size: 7),
        const SizedBox(width: 6),
        Text(statusLabel(status), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}
