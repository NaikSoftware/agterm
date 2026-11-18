import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/decoder.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/link/messages.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/screens/session.dart';
import 'package:elis_mobile/terminal/row_cache.dart';
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
  final grids = <Map>[]; // session.grid arguments
  final scrolls = <Map>[]; // session.scroll arguments
  final textArgs = <Map>[]; // session.text arguments
  final refused = <String>{}; // commands answered with an error
  final held = <String, List<List<int>>>{}; // answers kept back until the test sends them
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
      if (r['cmd'] == 'session.grid') grids.add(r['args'] as Map);
      if (r['cmd'] == 'session.scroll') scrolls.add(r['args'] as Map);
      if (r['cmd'] == 'session.text') textArgs.add(r['args'] as Map);
      if (refused.contains(r['cmd'])) {
        send(frame(LinkKind.data, 0, utf8.encode('${jsonEncode({'id': r['id'], 'ok': false, 'error': 'refused ${r['cmd']}'})}\n')));
        continue;
      }
      if (held[r['cmd']] case final q?) {
        q.add(frame(LinkKind.data, 0, answer(r['id'])));
        continue;
      }
      final result = switch (r['cmd']) {
        'tree' => {'tree': tree},
        'events.read' => {
            'events': {'run': 'r', 'next': 0, 'items': <Object>[]},
          },
        'session.text' => {'text': 'plain text', 'columns': (grids.isEmpty ? null : grids.last['columns'] as int?) ?? 40}, // the fit's width
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
  FakeSnapshot(this.cols, this.rows, this.altScreen);
  @override
  final int cols, rows;
  @override
  final bool altScreen;
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
  int cols, rows, resets = 0, snapshots = 0;
  final written = <int>[];
  bool disposed = false, failSnapshot = false;
  bool alt = true; // a full-screen program: Term, no scrollback

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

  final modes = <int>{};
  bool tracksMouse = false;
  @override
  bool mode(int mode) => modes.contains(mode);
  @override
  VtSnapshot snapshot() {
    snapshots++;
    if (failSnapshot) throw StateError('boom');
    return FakeSnapshot(cols, rows, alt);
  }
  @override
  void dispose() => disposed = true;

  // canned emulator replies, drained by takeReplies like the shim's buffer
  final replies = <int>[];
  @override
  Uint8List encodeKey(VtKey key, {int mods = 0, String text = ''}) =>
      Uint8List.fromList(utf8.encode(switch (key) {
        VtKey.arrowUp => '\x1b[A',
        VtKey.arrowDown => '\x1b[B',
        VtKey.enter => '\r',
        VtKey.c when mods == vtCtrl => '\x03',
        _ => text,
      }));
  @override
  Uint8List encodeText(String text) => Uint8List.fromList(utf8.encode(text));
  @override
  Uint8List encodePaste(String text) => Uint8List.fromList(utf8.encode(text));
  @override
  Uint8List encodeWheel({required bool up, required int col, required int row}) =>
      Uint8List.fromList(tracksMouse ? utf8.encode('wheel ${up ? 'up' : 'down'} $col,$row') : const []);
  @override
  Uint8List encodeFocus(bool gained) => Uint8List.fromList(modes.contains(1004) ? utf8.encode(gained ? '\x1b[I' : '\x1b[O') : const []);
  @override
  Uint8List takeReplies() {
    final r = Uint8List.fromList(replies);
    replies.clear();
    return r;
  }
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

const _claimCh = 3; // the watch channel is 2

/// Taps Take over; the relay opens the claim and makes the phone the leader.
Future<void> _lead(Harness h) async {
  await h.t.tap(find.byKey(const Key('takeOver')));
  await h.t.pump();
  await h.t.pump();
  expect(h.r.lastChannel, _claimCh);
  h.r.send([...json(LinkKind.opened, _claimCh, {'cols': 40, 'rows': 20}), ...json(LinkKind.lead, _claimCh, {'role': 'leader'})]);
  await h.t.pump();
  await h.t.pump();
}

String _typed(Harness h) => utf8.decode([for (final f in h.r.frames) if (f.channel == _claimCh && f.kind == LinkKind.data) ...f.payload]);
int _types(Harness h) => h.r.calls.where((c) => c == 'session.type').length;
String _label(WidgetTester t, String key) => t.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text))).data!;
double _zoom(WidgetTester t) =>
    t.widget<Transform>(find.descendant(of: find.byKey(const Key('term')), matching: find.byType(Transform)).first).transform.getMaxScaleOnAxis();

/// Two fingers 105 apart once past the recognizer's slop, spread to 210 near [c]: twice the size.
Future<void> _pinch(WidgetTester t, Offset c) async {
  final a = await t.startGesture(c - const Offset(40, 0), pointer: 7);
  final b = await t.startGesture(c + const Offset(40, 0), pointer: 8);
  await a.moveBy(const Offset(-25, 0));
  for (var i = 0; i < 4; i++) {
    await a.moveBy(const Offset(-13.125, 0));
    await b.moveBy(const Offset(13.125, 0));
    await t.pump();
  }
  await a.up();
  await b.up();
  await t.pump(const Duration(milliseconds: 400));
}
bool _enabled(WidgetTester t, String key) => t.widget<OutlinedButton>(find.byKey(Key(key))).onPressed != null;

Future<void> _loadFonts() async {
  for (final (family, file) in [('Inter', 'Inter'), ('JetBrainsMono', 'JetBrainsMono')]) {
    await (FontLoader(family)..addFont(rootBundle.load('assets/fonts/$file.ttf'))).load();
  }
}

void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
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
    expect(h.r.calls.where((c) => c == 'session.grid'), hasLength(1)); // fitted to the phone, as the text view is
    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.r.of(LinkKind.resize), isEmpty);
    expect([for (final f in h.r.frames) if (f.channel >= 2 && f.kind == LinkKind.data) f], isEmpty); // watch only
    await h.stop();
  });

  testWidgets('theScreenPicksScrollback', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('\$ ')));
    await t.pump();
    await t.pump();
    expect(find.byType(TerminalView), findsNothing); // the main screen: its history, scrollable
    expect(find.byKey(const Key('screen')), findsOneWidget);
    final texts = h.r.texts;
    await t.pump(const Duration(seconds: 2));
    expect(h.r.texts, greaterThan(texts));
    expect(h.r.closes, isEmpty); // the channel stays open to see the next switch

    h.vts.single.alt = true;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('top')));
    await t.pump();
    await t.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.r.closes, isEmpty);
    await h.stop();
  });

  testWidgets('aFitSizesTheEmulatorBeforeTheRelayReportsIt', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened(cols: 200, rows: 60);
    final fit = h.r.grids.single;
    expect((h.vts.single.cols, h.vts.single.rows), (fit['columns'], fit['rows']));
    h.r.send(frame(LinkKind.grid, 2, LinkFrame.resize(2, 200, 60).payload)); // the Mac took its grid back
    await t.pump();
    expect((h.vts.single.cols, h.vts.single.rows), (200, 60));
    await h.stop();
  });

  testWidgets('aFloodOfDataCostsOneSnapshotPerFrame', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.send(frame(LinkKind.data, 2, utf8.encode('a')));
    await t.pump(); // the text view is cleared by now
    final before = h.vts.single.snapshots;
    h.r.send([for (var i = 0; i < 20; i++) ...frame(LinkKind.data, 2, utf8.encode('x'))]);
    await t.pump();
    expect(h.vts.single.snapshots - before, lessThanOrEqualTo(1));
    await h.stop();
  });

  testWidgets('aFailingSnapshotFallsBackToText', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.failSnapshot = true;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('a')));
    await t.pump();
    await t.pump();
    expect(h.vts.single.disposed, isTrue);
    expect(h.r.closes, contains(2));
    expect(t.takeException(), isNull);
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
    expect(h.r.textArgs.last['lines'], 2000); // no screen to follow: the history
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
    h.r.send(frame(LinkKind.data, 2, utf8.encode('\x1b[?1049hhello\x1b[1;31m!'))); // a full-screen program
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

  testWidgets('termDragScrollsTheProgram', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.pump();
    final term = find.byKey(const Key('term'));
    final cols = h.m.fitted['s1/left']?.$1 ?? h.vts.single.cols;
    final row = CellMetrics.fit(t.getSize(term).width - 24, cols).h;
    final g = await t.startGesture(t.getCenter(term));
    await g.moveBy(Offset(0, 3 * row));
    await g.up();
    await t.pump();
    expect(h.r.scrolls, [
      {'pane': 'left', 'lines': -3},
    ]);
    await h.stop();
  });

  testWidgets('termDragErrorIsReportedOnce', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.pump();
    h.r.refused.add('session.scroll');
    final g = await t.startGesture(t.getCenter(find.byKey(const Key('term'))));
    await g.moveBy(const Offset(0, 200));
    await g.up();
    await t.pump();
    await t.pump();
    expect(find.text('refused session.scroll'), findsOneWidget);
    expect(h.r.scrolls, hasLength(1));
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
  testWidgets('takeOverButtonIsDisabledWithoutATerminal', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    expect(find.byKey(const Key('takeOver')), findsOneWidget);
    expect(_enabled(t, 'takeOver'), isFalse);
    expect(_label(t, 'takeOver'), 'Take over');
    final fg = t.widget<OutlinedButton>(find.byKey(const Key('takeOver'))).style!.foregroundColor!;
    expect(fg.resolve({WidgetState.disabled})!.a, lessThan(fg.resolve({})!.a)); // reads as disabled, not as off
    await h.stop();
  });

  testWidgets('takeOverResetsTheFitFirst', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    expect(h.m.fitted['s1/left'], isNotNull);
    final grids = h.r.grids.length;
    h.r.held['session.grid'] = [];
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    expect(h.r.grids.last, {'pane': 'left', 'reset': true});
    expect(h.r.lastChannel, 2); // no claim until the computer has its grid back
    h.r.held.remove('session.grid')!.forEach(h.r.send);
    await t.pump();
    await t.pump();
    expect(h.r.opens.last['claim'], isTrue);
    expect(h.m.fitted['s1/left'], isNull);
    await t.pump(const Duration(seconds: 1));
    expect(h.r.grids, hasLength(grids + 1)); // the reset, and no fit while leading
    await h.stop();
  });

  testWidgets('takeOverUsesThePhoneGrid', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.pump();
    final box = t.getSize(find.byKey(const Key('term')));
    final cols = h.r.grids.first['columns'] as int; // Fit to phone's columns for the same box
    final rows = ((box.height - 24) / CellMetrics.fit(box.width - 24, cols).h).floor();
    expect(h.r.opens.last, {'type': 'vt', 'target': 's1', 'pane': 'left', 'claim': true, 'cols': cols, 'rows': rows});
    await h.stop();
  });

  testWidgets('refusalStaysInWatch', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.pump();
    expect(_label(t, 'takeOver'), 'Give back'); // the relay can take up to 10 s
    h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
    await t.pump();
    await t.pump();
    expect(find.text('session not realized'), findsOneWidget);
    expect(_label(t, 'takeOver'), 'Take over');
    await t.tap(find.byKey(const Key('key-Up')));
    await t.pump();
    expect(_types(h), 1);
    await h.stop();
  });

  testWidgets('keyBarSendsEncodedKeysWhileLeading', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    expect(_label(t, 'takeOver'), 'Give back');
    await t.tap(find.byKey(const Key('key-Up')));
    await t.tap(find.byKey(const Key('key-Control C')));
    await t.pump();
    expect(_typed(h), '\x1b[A\x03');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('composerSendsTextThenEnter', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    await t.enterText(find.byKey(const Key('composer')), 'ls');
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(_typed(h), 'ls\r');
    expect(find.text('ls'), findsNothing);
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(_typed(h), 'ls\r\r');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('pasteKeyPastes', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (c) async => c.method == 'Clipboard.getData' ? {'text': 'echo hi'} : null);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.scrollUntilVisible(find.byKey(const Key('key-Paste')), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)));
    await t.tap(find.byKey(const Key('key-Paste')));
    await t.pump();
    await t.pump();
    expect(_types(h), 1);
    await _lead(h);
    await t.scrollUntilVisible(find.byKey(const Key('key-Paste')), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)));
    await t.tap(find.byKey(const Key('key-Paste')));
    await t.pump();
    await t.pump();
    expect(_typed(h), 'echo hi');
    expect(_types(h), 1);
    await h.stop();
  });

  testWidgets('dragSendsWheelWhileLeading', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    final term = find.byKey(const Key('term'));
    final row = CellMetrics.fit(t.getSize(term).width - 24, h.vts.single.cols).h;
    final g = await t.startGesture(t.getCenter(term));
    await g.moveBy(Offset(0, 3 * row));
    await g.up();
    await t.pump();
    expect(RegExp('wheel up').allMatches(_typed(h)), hasLength(3));
    expect(h.r.scrolls, isEmpty);
    await h.stop();
  });

  testWidgets('zoomedWheelHitsTheCellUnderTheFinger', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    final c = t.getCenter(find.byKey(const Key('term')));
    await _pinch(t, c);
    expect(_zoom(t), greaterThan(1.5));
    final start = c + const Offset(60, 0);
    final at = t.renderObject<RenderBox>(find.byType(TerminalView)).globalToLocal(start);
    final cell = CellMetrics.fit(t.getSize(find.byKey(const Key('term'))).width - 24, h.vts.single.cols);
    final g = await t.startGesture(start);
    for (var i = 0; i < 4; i++) {
      await g.moveBy(Offset(0, cell.h));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final hits = RegExp(r'wheel up (\d+),(\d+)').allMatches(_typed(h)).toList();
    expect(hits, isNotEmpty);
    final row = (at.dy / cell.h).floor();
    for (final m in hits) {
      expect(int.parse(m[1]!), (at.dx / cell.w).floor());
      expect(int.parse(m[2]!), inInclusiveRange(row, row + 3));
    }
    await h.stop();
  });

  testWidgets('paneSwitchResetsTheZoom', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await _pinch(t, t.getCenter(find.byKey(const Key('term'))));
    expect(_zoom(t), greaterThan(1.5));
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    await h.opened();
    expect(_zoom(t), 1);
    await h.stop();
  });

  testWidgets('giveBackResumesTheFit', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    expect(h.m.fitted['s1/left'], isNull);
    final grids = h.r.grids.length;
    await t.tap(find.byKey(const Key('takeOver'))); // Give back
    await t.pump();
    await t.pump();
    expect(h.r.closes, [_claimCh]);
    expect(h.r.grids, hasLength(grids + 1));
    expect(h.r.grids.last['columns'], isNotNull);
    expect(h.m.fitted['s1/left'], isNotNull);
    await h.stop();
  });

  testWidgets('leadLostReturnsToWatch', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final grids = h.r.grids.length;
    h.r.send([...json(LinkKind.lead, _claimCh, {'role': 'follower'}), ...json(LinkKind.close, _claimCh, {'reason': 'the computer took the lead back'})]);
    await t.pump();
    await t.pump();
    expect(find.text('The computer took the lead back.'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 500));
    expect(h.r.grids, hasLength(grids)); // not refitted under the Mac's user
    expect(_label(t, 'takeOver'), 'Take over');
    h.r.send(frame(LinkKind.data, 2, utf8.encode('x')));
    await t.pump();
    await t.pump();
    expect(find.text('The computer took the lead back.'), findsOneWidget); // said once
    await t.tap(find.byKey(const Key('key-Up')));
    await t.pump();
    expect(_types(h), 1);
    await h.stop();
  });

  testWidgets('pauseAndPaneSwitchRelease', (t) async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (_) async => null);
    Watch.permitted = true;
    addTearDown(() => Watch.permitted = false);
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await _lead(h);
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(h.r.closes, containsAll([2, _claimCh]));
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    final watch = h.r.lastChannel;
    await h.opened();
    expect(_label(t, 'takeOver'), 'Take over');
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.pump();
    final claim = h.r.lastChannel;
    h.r.send([...json(LinkKind.opened, claim, {'cols': 40, 'rows': 20}), ...json(LinkKind.lead, claim, {'role': 'leader'})]);
    await t.pump();
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    expect(h.r.closes, containsAll([watch, claim]));
    expect(_label(t, 'takeOver'), 'Take over');
    await h.stop();
  });

  testWidgets('keyboardInsetResizesTheLead', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(t.view.reset);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    t.view.viewInsets = const FakeViewPadding(bottom: 600);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(h.r.of(LinkKind.resize), isEmpty);
    await t.pump(const Duration(milliseconds: 150));
    expect([for (final f in h.r.of(LinkKind.resize)) f.channel], [_claimCh]);
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), hasLength(1));
    await h.stop();
  });

  testWidgets('paneSwitchDuringTheResetStaysQuiet', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    h.r.held['session.grid'] = [];
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    h.r.held.remove('session.grid')!.forEach(h.r.send);
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
    expect([for (final o in h.r.opens) if (o['claim'] == true) o], isEmpty);
    expect(find.text('closed'), findsNothing);
    expect(_label(t, 'takeOver'), 'Take over');
    await h.stop();
  });

  testWidgets('giveBackDuringTheResetCancelsTheClaim', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.held['session.grid'] = [];
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    expect(_enabled(t, 'takeOver'), isTrue);
    await t.tap(find.byKey(const Key('takeOver'))); // Give back
    await t.pump();
    h.r.held.remove('session.grid')!.forEach(h.r.send);
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
    expect([for (final o in h.r.opens) if (o['claim'] == true) o], isEmpty);
    expect(_label(t, 'takeOver'), 'Take over');
    await h.stop();
  });

  testWidgets('takeOverIsDisabledWhileAFitIsPending', (t) async {
    final h = Harness(t, treeOf());
    h.r.held['session.grid'] = [];
    await h.start();
    await h.opened();
    expect(h.r.grids, hasLength(1));
    expect(_enabled(t, 'takeOver'), isFalse);
    h.r.held.remove('session.grid')!.forEach(h.r.send);
    await t.pump();
    await t.pump();
    expect(_enabled(t, 'takeOver'), isTrue);
    await h.stop();
  });

  testWidgets('keyboardDuringThePendingClaimResizesTheLead', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.pump();
    final claimed = h.r.opens.last;
    t.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(t.view.reset);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(h.r.of(LinkKind.resize), isEmpty);
    h.r.send([...json(LinkKind.opened, _claimCh, {'cols': 40, 'rows': 20}), ...json(LinkKind.lead, _claimCh, {'role': 'leader'})]);
    await t.pump();
    await t.pump();
    final resize = h.r.of(LinkKind.resize).single;
    expect(resize.channel, _claimCh);
    expect(resize.size!.rows, lessThan(claimed['rows'] as int));
    await h.stop();
  });

  testWidgets('aRefusedResetKeepsTheFitToGiveBack', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.refused.add('session.grid');
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.pump();
    expect(find.text('refused session.grid'), findsOneWidget);
    expect(h.m.fitted['s1/left'], isNotNull);
    final resets = h.r.grids.where((g) => g['reset'] == true).length;
    h.nav.currentState!.pop();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(h.r.grids.where((g) => g['reset'] == true).length, resets + 1); // leaving gives it back
    await h.stop();
  });

  testWidgets('linkLossReturnsToWatch', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.relays.first.drop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 1100));
    await t.pump(const Duration(milliseconds: 10));
    expect(h.relays.length, 2);
    await h.opened();
    await t.pump(const Duration(milliseconds: 10));
    expect(_label(t, 'takeOver'), 'Take over');
    expect(find.text('Disconnected.'), findsNothing);
    expect([for (final o in h.r.opens) if (o['claim'] == true) o], isEmpty);
    expect(h.r.grids.last['columns'], isNotNull); // fitted again for Watch
    await h.stop();
  });

  testWidgets('pauseDuringThePendingClaim', (t) async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (_) async => null);
    Watch.permitted = true;
    addTearDown(() => Watch.permitted = false);
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('takeOver')));
    await t.pump();
    await t.pump();
    expect(h.r.lastChannel, _claimCh);
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    h.r.send(json(LinkKind.opened, _claimCh, {'cols': 40, 'rows': 20})); // too late: closed at once
    await t.pump();
    await t.pump();
    expect(h.r.closes, containsAll([2, _claimCh]));
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    await h.opened();
    expect(find.text('closed'), findsNothing);
    expect(_label(t, 'takeOver'), 'Take over');
    await h.stop();
  });

  // real fonts: the test font is wider than both
  testWidgets('toolbarFitsAPhoneWidthWithASplit', (t) async {
    await _loadFonts();
    _phone(t);
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    final bar = find.byKey(const Key('toolbar'));
    final segs = find.descendant(of: bar, matching: find.byType(OutlinedButton));
    void onScreen() {
      expect(segs, findsNWidgets(3));
      for (final e in segs.evaluate()) {
        final r = t.getRect(find.byWidget(e.widget));
        expect((r.left >= 0, r.right <= 360), (true, true));
      }
    }
    onScreen();
    await expectLater(bar, matchesGoldenFile('goldens/session_toolbar_watch.png'));
    await _lead(h);
    await t.pump(const Duration(milliseconds: 300)); // the segment's colour change animates
    onScreen();
    await expectLater(bar, matchesGoldenFile('goldens/session_toolbar_lead.png'));
    await h.stop();
  });

  testWidgets('takeOverReadsAsDisabledOnAPaneThatIsNotLive', (t) async {
    await _loadFonts();
    _phone(t);
    final h = Harness(t, treeOf(live: false, split: true));
    await h.start();
    await expectLater(find.byKey(const Key('toolbar')), matchesGoldenFile('goldens/session_toolbar_disabled.png'));
    await h.stop();
  });
}
