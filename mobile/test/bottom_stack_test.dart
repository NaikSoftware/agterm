import 'dart:io';

import 'package:elis_mobile/chat/bottom_stack.dart';
import 'package:elis_mobile/chat/checks.dart';
import 'package:elis_mobile/chat/claude_screen.dart';
import 'package:elis_mobile/chat/feed.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

String _raw(String name) => File('test/fixtures/grid/$name.ansi').readAsStringSync();
Grid _g(String name) => gridFromAnsi(_raw(name));

class _Grids extends ChangeNotifier {
  _Grids(this.g);
  Grid g;
  void set(Grid n) {
    g = n;
    notifyListeners();
  }
}

class _Writer implements GateWriter {
  _Writer(this.onWrite);
  final void Function(GateWrite w) onWrite;
  final writes = <GateWrite>[];
  @override
  Future<bool> lead() async => true;
  @override
  Future<bool> write(GateWrite w) async {
    writes.add(w);
    onWrite(w);
    return true;
  }

  @override
  bool pasteSafe(String text) => true;
}

class _Stack {
  _Stack(this.t, String fixture) : grids = _Grids(_g(fixture));

  final WidgetTester t;
  final _Grids grids;
  late final writer = _Writer((w) => onWrite?.call(w));
  void Function(GateWrite w)? onWrite;
  final feed = TranscriptFeed(call: (_) async => const {}, canPoll: () => false, remote: false)..loading = false;
  late final gate =
      WriteGate(grids: grids, grid: () => grids.g, writer: () => writer, remote: () => false, blocked: () => null);

  Future<void> pump({bool remote = false, bool server = false, Checks checks = checks, Grid? grid}) async {
    if (grid != null) grids.g = grid;
    final g = grids.g;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BottomStack(
            screen: ClaudeScreen.read(g), grid: g, feed: feed, gate: gate, stale: false, remote: remote, server: server, checks: checks),
      ),
    ));
  }
}

FilledButton? _button(WidgetTester t, String label) =>
    t.widgetList<FilledButton>(find.ancestor(of: find.text(label), matching: find.byType(FilledButton))).firstOrNull;

bool _enabled(WidgetTester t, String label) => _button(t, label)?.onPressed != null;

ChatItem _text(String text) => ChatItem.fromJson({'kind': 'text', 'uuid': 't1', 'text': text});

const _proven = Checks(keys: true, paste: true, sendNow: true);

void main() {
  testWidgets('stopSendsOneEsc', (t) async {
    final s = _Stack(t, 'working-45');
    await s.pump();
    await t.tap(find.text('Stop'));
    await t.tap(find.text('Stop'), warnIfMissed: false);
    await t.pump(const Duration(seconds: 3));
    expect(s.writer.writes.length, 1);
    expect((s.writer.writes.single as KeyWrite).key, VtKey.escape);
  });

  testWidgets('stopDoneOnInterruptedWithQueue', (t) async {
    final s = _Stack(t, 'working-45');
    s.onWrite = (_) => Future.microtask(() => s.grids.set(_g('interrupted-queued-45')));
    await s.pump();
    await t.tap(find.text('Stop'));
    await t.pump(const Duration(seconds: 3));
    expect(s.writer.writes.length, 1);
    expect(find.byType(SnackBar), findsNothing);
    expect(s.gate.running, isFalse);
  });

  testWidgets('oldInterruptedRowDoesNotEndStop', (t) async {
    final s = _Stack(t, 'interrupted-queued-45');
    s.onWrite = (_) => Future.microtask(() => s.grids.set(_g('interrupted-queued-45')));
    await s.pump();
    await t.tap(find.text('Stop'));
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(s.writer.writes.length, 1);
    expect(find.text("Claude's screen did not change"), findsOneWidget);
  });

  testWidgets('sendNowBlockedOnUnprovenRemote', (t) async {
    final s = _Stack(t, 'queued-45');
    s.feed.meta = TranscriptMeta.fromJson({
      'queued': ['QUEUED reply with just ok'],
    });
    await s.pump(remote: true, checks: _proven);
    expect(_button(t, 'Send now'), isNotNull);
    expect(_enabled(t, 'Send now'), isFalse);
    expect(find.text(_proven.writeBlockedOn(remote: true)!), findsOneWidget);
    expect(_enabled(t, 'Stop'), isTrue);
    await s.pump(remote: true, server: true, checks: const Checks(keys: true, paste: true, sendNow: true, server: true));
    expect(_enabled(t, 'Send now'), isTrue);
  });

  testWidgets('sendNowSendsCtrlXThenCtrlS', (t) async {
    final s = _Stack(t, 'queued-45');
    s.feed.meta = TranscriptMeta.fromJson({
      'queued': ['QUEUED reply with just ok'],
    });
    var n = 0;
    s.onWrite = (_) => Future.microtask(() => s.grids.set(_g(++n == 1 ? 'working-thinking-45' : 'working-45')));
    await s.pump(checks: _proven);
    await t.tap(find.text('Send now'));
    await t.pump(const Duration(seconds: 3));
    expect([for (final w in s.writer.writes) ((w as KeyWrite).key, w.mods)], [(VtKey.x, vtCtrl), (VtKey.s, vtCtrl)]);
  });

  testWidgets('stopDisabledOnDialog', (t) async {
    final lines = _raw('dialog-bash-45').split('\n');
    lines[21] = '✶ Wrangling… (3s · ↓ 40 tokens)';
    final g = gridFromAnsi(lines.join('\n'));
    expect(ClaudeScreen.read(g).dialog, isTrue);
    final s = _Stack(t, 'dialog-bash-45');
    await s.pump(grid: g);
    expect(find.textContaining('Wrangling…'), findsOneWidget);
    expect(_enabled(t, 'Stop'), isFalse);
  });

  testWidgets('queuedNeedsBothSources', (t) async {
    final g = _Stack(t, 'queued-45');
    await g.pump(checks: _proven);
    expect(find.text('QUEUED reply with just ok'), findsNothing);

    final tOnly = _Stack(t, 'working-45');
    tOnly.feed.meta = TranscriptMeta.fromJson({
      'queued': ['QUEUED reply with just ok'],
    });
    await tOnly.pump(checks: _proven);
    expect(find.text('QUEUED reply with just ok'), findsNothing);

    g.feed.meta = TranscriptMeta.fromJson({
      'queued': ['QUEUED reply with just ok'],
    });
    await g.pump(checks: _proven);
    expect(find.text('QUEUED reply with just ok'), findsOneWidget);
  });

  testWidgets('sendNowHiddenUntilProven', (t) async {
    final s = _Stack(t, 'queued-45');
    s.feed.meta = TranscriptMeta.fromJson({
      'queued': ['QUEUED reply with just ok'],
    });
    await s.pump();
    expect(find.text('QUEUED reply with just ok'), findsOneWidget);
    expect(find.text('Send now'), findsNothing);
  });

  testWidgets('statuslineFirstRowExpands', (t) async {
    final s = _Stack(t, 'bash-mode-45');
    await s.pump();
    final g = s.grids.g;
    final rows = ClaudeScreen.read(g).statusRows;
    expect(rows.length, 2);
    final first = g.text(rows[0]).trim(), second = g.text(rows[1]).trim();
    expect(find.textContaining(first), findsOneWidget);
    expect(find.textContaining(second), findsNothing);
    final line = t.widget<RichText>(find.descendant(of: find.byKey(const Key('statusline')), matching: find.byType(RichText)).first);
    expect(line.maxLines, 1);
    await t.tap(find.byKey(const Key('statusline')));
    await t.pump();
    expect(find.textContaining(first), findsOneWidget);
    expect(find.textContaining(second), findsOneWidget);
  });

  testWidgets('statuslineStaleUnderDialog', (t) async {
    final s = _Stack(t, 'idle-placeholder-45');
    await s.pump();
    final g = s.grids.g;
    final first = g.text(ClaudeScreen.read(g).statusRows.first).trim();
    Opacity opacity() => t.widget<Opacity>(find.ancestor(of: find.textContaining(first), matching: find.byType(Opacity)).first);
    expect(opacity().opacity, 1);
    await s.pump(grid: _g('dialog-bash-45'));
    expect(find.textContaining(first), findsOneWidget);
    expect(opacity().opacity, lessThan(1));
    await s.pump(grid: _g('idle-placeholder-45'));
    expect(opacity().opacity, 1);
  });

  testWidgets('statuslinePlainOnTextGrid', (t) async {
    final s = _Stack(t, 'idle-placeholder-45');
    final g = s.grids.g;
    final plain = Grid.text([for (var r = 0; r < g.rows.length; r++) g.text(r)].join('\n'));
    await s.pump(grid: plain);
    final first = g.text(ClaudeScreen.read(g).statusRows.first).trim();
    final line = t.widget<RichText>(find.descendant(of: find.byKey(const Key('statusline')), matching: find.byType(RichText)).first);
    var coloured = 0;
    line.text.visitChildren((span) {
      if (span != line.text && span.style?.color != null) coloured++;
      return true;
    });
    expect(coloured, 0);
    expect(line.text.toPlainText(), contains(first));
  });

  testWidgets('streamingHidesOnceInTranscript', (t) async {
    final s = _Stack(t, 'working-45');
    await s.pump();
    expect(find.textContaining('Fishermen read it like a page.'), findsOneWidget);
    s.feed.items.add(_text('An older reply'));
    await s.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('Fishermen read it like a page.'), findsOneWidget);
    s.feed.items.add(_text('# The Sea Keeps\nIts **Own** Time\n\nmore'));
    await s.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('Fishermen read it like a page.'), findsNothing);
  });

  testWidgets('limitBannerCancel', (t) async {
    final s = _Stack(t, 'limit-45');
    s.onWrite = (_) => Future.microtask(() => s.grids.set(_g('idle-placeholder-45')));
    await s.pump();
    expect(find.textContaining('Usage limit reached'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pump(const Duration(seconds: 3));
    expect((s.writer.writes.single as KeyWrite).key, VtKey.escape);
    expect(find.byType(SnackBar), findsNothing);
  });
}
