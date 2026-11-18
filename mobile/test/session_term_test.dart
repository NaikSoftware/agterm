import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/decoder.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/link/messages.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/screens/session.dart';
import 'package:elis_mobile/terminal/terminal_view.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:elis_mobile/theme.dart';
import 'package:elis_mobile/watch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show answer, frame, json, pairing, upgradeAnswer;

const _refusal = 'session predates this version; restart it to watch it on the phone';

/// A mux relay that answers the model's control calls on channel 0 and records every frame the phone sends.
class Relay {
  Relay(this.tree, {this.unauthorized = false});

  Map<String, Object> tree;
  final bool unauthorized; // a revoked pairing: auth fails
  final _input = StreamController<Uint8List>();
  final frames = <LinkFrame>[];
  final calls = <String>[];
  final _decoder = LinkDecoder();
  final _lines = LineBuffer();
  final _control = LineBuffer();
  var _framed = false;

  late final link = Link(_input.stream, _phone, () => unawaited(_input.close()), via: 'Wi-Fi');

  void _phone(List<int> bytes) {
    if (_framed) return _decoder.feed(bytes).forEach(_frame);
    _lines.add(bytes);
    for (var line = _lines.next(); line != null; line = _lines.next()) {
      if ('$line\n' == linkUpgradeRequest) {
        _framed = true;
        send(upgradeAnswer);
        return;
      }
      final id = (jsonDecode(line) as Map)['id'];
      send(unauthorized ? utf8.encode('${jsonEncode({'id': id, 'ok': false, 'error': 'unauthorized'})}\n') : answer(id)); // auth
    }
  }

  void _frame(LinkFrame f) {
    frames.add(f);
    if (f.channel != 0 || f.kind != LinkKind.data) return;
    _control.add(f.payload);
    for (var line = _control.next(); line != null; line = _control.next()) {
      final r = jsonDecode(line) as Map;
      calls.add(r['cmd']);
      final result = switch (r['cmd']) {
        'tree' => {'tree': tree},
        'events.read' => {
            'events': {'run': 'r', 'next': 0, 'items': <Object>[]},
          },
        'session.text' => {'text': 'plain text', 'columns': 40},
        _ => <String, Object>{},
      };
      send(frame(LinkKind.data, 0, answer(r['id'], result)));
    }
  }

  void send(List<int> bytes) => _input.add(Uint8List.fromList(bytes));
  void drop() => unawaited(_input.close());

  List<LinkFrame> of(LinkKind k) => [for (final f in frames) if (f.kind == k) f];
  List<Map> get opens => [for (final f in of(LinkKind.open)) jsonDecode(utf8.decode(f.payload)) as Map];
  List<int> get closes => [for (final f in of(LinkKind.close)) f.channel];
  int get lastChannel => of(LinkKind.open).last.channel;
  int get texts => calls.where((c) => c == 'session.text').length;
}

Map<String, Object> treeOf({bool live = true, bool split = false}) => {
      'workspaces': [
        {
          'id': 'w1',
          'name': 'elis',
          'sessions': [
            {
              'id': 's1',
              'name': 'shell',
              'hasSplit': split,
              'surfaces': [
                {'id': 'surface:s1:left', 'kind': 'left', 'backedByZmx': live},
                if (split) {'id': 'surface:s1:right', 'kind': 'right', 'backedByZmx': live},
              ],
            },
          ],
        },
      ],
    };

class FakeSnapshot implements VtSnapshot {
  FakeSnapshot(this.cols, this.rows);
  @override
  final int cols, rows;
  @override
  int get cursorX => 0;
  @override
  int get cursorY => 0;
  @override
  bool get cursorVisible => false;
  @override
  List<VtRow> get lines => const [];
}

class FakeVt implements Vt {
  FakeVt(this.cols, this.rows);
  int cols, rows, resets = 0;
  final written = <int>[];
  bool disposed = false;

  @override
  void write(Uint8List bytes) => written.addAll(bytes);
  @override
  void resize(int cols, int rows) {
    this.cols = cols;
    this.rows = rows;
  }

  @override
  void reset() {
    resets++;
    written.clear();
  }

  @override
  bool mode(int mode) => false;
  @override
  VtSnapshot snapshot() => FakeSnapshot(cols, rows);
  @override
  void dispose() => disposed = true;
}

class Harness {
  Harness(this.t, Map<String, Object> tree) : relays = [Relay(tree)];
  final WidgetTester t;
  final List<Relay> relays; // one per connect; a reconnect takes the next
  final nav = GlobalKey<NavigatorState>();
  final vts = <FakeVt>[];
  late final ElisModel m;
  Relay get r => relays.last;

  Future<void> start({Vt Function(int, int)? vt}) async {
    var n = 0;
    m = ElisModel(pairing, open: (p, {preferBluetooth = false}) {
      if (n == relays.length) relays.add(Relay(relays.first.tree));
      return Connection.open(p, tls: (p, t) async => relays[n++].link);
    })..start();
    await t.pumpWidget(MaterialApp(navigatorKey: nav, theme: buildTheme(), home: const SizedBox()));
    await t.pump(const Duration(milliseconds: 10));
    expect(m.mux, isNotNull);
    expect(m.loaded, isTrue);
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => SessionScreen(model: m, sessionId: 's1', vt: vt ?? (c, r) => FakeVt(c, r)..also(vts.add)))));
    await t.pumpAndSettle(const Duration(milliseconds: 10));
  }

  /// The Mac's tree changes and the phone re-reads it.
  Future<void> retree(Map<String, Object> tree) async {
    for (final x in relays) {
      x.tree = tree;
    }
    await m.refresh();
    await t.pump();
  }

  Future<void> opened({int cols = 80, int rows = 24}) async {
    r.send(json(LinkKind.opened, r.lastChannel, {'cols': cols, 'rows': rows}));
    await t.pump();
    await t.pump(); // the event reaches the screen in this pump, its frame in the next
  }

  Future<void> stop() async {
    await t.pumpWidget(const SizedBox());
    m.dispose();
    for (final x in relays) {
      x.drop();
    }
    await t.pump(const Duration(seconds: 20));
  }
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

void main() {
  testWidgets('livePaneShowsTheTerminal', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    expect(h.r.opens, [
      {'type': 'vt', 'target': 's1', 'pane': 'left'},
    ]);
    await h.opened();
    h.r.send(frame(LinkKind.data, 2, utf8.encode('hello')));
    await t.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byKey(const Key('screen')), findsNothing);
    expect(utf8.decode(h.vts.single.written), 'hello');
    expect([for (final f in h.r.of(LinkKind.credit)) f.creditBytes], [5]);

    // Data before a Resync is still reported; the Grid that follows resizes
    h.r.send([...frame(LinkKind.data, 2, utf8.encode('old')), ...frame(LinkKind.resync, 2), ...frame(LinkKind.grid, 2, LinkFrame.resize(2, 100, 30).payload)]);
    await t.pump();
    expect((h.vts.single.resets, h.vts.single.cols, h.vts.single.rows), (1, 100, 30));
    h.r.send(frame(LinkKind.data, 2, utf8.encode('new')));
    await t.pump();
    expect([for (final f in h.r.of(LinkKind.credit)) f.creditBytes], [5, 3]);

    final texts = h.r.texts;
    await t.pump(const Duration(seconds: 3));
    expect(h.r.texts, texts); // the text poll stops while Term is shown
    expect(h.r.calls, isNot(contains('session.grid'))); // no Fit to phone on the Term view
    final fit = t.widget<OutlinedButton>(find.byKey(const Key('fitPhone')));
    expect(fit.onPressed, isNull); // visible and disabled
    expect(h.r.of(LinkKind.resize), isEmpty);
    expect([for (final f in h.r.frames) if (f.channel >= 2 && f.kind == LinkKind.data) f], isEmpty); // watch only
    await h.stop();
  });

  testWidgets('refusalFallsBackToText', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    h.r.send(json(LinkKind.opened, 2, {'error': _refusal}));
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
    expect(find.text(_refusal), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('plain text'), findsOneWidget);
    expect(h.r.opens.length, 1); // not retried, so not said again
    h.m.notifyListeners(); // a tree refresh
    await t.pump(const Duration(seconds: 6));
    expect(h.r.opens.length, 1);
    expect(find.text(_refusal), findsNothing);
    await h.stop();
  });

  testWidgets('disconnectShowsReconnect', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    h.relays.first.drop();
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('disconnected')), findsOneWidget);
    expect(find.text('Disconnected'), findsNothing); // no refusal notice for a lost link
    expect(h.vts.single.disposed, isTrue);
    await t.pump(const Duration(milliseconds: 1100)); // the reconnect backoff
    await t.pump(const Duration(milliseconds: 10));
    expect(h.relays.length, 2);
    expect(h.r.opens, [
      {'type': 'vt', 'target': 's1', 'pane': 'left'},
    ]);
    expect(h.r.lastChannel, 2); // a new link starts its ids again
    await h.opened();
    expect(find.byKey(const Key('disconnected')), findsNothing);
    expect(find.byType(TerminalView), findsOneWidget);
    await h.stop();
  });

  testWidgets('leavingClosesTheChannel', (t) async {
    AndroidFlutterLocalNotificationsPlugin.registerWith(); // resume asks it whether notifications are on
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (_) async => null);
    Watch.permitted = true; // the link stays up in the background, so the screen itself must close the channel
    addTearDown(() => Watch.permitted = false);
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();

    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(h.r.closes, [2]);
    expect(h.vts.single.disposed, isTrue);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(h.r.lastChannel, 3); // a fresh channel id
    await h.opened();

    h.nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(h.r.closes, [2, 3]);

    // left before OPENED: the channel that opens late is closed
    unawaited(h.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => SessionScreen(model: h.m, sessionId: 's1', vt: FakeVt.new))));
    await t.pumpAndSettle();
    expect(h.r.lastChannel, 4);
    h.nav.currentState!.pop();
    await t.pumpAndSettle();
    await h.opened();
    expect(h.r.closes, [2, 3, 4]);
    await h.stop();
  });

  testWidgets('splitToggleReopensTheOtherPane', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    expect(h.r.closes, [2]);
    expect(h.r.opens.last, {'type': 'vt', 'target': 's1', 'pane': 'right'});
    expect(h.r.lastChannel, 3);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    await h.stop();
  });

  testWidgets('notLivePaneKeepsTheTextView', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await t.pump(const Duration(seconds: 1));
    expect(h.r.opens, isEmpty);
    expect(h.r.calls, contains('session.text'));
    expect(find.text('plain text'), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    await h.stop();
  });

  const lib = 'build/vtshim/libvtshim.dylib';
  testWidgets('livePaneDrawsWithTheRealEmulator', (t) async {
    final h = Harness(t, treeOf());
    await h.start(vt: (c, r) {
      Vt.open(lib);
      return Vt(c, r);
    });
    await h.opened(cols: 20, rows: 3);
    h.r.send(frame(LinkKind.data, 2, utf8.encode('hello\x1b[1;31m!')));
    await t.pump();
    await t.pump();
    final view = t.widget<TerminalView>(find.byType(TerminalView));
    expect(view.snapshot!.lines.first.text, 'hello!');
    expect(view.hold, isFalse);
    await h.stop();
  }, skip: !File(lib).existsSync());

  testWidgets('opensWithoutABlankScreen', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await t.pump(const Duration(seconds: 1)); // OPENED is slow: the text view stays and polls
    expect(find.text('plain text'), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('plain text'), findsNothing);
    await h.stop();
  });

  testWidgets('midStreamCloseReopensOnce', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.send(json(LinkKind.close, 2, {'reason': 'stalled'}));
    await t.pump();
    await t.pump();
    expect(h.r.lastChannel, 3); // reopened, quietly
    expect(find.textContaining('stalled'), findsNothing);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    h.r.send(json(LinkKind.close, 3, {'reason': 'stalled'}));
    await t.pump();
    await t.pump();
    expect(h.r.lastChannel, 3); // a second close soon: text view, said readably
    expect(find.text('The live terminal closed (the phone fell behind). Showing the text view.'), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('plain text'), findsOneWidget);
    await h.stop();
  });

  testWidgets('restartedSessionLeavesTheRefusal', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    h.r.send(json(LinkKind.opened, 2, {'error': _refusal}));
    await t.pump();
    await h.retree(treeOf(live: false)); // restarted: not Live for a moment
    await h.retree(treeOf());
    expect(h.r.lastChannel, 3);
    await h.stop();
  });

  testWidgets('paneThatBecomesOrStopsBeingLive', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    expect(h.r.opens, isEmpty);
    await h.retree(treeOf());
    expect(h.r.lastChannel, 2);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    await h.retree(treeOf(live: false));
    expect(h.r.closes, [2]);
    expect(find.byType(TerminalView), findsNothing);
    await h.stop();
  });

  testWidgets('scrollbackClosesAndReopensTheTerm', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('scrollback')));
    await t.pump();
    expect(h.r.closes, [2]);
    expect(find.byType(TerminalView), findsNothing);
    await t.tap(find.byKey(const Key('scrollback')));
    await t.pump();
    expect(h.r.lastChannel, 3);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    await h.stop();
  });

  testWidgets('revokeShowsTheReason', (t) async {
    final h = Harness(t, treeOf());
    h.relays.add(Relay(treeOf(), unauthorized: true)); // the reconnect finds the pairing revoked
    await h.start();
    final first = h.relays.first;
    first.send(json(LinkKind.opened, 2, {'error': 'revoked'})); // the link closes after it
    await t.pump();
    await t.pump();
    expect(find.text(revokedMessage), findsNothing); // no refusal notice: the link state says it
    await t.pump(const Duration(milliseconds: 1100)); // the reconnect is refused
    await t.pump();
    expect(find.text(revokedMessage), findsOneWidget);
    expect(find.text('Disconnected. Reconnecting…'), findsNothing);
    expect(h.relays.length, 2);
    await h.stop();
  });

  testWidgets('reconnectOpensFromTheNewTree', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.relays.first.tree = treeOf(live: false); // the next link's tree: the pane is no longer Live
    h.relays.first.drop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 1100));
    await t.pump(const Duration(milliseconds: 10));
    expect(h.relays.length, 2);
    expect(h.r.opens, isEmpty); // nothing opened from the old link's tree
    await t.pump(const Duration(seconds: 1));
    expect(find.text('plain text'), findsOneWidget);
    await h.stop();
  });
}
