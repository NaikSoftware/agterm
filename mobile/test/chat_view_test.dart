import 'dart:async';
import 'dart:io';

import 'package:elis_mobile/chat/chat_composer.dart';
import 'package:elis_mobile/chat/chat_view.dart';
import 'package:elis_mobile/chat/claude_screen.dart';
import 'package:elis_mobile/chat/feed.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/mode.dart';
import 'package:elis_mobile/chat/rows.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show json;
import 'session_term_test.dart' show Harness, treeOf;
import 'support/ansi.dart';

class _Host {
  final calls = <(Map<String, dynamic>, Completer<Map<String, dynamic>>)>[];

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) {
    final c = Completer<Map<String, dynamic>>();
    calls.add((args, c));
    return c.future;
  }

  (Map<String, dynamic>, Completer<Map<String, dynamic>>)? get held => calls.where((c) => !c.$2.isCompleted).lastOrNull;
}

Map<String, dynamic> _text(String uuid, [int lines = 0]) =>
    {'kind': 'text', 'uuid': uuid, 'text': [uuid, for (var n = 0; n < lines; n++) 'more $n'].join('\n\n')};
Map<String, dynamic> _prompt(String uuid) => {'kind': 'user', 'uuid': uuid, 'text': uuid, 'promptSource': 'typed'};
Map<String, dynamic> _tool(String uuid) => {'kind': 'tool', 'uuid': uuid, 'name': 'Bash', 'arg': uuid};
Map<String, dynamic> _command(String uuid, String name) => {'kind': 'command', 'uuid': uuid, 'name': name};

// uneven heights: a lazy list estimates unbuilt rows from the built ones
List<Map<String, dynamic>> _history(int n) => [
      for (var i = 0; i < n; i++)
        switch (i % 3) {
          0 => _prompt('p$i'),
          1 => _text('t$i', i % 5),
          _ => _tool('b$i'),
        },
    ];

class _Chat {
  _Chat(this.t);

  final WidgetTester t;
  final h = _Host();
  late final feed = TranscriptFeed(call: h.call, canPoll: () => true, remote: false);
  int _next = 100;

  var terms = 0;

  Future<void> start(List<Map<String, dynamic>>? items,
      {Map<String, dynamic> meta = const {},
      int start = 0,
      bool exited = false,
      bool stale = false,
      bool running = false,
      double height = 800}) async {
    t.view.physicalSize = Size(400, height);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = Session(
        {'id': 's1', 'name': 'Session one', 'cwd': '/work/elis', if (running) ...{'agent': 'claude', 'agentSessionId': 'a1'}}, 'w', 'W');
    final gate = WriteGate(
        grids: ChangeNotifier(), grid: () => null, writer: () => throw UnimplementedError(), remote: () => false, blocked: () => null);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        appBar: AppBar(title: ChatTitle(feed: feed, s: s)),
        body: ChatView(
            feed: feed,
            grid: () => null,
            grids: ChangeNotifier(),
            gate: gate,
            s: s,
            exited: exited,
            stale: stale,
            onTerm: () => terms++,
            switcher: const Text('switcher')),
      ),
    ));
    feed.start();
    if (items != null) await reply(items, meta: meta, start: start);
  }

  /// Answers the held tail poll with [items] after the cursor.
  Future<void> reply(List<Map<String, dynamic>> items, {Map<String, dynamic> meta = const {}, int start = 0, String transcript = 't1'}) async {
    await t.pump();
    _next += 10;
    h.held!.$2.complete({'transcript': transcript, 'size': _next, 'start': start, 'next': _next, 'items': items, 'meta': meta});
    await t.pump();
    await t.pump();
    await t.pump(); // the post-frame scroll bookkeeping
  }

  /// Lets the next tail poll go out.
  Future<void> tick() => t.pump(const Duration(milliseconds: 800));
}

/// A widget test over a [_Chat], which leaves no feed timer behind.
void _chatTest(String name, Future<void> Function(WidgetTester t, _Chat c) body) => testWidgets(name, (t) async {
      final c = _Chat(t);
      await body(t, c);
      await t.pumpWidget(const SizedBox());
      c.feed.dispose();
    });

Finder _row(String uuid) => find.text(uuid, findRichText: true);

Rect _list(WidgetTester t) => t.getRect(find.byKey(const Key('chatList')));

/// The uuids of [items] whose row is fully on screen.
List<String> _onScreen(WidgetTester t, List<Map<String, dynamic>> items) {
  final list = _list(t);
  return [
    for (final i in items)
      if (_row(i['uuid'] as String).evaluate().isNotEmpty)
        if (t.getRect(_row(i['uuid'] as String).first) case final r when r.top >= list.top && r.bottom <= list.bottom) i['uuid'] as String,
  ];
}

double _pixels(WidgetTester t) => t.widget<ListView>(find.byKey(const Key('chatList'))).controller!.position.pixels;

void main() {
  test('stickyPromptIsNearestAbove', () {
    final rows = chatRows([
      for (final m in [_prompt('u1'), _text('a1'), {'kind': 'user', 'uuid': 'tool-result'}, _prompt('u2'), _text('a2'), _text('a3')])
        ChatItem.fromJson(m),
    ]);
    expect([for (final r in rows) r.key], ['a3', 'a2', 'u2', 'tool-result', 'a1', 'u1']);
    expect(stickyPrompt(rows, 0), 2);
    expect(stickyPrompt(rows, 2), 5);
    expect(stickyPrompt(rows, 5), isNull);
  });

  test('modelLabel', () {
    expect(modelLabel('claude-opus-4-5', 'medium'), 'Opus · medium');
    expect(modelLabel('claude-sonnet-4-5[1m]', null), 'Sonnet');
    expect(modelLabel('gpt-x', 'high'), 'gpt-x · high');
    expect(modelLabel(null, null), '');
  });

  _chatTest('stickyTapScrollsToPrompt', (t, c) async {
    await c.start([_prompt('first prompt'), for (var i = 0; i < 40; i++) _text('r$i', i % 4)]);
    expect(_row('first prompt'), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('stickyPrompt')), matching: find.text('❯ first prompt')), findsOneWidget);
    await t.tap(find.byKey(const Key('stickyPrompt')));
    await t.pumpAndSettle();
    expect(_onScreen(t, [_prompt('first prompt')]), ['first prompt']);
  });

  _chatTest('stickyHoldsItsPromptThroughAppend', (t, c) async {
    await c.start([_prompt('first prompt'), for (var i = 0; i < 40; i++) _text('r$i', i % 4)]);
    await c.tick();
    await t.pump();
    c.h.held!.$2.complete({'transcript': 't1', 'size': 300, 'start': 0, 'next': 300, 'items': [_text('n1'), _text('n2'), _tool('n3')]});
    await Future<void>.value();
    await t.pump();
    expect(_row('n1'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('stickyPrompt')), matching: find.text('❯ first prompt')), findsOneWidget);
  });

  _chatTest('appendWhileScrolledUpKeepsView', (t, c) async {
    final items = _history(40);
    await c.start(items);
    await t.drag(find.byKey(const Key('chatList')), const Offset(0, 400));
    await t.pumpAndSettle();
    final anchor = _onScreen(t, items).first;
    final before = t.getRect(_row(anchor).first).top;
    await c.tick();
    await c.reply([_text('n1', 6), _prompt('n2'), _tool('n3')]);
    await t.pump();
    expect(t.getRect(_row(anchor).first).top, before);
    expect(find.text('↓ 3 new'), findsOneWidget);
    await t.tap(find.byKey(const Key('jumpToBottom')));
    await t.pumpAndSettle();
    expect(_pixels(t), 0);
    expect(find.byKey(const Key('jumpToBottom')), findsNothing);
  });

  for (final append in [false, true]) {
    _chatTest('pollMidDragKeepsScrolling${append ? 'WithAppend' : ''}', (t, c) async {
      final items = _history(40);
      await c.start(items);
      final g = await t.startGesture(t.getCenter(find.byKey(const Key('chatList'))));
      for (var n = 0; n < 5; n++) {
        await g.moveBy(const Offset(0, 40));
        await t.pump();
      }
      await c.tick();
      final before = _pixels(t);
      final anchor = _onScreen(t, items).first;
      final top = t.getRect(_row(anchor).first).top;
      c.h.held!.$2.complete({
        'transcript': 't1', 'size': 300, 'start': 0, 'next': 300, //
        'items': append ? [_text('n1', 2), _prompt('n2'), _tool('n3')] : [],
      });
      await Future<void>.value();
      await g.moveBy(const Offset(0, 50)); // the user's finger moves before the reply's frame
      await t.pump();
      await t.pump();
      final settled = _pixels(t);
      expect(settled, greaterThan(before + 40));
      expect(t.getRect(_row(anchor).first).top, top + 50);
      await g.moveBy(const Offset(0, 50));
      await t.pump();
      expect(_pixels(t), settled + 50);
      await g.up();
      await t.pumpAndSettle();
    });
  }

  _chatTest('atBottomFollows', (t, c) async {
    await c.start(_history(40));
    await c.tick();
    await c.reply([_text('n1', 6), _prompt('n2')]);
    await t.pumpAndSettle();
    expect(_pixels(t), 0);
    expect(_onScreen(t, [_prompt('n2')]), ['n2']);
    expect(find.byKey(const Key('jumpToBottom')), findsNothing);
  });

  _chatTest('pagingBackPrepends', (t, c) async {
    final items = _history(30);
    await c.start(items, start: 50, height: 870); // the composer's 70: the first page-back request leaves its row on screen
    for (var n = 0; n < 10 && c.h.held?.$1['before'] == null; n++) {
      await t.drag(find.byKey(const Key('chatList')), const Offset(0, 600));
      await t.pump();
    }
    expect(c.h.held!.$1['before'], '50');
    await t.pumpAndSettle();
    expect(find.text('Loading earlier…'), findsOneWidget);
    final anchor = _onScreen(t, items).last;
    final before = t.getRect(_row(anchor).first).top;
    c.h.held!.$2.complete({'transcript': 't1', 'size': 200, 'start': 0, 'next': 50, 'items': [_text('old1', 3), _prompt('old2')]});
    await t.pump();
    await t.pump();
    expect(find.text('Loading earlier…'), findsNothing);
    expect(t.getRect(_row(anchor).first).top, before);
    expect(find.textContaining('new'), findsNothing);
  });

  for (final tail in [false, true]) {
    _chatTest('pagingBackAtTopKeepsTheReadRow${tail ? 'OnAnAppend' : ''}', (t, c) async {
      final items = _history(30);
      await c.start(items, start: 50, height: 800);
      for (var n = 0; n < 10 && c.h.held?.$1['before'] == null; n++) {
        await t.drag(find.byKey(const Key('chatList')), const Offset(0, 600));
        await t.pump();
      }
      final page = c.h.held!;
      expect(page.$1['before'], '50');
      await t.drag(find.byKey(const Key('chatList')), const Offset(0, 3000));
      await t.pumpAndSettle();
      final p = t.state<ScrollableState>(find.descendant(of: find.byKey(const Key('chatList')), matching: find.byType(Scrollable))).position;
      expect(p.pixels, p.maxScrollExtent);
      final anchor = _onScreen(t, items).last;
      final before = t.getRect(_row(anchor).first).top;
      if (tail) {
        await c.tick();
        c.h.held!.$2.complete({'transcript': 't1', 'size': 300, 'start': 50, 'next': 300, 'items': [_text('n1', 3), _prompt('n2')]});
      } else {
        page.$2.complete({'transcript': 't1', 'size': 200, 'start': 0, 'next': 50, 'items': [_text('old1', 3), _prompt('old2')]});
      }
      // every painted frame, not only the settled one
      for (var n = 0; n < 3; n++) {
        await t.pump();
        expect(t.getRect(_row(anchor).first).top, before, reason: 'frame $n');
      }
      expect(find.text(tail ? '↓ 2 new' : 'Loading earlier…'), tail ? findsOneWidget : findsNothing);
    });
  }

  _chatTest('modelChipDimsAfterModelCommand', (t, c) async {
    const meta = {'title': 'Echo todo', 'model': 'claude-opus-4-5', 'effort': 'medium'};
    await c.start([_prompt('p1'), _text('a1')], meta: meta);
    expect(find.text('Echo todo'), findsOneWidget);
    double opacity() => t.widget<Opacity>(find.ancestor(of: find.text('Opus · medium'), matching: find.byType(Opacity))).opacity;
    expect(opacity(), 1);
    await c.tick();
    await c.reply([_command('m1', 'model')], meta: meta);
    expect(opacity(), lessThan(1));
    await c.tick();
    await c.reply([_text('a2')], meta: meta);
    expect(opacity(), 1);
  });

  testWidgets('modelChipSendsModel', (t) async {
    Grid g(String name) => gridFromAnsi(File('test/fixtures/grid/$name.ansi').readAsStringSync());
    final idle = g('idle-placeholder-45');
    var grid = idle;
    final grids = ChangeNotifier();
    final writes = <GateWrite>[];
    final writer = TypeWriter((text) async {
      writes.add(text == '\r' ? KeyWrite(VtKey.enter) : PasteWrite(text));
      Future.microtask(() {
        final (a, b) = ClaudeScreen.read(idle).inputRows!;
        grid = text == '\r' ? g('panel-model-45') : Grid([...idle.rows]..replaceRange(a, b, [VtRow([for (final r in '❯ /model'.runes) VtCell(String.fromCharCode(r))])]));
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        grids.notifyListeners();
      });
      return null;
    });
    final gate = WriteGate(grids: grids, grid: () => grid, writer: () => writer, remote: () => false, blocked: () => null);
    final feed = TranscriptFeed(call: (_) async => const {}, canPoll: () => false, remote: false)
      ..loading = false
      ..meta = TranscriptMeta.fromJson({'model': 'claude-opus-4-5'});
    final s = Session({'id': 's1', 'name': 'Session one', 'cwd': '/work/elis'}, 'w', 'W');
    final composer = GlobalKey<ChatComposerState>();
    Future<void> pump({required bool idle}) => t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            appBar: AppBar(title: ChatTitle(feed: feed, s: s, onChangeModel: idle ? () => composer.currentState?.send('/model') : null)),
            body: ChatView(
                feed: feed,
                grid: () => grid,
                grids: grids,
                gate: gate,
                s: s,
                exited: false,
                stale: false,
                onTerm: () {},
                switcher: const SizedBox(),
                composer: composer),
          ),
        ));
    await pump(idle: false);
    await t.tap(find.byKey(const Key('modelChip')));
    await t.pumpAndSettle();
    expect(t.widget<PopupMenuItem<void>>(find.ancestor(of: find.text('Change model…'), matching: find.byType(PopupMenuItem<void>))).enabled,
        isFalse);
    await t.tapAt(const Offset(10, 500)); // the barrier
    await t.pumpAndSettle();
    expect(find.text('Change model…'), findsNothing);

    await pump(idle: true);
    await t.enterText(find.byKey(const Key('composer')), 'an unsent draft');
    await t.tap(find.byKey(const Key('modelChip')));
    await t.pumpAndSettle();
    await t.tap(find.text('Change model…'));
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect([for (final w in writes) w is PasteWrite ? w.text : (w as KeyWrite).key], ['/model', VtKey.enter]);
    expect(t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'an unsent draft');
    await t.pumpWidget(const SizedBox());
    feed.dispose();
  });

  _chatTest('titleFallsBackToSessionName', (t, c) async {
    await c.start([_text('a1')]);
    expect(find.text('Session one'), findsOneWidget);
  });

  _chatTest('prChipOpensUrl', (t, c) async {
    final opens = <MethodCall>[];
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('elis/open'), (m) async {
      opens.add(m);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('elis/open'), null));
    await c.start([_text('a1')], meta: {
      'pr': {'prNumber': 446, 'prRepository': 'o/elis', 'prUrl': 'https://github.com/o/elis/pull/446'},
    });
    expect(find.text('/work/elis'), findsOneWidget);
    await t.tap(find.text('PR #446'));
    expect([for (final o in opens) (o.method, o.arguments)], [('view', 'https://github.com/o/elis/pull/446')]);
  });

  _chatTest('todoStripHidesWhenAllDone', (t, c) async {
    Map<String, dynamic> todos(String second) => {
          'todos': [
            {'content': 'Write code', 'status': 'completed'},
            {'content': 'Write tests', 'status': second},
          ],
        };
    await c.start([_text('a1')], meta: todos('in_progress'));
    expect(find.text('☐ 1/2 · Write tests'), findsOneWidget);
    expect(find.text('Write code'), findsNothing);
    await t.tap(find.byKey(const Key('todoStrip')));
    await t.pumpAndSettle();
    expect(find.textContaining('Write code'), findsOneWidget);
    await c.tick();
    await c.reply([], meta: todos('completed'));
    expect(find.byKey(const Key('todoStrip')), findsNothing);
  });

  _chatTest('headerCollapsesOnScrollUp', (t, c) async {
    await c.start(_history(40));
    bool shown() => t.getSize(find.byKey(const Key('chatHeader'))).height > 0;
    expect(find.text('switcher'), findsOneWidget);
    expect(shown(), isTrue);
    await t.drag(find.byKey(const Key('chatList')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(shown(), isFalse);
    await t.drag(find.byKey(const Key('chatList')), const Offset(0, -100));
    await t.pumpAndSettle();
    expect(shown(), isTrue);
  });

  group('states', () {
    tearDown(() {
      ModePicks.pick('s1', null);
      ModePicks.tooOld.clear();
    });

    _chatTest('emptyState', (t, c) async {
      await c.start([]);
      expect(find.text('Claude is ready'), findsOneWidget);
      for (final cmd in ['help', 'model', 'usage']) {
        expect(find.byKey(Key('emptyCommand-$cmd')), findsOneWidget);
      }
      expect(find.byKey(const Key('chatSkeleton')), findsNothing);
    });

    _chatTest('emptyStateFillsTheField', (t, c) async {
      await c.start([]);
      await t.tap(find.byKey(const Key('emptyCommand-usage')));
      await t.pump();
      expect(t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, '/usage ');
    });

    _chatTest('loadingSkeleton', (t, c) async {
      await c.start(null);
      await t.pump();
      expect(find.byKey(const Key('chatSkeleton')), findsOneWidget);
      expect(find.text('Claude is ready'), findsNothing);
      await c.reply([_text('a1')]);
      expect(find.byKey(const Key('chatSkeleton')), findsNothing);
      expect(_row('a1'), findsOneWidget);
    });

    for (final (name, error) in [('NotFound', 'transcript not found'), ('Other', 'boom')]) {
      _chatTest('unreadableShowsRetryAndTerm$name', (t, c) async {
        await c.start(null);
        await t.pump();
        c.h.held!.$2.completeError(Exception(error));
        await t.pump();
        await t.pump();
        expect(find.byKey(const Key('chatUnreadable')), findsOneWidget);
        expect(find.byKey(const Key('chatList')), findsNothing);
        expect(find.text('switcher'), findsOneWidget);
        await t.tap(find.byKey(const Key('chatTerm')));
        expect(c.terms, 1);
        await t.tap(find.byKey(const Key('chatRetry')));
        await c.reply([_text('a1')]);
        expect(find.byKey(const Key('chatUnreadable')), findsNothing);
        expect(_row('a1'), findsOneWidget);
      });
    }

    _chatTest('notFoundWhileClaudeRunsIsEmptyAndKeepsPolling', (t, c) async {
      await c.start(null, running: true);
      await t.pump();
      c.h.held!.$2.completeError(Exception('transcript not found'));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('chatUnreadable')), findsNothing);
      expect(find.byKey(const Key('chatError')), findsNothing);
      expect(find.text('Claude is ready'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const Key('composer'))).enabled, isNot(false));
      await c.tick();
      await c.reply([_text('a1')]);
      expect(_row('a1'), findsOneWidget);
    });

    _chatTest('pollFailureKeepsHistoryUnderABanner', (t, c) async {
      await c.start([_prompt('p1'), _text('a1')]);
      await c.tick();
      c.h.held!.$2.completeError(Exception('boom'));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('chatUnreadable')), findsNothing);
      expect(find.byKey(const Key('chatError')), findsOneWidget);
      expect(_row('a1'), findsOneWidget);
      await t.tap(find.byKey(const Key('chatErrorRetry')));
      await c.reply([_text('a2')]);
      expect(find.byKey(const Key('chatError')), findsNothing);
      expect(_row('a1'), findsOneWidget);
      expect(_row('a2'), findsOneWidget);
    });

    _chatTest('switchClearsTransientMarks', (t, c) async {
      await c.start([..._history(40), _tool('a1'), {'kind': 'tool', 'uuid': 'ag1', 'name': 'Agent', 'arg': 'probe', 'running': true, 'mark': 'running'}]);
      expect(find.text('◯ running'), findsOneWidget);
      await t.drag(find.byKey(const Key('chatList')), const Offset(0, 300));
      await t.pumpAndSettle();
      expect(t.getSize(find.byKey(const Key('chatHeader'))).height, 0);
      await c.tick();
      await c.reply([], transcript: 't2');
      expect(find.text('◯ running'), findsNothing);
      expect(find.byKey(const Key('chatSkeleton')), findsOneWidget);
      expect(find.text('switcher'), findsOneWidget); // no list left to scroll the header back with
      await c.reply([_text('n1')], transcript: 't2');
      expect(_row('n1'), findsOneWidget);
      expect(find.byKey(const Key('jumpToBottom')), findsNothing);
      expect(find.text('switcher'), findsOneWidget);
    });

    _chatTest('staleStopsOpenSubagents', (t, c) async {
      await c.start([{'kind': 'tool', 'uuid': 'ag1', 'name': 'Agent', 'arg': 'probe', 'running': true, 'mark': 'running'}], stale: true);
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('stopped'), findsOneWidget);
    });

    test('blockedReason', () {
      expect(ChatView.blockedReason(exited: true, stale: true), 'Claude exited');
      expect(ChatView.blockedReason(exited: false, stale: true), 'Reconnecting…');
      expect(ChatView.blockedReason(exited: false, stale: false), isNull);
    });

    ChatView view(WidgetTester t) => t.widget<ChatView>(find.byType(ChatView));
    // a write that is not blocked would wait on the lead: read the result after one pump instead of awaiting it
    Future<GateResult?> write(WidgetTester t) async {
      GateResult? r;
      unawaited(view(t).gate.run(1, (s) => s.send(GateStep(KeyWrite(VtKey.arrowUp), ready: (_) => true, done: (_) => true))).then((v) => r = v));
      await t.pump();
      return r;
    }
    const claude = {'agent': 'claude', 'agentSessionId': 'c1'};

    for (final (host, shown) in [('', 'the computer'), ('studio', 'studio')]) {
      testWidgets('hostTooOldDisablesChat${host.isEmpty ? '' : 'Remote'}', (t) async {
        final h = Harness(t, treeOf(session: {...claude, if (host.isNotEmpty) 'remoteHost': host}));
        h.r.errors['session.transcript'] = 'unknown command: session.transcript';
        await h.start();
        await t.pump(const Duration(milliseconds: 100));
        expect(find.byType(ChatView), findsNothing);
        expect(find.text('Update Elis on $shown'), findsOneWidget);
        expect(t.widget<OutlinedButton>(find.byKey(const Key('modeChat'))).onPressed, isNull);
        // the reason stays on the disabled segment after the notice is gone
        expect(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Update Elis on $shown'), findsOneWidget);
        final calls = h.r.transcriptArgs.length;
        await t.pump(const Duration(seconds: 5));
        expect(h.r.transcriptArgs.length, calls);
        await h.stop();
      });
    }

    testWidgets('exitedBannerDisablesWrites', (t) async {
      final h = Harness(t, treeOf(session: claude));
      h.r.transcript = {'transcript': 't1', 'size': 10, 'start': 0, 'next': 10, 'items': [_text('a1')]};
      await h.start();
      await h.opened();
      expect(_row('a1'), findsOneWidget);
      await h.retree(treeOf(session: {'agentSessionId': 'c1'}));
      await t.pump();
      expect(find.text('Claude exited'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('chatExited')), matching: find.text('Term')), findsOneWidget);
      final r = await write(t);
      expect((r?.outcome, r?.reason), (GateOutcome.blocked, 'Claude exited'));
      h.r.errors['session.transcript'] = 'no adapter';
      await t.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('chatUnreadable')), findsNothing); // the history stays
      expect(_row('a1'), findsOneWidget);
      await h.stop();
    });

    testWidgets('staleDimsAndBlocks', (t) async {
      final h = Harness(t, treeOf(session: claude));
      await h.start();
      await h.opened();
      expect(view(t).stale, isFalse);
      h.r.send(json(LinkKind.close, h.r.lastWatch, {'reason': 'stalled'}));
      await t.pump();
      await t.pump();
      expect(view(t).stale, isTrue);
      expect(find.text('Reconnecting…'), findsOneWidget);
      final r = await write(t);
      expect((r?.outcome, r?.reason), (GateOutcome.blocked, 'Reconnecting…'));
      await h.opened(); // the quiet reopen
      expect(view(t).stale, isFalse);
      expect(find.text('Reconnecting…'), findsNothing);
      await h.stop();
    });

    testWidgets('connectingIsNotStale', (t) async {
      final h = Harness(t, treeOf(session: claude));
      await h.start();
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(seconds: 1));
        expect(view(t).stale, isFalse);
      }
      expect(find.text('Reconnecting…'), findsNothing);
      await h.stop();
    });
  });
}
