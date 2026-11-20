import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/decoder.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/link/messages.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/pages/page_sheet.dart';
import 'package:elis_mobile/screens/actions.dart';
import 'package:elis_mobile/screens/session.dart';
import 'package:elis_mobile/terminal/row_cache.dart';
import 'package:elis_mobile/terminal/term_keyboard.dart';
import 'package:elis_mobile/terminal/terminal_view.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:elis_mobile/theme.dart';
import 'package:elis_mobile/watch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show answer, frame, grid, json, pairing, upgradeAnswer;

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
  final typed = <String>[]; // session.type texts
  String text = 'plain text'; // what session.text answers
  final refused = <String>{}; // commands answered with an error
  int refusedFits = 0; // the next session.grid fits (not resets) answered with an error, as a covered pane does
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
      if (r['cmd'] == 'session.type') typed.add((r['args'] as Map)['text'] as String);
      final fit = r['cmd'] == 'session.grid' && (r['args'] as Map)['columns'] != null;
      final covered = fit && refusedFits > 0;
      if (covered) refusedFits--;
      final List<int>? reply =
          refused.contains(r['cmd']) || covered ? frame(LinkKind.data, 0, utf8.encode('${jsonEncode({'id': r['id'], 'ok': false, 'error': 'refused ${r['cmd']}'})}\n')) : null;
      if (held[r['cmd']] case final q?) {
        q.add(reply ?? frame(LinkKind.data, 0, answer(r['id'])));
        continue;
      }
      if (reply != null) {
        send(reply);
        continue;
      }
      final result = switch (r['cmd']) {
        'tree' => {'tree': tree},
        'events.read' => {
            'events': {'run': 'r', 'next': 0, 'items': <Object>[]},
          },
        'session.text' => {'text': text, 'columns': (grids.isEmpty ? null : grids.last['columns'] as int?) ?? 40}, // the fit's width
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
  int get lastWatch => [for (final f in of(LinkKind.open)) if ((jsonDecode(utf8.decode(f.payload)) as Map)['claim'] != true) f.channel].last;
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
  FakeSnapshot(this.cols, this.rows, this.altScreen, {this.cursorY = 0, this.cursorVisible = false});
  @override
  final int cols, rows;
  @override
  final bool altScreen;
  @override
  int get cursorX => 0;
  @override
  final int cursorY;
  @override
  final bool cursorVisible;
  @override
  List<VtRow> get lines => const [];
}

class FakeVt implements Vt {
  FakeVt(this.cols, this.rows);
  int cols, rows, resets = 0, snapshots = 0;
  final written = <int>[];
  bool disposed = false, failSnapshot = false;
  bool alt = true; // a full-screen program: Term, no scrollback
  int cursorY = 0;
  bool cursorVisible = false;

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
    alt = false; // a full reset leaves the alternate screen; the replay enters it again
  }

  final modes = <int>{};
  bool tracksMouse = false;
  @override
  bool mode(int mode) => modes.contains(mode);
  @override
  VtSnapshot snapshot() {
    snapshots++;
    if (failSnapshot) throw StateError('boom');
    return FakeSnapshot(cols, rows, alt, cursorY: cursorY, cursorVisible: cursorVisible);
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
        VtKey.tab => '\t',
        VtKey.escape => '\x1b',
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
  final clicks = <(int, int)>[];
  @override
  Uint8List encodeClick({required int col, required int row}) {
    clicks.add((col, row));
    return Uint8List.fromList(tracksMouse ? utf8.encode('click $col,$row') : const []);
  }

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
  var keyboards = 0; // the screen asked for the soft keyboard
  late final ElisModel m;
  Relay get r => relays.last;

  final webs = <FakeWeb>[]; // one per page sheet, with [start]'s pages

  Future<void> start({Vt Function(int, int)? vt, bool pages = false}) async {
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
        builder: (_) => screen(vt: vt, pages: pages))));
    await t.pumpAndSettle(const Duration(milliseconds: 10));
  }

  SessionScreen screen({Vt Function(int, int)? vt, bool pages = false}) => SessionScreen(
      model: m,
      sessionId: 's1',
      vt: vt ?? (c, r) => FakeVt(c, r)..also(vts.add),
      onKeyboard: () => keyboards++,
      pages: pages,
      pageWebView: (c) {
        final web = FakeWeb(c);
        webs.add(web);
        return Focus(focusNode: web.focus, child: const ColoredBox(color: C.bg, child: SizedBox.expand(key: Key('fakeWeb')))); // hit-testable, as a platform view is
      });

  /// The Mac's tree changes and the phone re-reads it.
  Future<void> retree(Map<String, Object> tree) async {
    for (final x in relays) {
      x.tree = tree;
    }
    await m.refresh();
    await t.pump();
  }

  Future<void> opened({int cols = 80, int rows = 24}) async {
    r.send(json(LinkKind.opened, r.lastWatch, {'cols': cols, 'rows': rows}));
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

/// With pages the present channel opens first: present 2, watch 3, claim 4.
const presentCh = 2;

/// A sheet's web view: it records what the sheet asks and lets a test report the page's side.
class FakeWeb implements PageWeb {
  FakeWeb(this.c) {
    c.web = this;
  }
  final PageSheetController c;
  final focus = FocusNode(); // the platform view's, which takes hardware keys
  final urls = <Uri>[], htmls = <String>[], scripts = <String>[];
  var reloads = 0, backs = 0, forwards = 0;
  bool back = false;

  @override
  Future<void> loadUrl(Uri url) async => urls.add(url);
  @override
  Future<void> loadHtml(String html) async => htmls.add(html);
  @override
  Future<void> run(String script) async => scripts.add(script);
  @override
  Future<void> reload() async => reloads++;
  @override
  Future<void> goBack() async => backs++;
  @override
  Future<void> goForward() async => forwards++;
  @override
  Future<bool> canGoBack() async => back;
  @override
  Future<String?> title() async => titleText;
  String? titleText = 'doc title';
  bool empty = false;
  var releases = 0;
  @override
  Future<void> release() async => releases++;
  @override
  Future<bool> isEmpty() async => empty;

  /// The nonce the sheet put in its prelude.
  String get nonce => RegExp(r"const n = '([0-9a-f]+)'").firstMatch(scripts.firstWhere((s) => s.contains('const n')))!.group(1)!;
}

Map<String, Object?> urlPage({String id = 'p1', bool hidden = false, int? sizePercent, bool javascript = false, bool chromeless = false}) => {
      't': 'page', 'id': id, 'kind': 'url', 'url': 'https://example.com/a', 'javascript': javascript, 'chromeless': chromeless,
      'browse': false, 'hidden': hidden, 'title': 'example.com', 'sizePercent': ?sizePercent,
    };

/// The relay accepts the present channel and sends [lines] on it.
Future<void> pageDown(Harness h, List<Map<String, Object?>> lines, {bool open = false}) async {
  if (open) h.r.send(json(LinkKind.opened, presentCh, {}));
  for (final l in lines) {
    h.r.send(frame(LinkKind.data, presentCh, utf8.encode('${jsonEncode(l)}\n')));
  }
  await h.t.pump();
  await h.t.pump();
}

/// The lines the phone sent on the present channel.
List<Map> pageUp(Harness h) => [
      for (final l in const LineSplitter().convert(_typed(h, presentCh))) jsonDecode(l) as Map,
    ];

const _busy = 'The computer has not taken the earlier input yet.';

/// The relay opens the claim on [ch] and makes the phone the leader.
Future<void> _leader(Harness h, [int ch = _claimCh]) async {
  h.r.send([...json(LinkKind.opened, ch, {'cols': 40, 'rows': 20}), ...json(LinkKind.lead, ch, {'role': 'leader'})]);
  await h.t.pump();
  await h.t.pump();
}

/// The claim made on open leads.
Future<void> _lead(Harness h) async {
  expect(h.r.lastChannel, _claimCh);
  await _leader(h);
}

Future<void> _key(WidgetTester t, String name) async {
  final bar = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));
  t.state<ScrollableState>(bar).position.jumpTo(0);
  await t.pump();
  await t.scrollUntilVisible(find.byKey(Key('key-$name')), 100, scrollable: bar);
  await t.ensureVisible(find.byKey(Key('key-$name'))); // whole, not just its edge
  await t.pump();
  await t.tap(find.byKey(Key('key-$name')));
  await t.pump();
}

List<Map> _watches(Harness h) => [for (final o in h.r.opens) if (o['claim'] != true) o];
List<Map> _claims(Harness h) => [for (final o in h.r.opens) if (o['claim'] == true) o];
String _typed(Harness h, [int ch = _claimCh]) =>
    utf8.decode([for (final f in h.r.frames) if (f.channel == ch && f.kind == LinkKind.data) ...f.payload]);
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

/// The app goes to the background and back; the screen's channels close and reopen.
Future<void> _pauseResume(Harness h, {Future<void> Function()? paused}) async {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  h.t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (_) async => null);
  Watch.permitted = true;
  addTearDown(() => Watch.permitted = false);
  for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    h.t.binding.handleAppLifecycleStateChanged(s);
  }
  await h.t.pump();
  await paused?.call();
  for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    h.t.binding.handleAppLifecycleStateChanged(s);
  }
  await h.t.pump();
}

/// The open claim leads, then the Mac takes the lead back: the next input claims again.
Future<void> _takeBack(Harness h) async {
  await _lead(h);
  h.r.send([...json(LinkKind.lead, _claimCh, {'role': 'follower'}), ...json(LinkKind.close, _claimCh, {'reason': 'the computer took the lead back'})]);
  await h.t.pump();
  await h.t.pump();
}

/// The relay refuses the claim made on open: the pane is indirect for the visit.
Future<void> _refuse(Harness h) async {
  h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
  for (var i = 0; i < 10; i++) {
    await h.t.pump(const Duration(milliseconds: 10));
  }
  expect(find.text('session not realized'), findsNothing); // said at the first input
}

/// A single tap, acted on once the double-tap timeout passes.
Future<void> _tap(WidgetTester t, Offset at) async {
  await t.tapAt(at);
  await t.pump(const Duration(milliseconds: 400));
  await t.pump();
}

/// The centre of a cell of the Term view, as laid out now (zoom and pan included).
Offset _cell(Harness h, int col, int row) {
  final cell = CellMetrics.fit(h.t.getSize(find.byKey(const Key('term'))).width, h.vts.single.cols);
  return h.t.renderObject<RenderBox>(find.byType(TerminalView)).localToGlobal(Offset((col + 0.5) * cell.w, (row + 0.5) * cell.h));
}

Future<void> _drag(WidgetTester t, Offset from, double dy, {int steps = 4}) async {
  final g = await t.startGesture(from);
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(0, dy / steps));
    await t.pump();
  }
  await g.up();
  await t.pump(const Duration(milliseconds: 400));
}

/// The watch channel shows [n] rows: an empty strip above the grid.
Future<void> _shortGrid(Harness h, int ch, [int n = 3]) async {
  h.r.send(frame(LinkKind.grid, ch, LinkFrame.resize(ch, 40, n).payload));
  await h.t.pump();
  await h.t.pump();
}

Future<void> _dirty(Harness h) async {
  h.r.send(frame(LinkKind.data, 2, utf8.encode('x')));
  await h.t.pump();
  await h.t.pump();
}

List<Map> _fits(Harness h) => [for (final g in h.r.grids) if (g['columns'] != null) g];
int _resets(Harness h) => h.r.grids.where((g) => g['reset'] == true).length;

void main() {
  setUp(() => ComposerPref.shown = true);
  tearDown(() => ComposerPref.shown = false);

  testWidgets('livePaneShowsTheTerminal', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    expect(_watches(h), [
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
    h.vts.single.alt = true;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('new')));
    await t.pump();
    expect([for (final f in h.r.of(LinkKind.credit)) f.creditBytes], [5, 3]);

    final texts = h.r.texts;
    await t.pump(const Duration(seconds: 3));
    expect(h.r.texts, texts); // the text poll stops while Term is shown
    expect(h.r.calls.where((c) => c == 'session.grid'), isEmpty); // the claim sizes it to the phone, not a fit
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
    await _refuse(h); // a pane the phone does not lead is fitted
    final fit = _fits(h).single;
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
    expect(_watches(h).length, 1); // not retried, so not said again
    h.m.notifyListeners(); // a tree refresh
    await t.pump(const Duration(seconds: 6));
    expect(_watches(h).length, 1);
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
    expect(_watches(h), [
      {'type': 'vt', 'target': 's1', 'pane': 'left'},
    ]);
    expect(h.r.lastWatch, 2); // a new link starts its ids again
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
    expect(h.r.closes, [2, 3]);
    expect(h.vts.single.disposed, isTrue);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(h.r.lastWatch, 4); // a fresh channel id
    await h.opened();

    h.nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(h.r.closes, [2, 3, 4, 5]);

    // left before OPENED: the channel that opens late is closed
    unawaited(h.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => SessionScreen(model: h.m, sessionId: 's1', vt: FakeVt.new, pages: false))));
    await t.pumpAndSettle();
    expect(h.r.lastWatch, 6);
    h.nav.currentState!.pop();
    await t.pumpAndSettle();
    await h.opened();
    expect(h.r.closes, [2, 3, 4, 5, 6]); // no OPENED, so no claim
    await h.stop();
  });

  testWidgets('backgrounding keeps the present channel', (t) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    expect(h.r.opens.first, {'type': 'present', 'target': 's1'});
    await h.opened();
    await _leader(h, 4);
    await pageDown(h, [urlPage()], open: true);
    expect(find.byKey(const Key('pageSheet')), findsOneWidget);
    await _pauseResume(h, paused: () async {
      expect(h.r.closes, containsAll([3, 4])); // the watch and the claim
      expect(h.r.closes, isNot(contains(presentCh)));
      await pageDown(h, [
        {'t': 'command', 'id': 'p1', 'seq': 1, 'action': 'close'},
      ]); // the origin moves the page to the Mac
    });
    // a paused app draws no frame, so the sheet is seen gone at resume
    expect(find.byKey(const Key('pageSheet'), skipOffstage: false), findsNothing);
    expect(find.byKey(const Key('pageChip')), findsNothing);
    await h.opened();
    await pageDown(h, [urlPage()]);
    expect(find.byKey(const Key('pageSheet')), findsOneWidget);
    expect(h.r.closes, isNot(contains(presentCh)));
    await h.stop();
  });

  testWidgets('the present channel opens once more after the relay ends it, and not for an older relay', (t) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    await h.opened();
    await pageDown(h, [urlPage()], open: true);
    List<int> presents() => [
      for (final f in h.r.frames)
        if (f.kind == LinkKind.open && (jsonDecode(utf8.decode(f.payload)) as Map)['type'] == 'present') f.channel,
    ];
    h.r.send(json(LinkKind.close, presentCh, {'reason': 'presentation ended'}));
    await t.pump();
    await t.pump();
    expect(presents(), hasLength(2));
    h.r.send(json(LinkKind.opened, presents().last, {'error': 'unsupported channel type'}));
    await t.pump();
    await t.pump();
    expect(presents(), hasLength(2)); // the budget is spent until the next terminal OPENED, and an older relay never retries
    await h.stop();
  });

  testWidgets('leaving the session closes the present channel', (t) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    await h.opened();
    await pageDown(h, [urlPage()], open: true);
    h.nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(h.r.closes, contains(presentCh));
    await h.stop();
  });

  testWidgets('a new screen for the session closes the old present channel before it opens its own', (t) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    await h.opened();
    await pageDown(h, [urlPage()], open: true);
    h.nav.currentState!.pop(); // the old screen disposes only after its exit transition
    unawaited(h.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => h.screen(pages: true))));
    await t.pump();
    final close = h.r.frames.indexWhere((f) => f.kind == LinkKind.close && f.channel == presentCh);
    final reopen = h.r.frames.lastIndexWhere((f) => f.kind == LinkKind.open && (jsonDecode(utf8.decode(f.payload)) as Map)['type'] == 'present');
    expect(close, isNonNegative);
    expect(close, lessThan(reopen));
    await t.pumpAndSettle();
    await h.stop();
  });

  testWidgets('statusShowsOnlyItsShape', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    expect(find.byKey(const Key('status')), findsOneWidget);
    expect(find.text('Idle'), findsNothing);
    expect(find.bySemanticsLabel('Idle'), findsOneWidget);
    await h.stop();
  });

  testWidgets('sessionActionsHaveNoSplit', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('sessionMenu')));
    await t.pumpAndSettle();
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Split side by side'), findsNothing);
    expect(find.text('Hide split pane'), findsNothing);
    await h.stop();
  });

  testWidgets('splitToggleReopensTheOtherPane', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    expect(h.r.closes, [2, 3]);
    expect(_watches(h).last, {'type': 'vt', 'target': 's1', 'pane': 'right'});
    expect(h.r.lastWatch, 4);
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
    expect(h.r.lastWatch, 4); // reopened, quietly
    expect(find.textContaining('stalled'), findsNothing);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(_claims(h), hasLength(2)); // the reopened pane claims again
    h.r.send(json(LinkKind.close, 4, {'reason': 'stalled'}));
    await t.pump();
    await t.pump();
    expect(h.r.lastWatch, 4); // a second close soon: text view, said readably
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
    expect(h.r.lastChannel, 3); // a refused watch was never claimed
    await h.stop();
  });

  testWidgets('paneThatBecomesOrStopsBeingLive', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    expect(h.r.opens, isEmpty);
    await h.retree(treeOf());
    expect(h.r.lastWatch, 2);
    await h.opened();
    expect(find.byType(TerminalView), findsOneWidget);
    await h.retree(treeOf(live: false));
    expect(h.r.closes, [2, 3]);
    expect(find.byType(TerminalView), findsNothing);
    await h.stop();
  });

  testWidgets('scrollOnARefusedPaneUsesSessionScroll', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _refuse(h);
    final term = find.byKey(const Key('term'));
    final row = CellMetrics.fit(t.getSize(term).width, h.vts.single.cols).h;
    final g = await t.startGesture(t.getCenter(term));
    await g.moveBy(Offset(0, 3 * row));
    await g.up();
    await t.pump();
    expect(h.r.scrolls, [
      {'pane': 'left', 'lines': -3},
    ]);
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('termDragErrorIsReportedOnce', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _refuse(h);
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

  testWidgets('openClaimsWithThePhoneGrid', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    final claim = _claims(h).single;
    final cols = claim['cols'] as int;
    final box = t.getSize(find.byKey(const Key('term')));
    expect(claim, {'type': 'vt', 'target': 's1', 'pane': 'left', 'claim': true, 'cols': cols, 'rows': (box.height / CellMetrics.fit(box.width, cols).h).floor()});
    expect(_label(t, 'lead'), 'Leading…');
    await _leader(h);
    expect(_label(t, 'lead'), 'Leading');
    expect((h.vts.single.cols, h.vts.single.rows), (cols, claim['rows']));
    await h.stop();
  });

  testWidgets('theClaimWaitsForTheWatchOpened', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await t.pump(const Duration(seconds: 1));
    expect(_claims(h), isEmpty);
    expect(h.r.grids, isEmpty); // about to be claimed: not fitted meanwhile
    await h.opened();
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('lookingDoesNotClaimTwice', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _takeBack(h);
    await t.pump(const Duration(seconds: 5));
    await _pinch(t, t.getCenter(find.byKey(const Key('term'))));
    await t.pump();
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('pauseReleasesAndResumeClaimsAgain', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _leader(h);
    await _pauseResume(h, paused: () async => expect(h.r.closes, containsAll([2, _claimCh])));
    await h.opened();
    expect(_claims(h), hasLength(2));
    expect(h.r.grids, isEmpty); // the claim brings the grid: no fit to reset first
    expect(h.r.lastChannel, greaterThan(_claimCh + 1));
    expect(_label(t, 'lead'), 'Leading…');
    await h.stop();
  });

  testWidgets('paneSwitchClaimsTheNewPane', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await _leader(h);
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    await t.pump();
    expect(h.r.closes, containsAll([2, _claimCh]));
    await h.opened();
    expect([for (final c in _claims(h)) c['pane']], ['left', 'right']);
    expect(h.r.grids, isEmpty);
    await h.stop();
  });

  testWidgets('macTakeBackIsNotReclaimedOnResume', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _leader(h);
    h.r.send([...json(LinkKind.lead, _claimCh, {'role': 'follower'}), ...json(LinkKind.close, _claimCh, {'reason': 'the computer took the lead back'})]);
    await t.pump();
    await t.pump();
    await _pauseResume(h);
    await h.opened();
    await t.pump(const Duration(seconds: 1));
    expect(_claims(h), hasLength(1));
    expect(find.byKey(const Key('lead')), findsNothing);
    await _key(t, 'Up');
    await t.pump();
    expect(_claims(h), hasLength(2));
    await h.stop();
  });

  testWidgets('refusedPaneDoesNotClaimOnReopen', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    await _pauseResume(h);
    await h.opened();
    await t.pump(const Duration(seconds: 1));
    expect(_claims(h), hasLength(1));
    expect(find.byKey(const Key('lead')), findsNothing);
    await h.stop();
  });

  testWidgets('notLivePaneDoesNotClaim', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await t.pump(const Duration(seconds: 1));
    expect(_claims(h), isEmpty);
    expect(find.byKey(const Key('lead')), findsNothing);
    await h.stop();
  });

  testWidgets('keyBarKeyBeforeTheLeadArrivesOnce', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    expect(_claims(h), hasLength(1));
    expect(_typed(h), '');
    await _leader(h);
    expect(_typed(h), '\x1b[A');
    await t.pump(const Duration(seconds: 1));
    expect(_typed(h), '\x1b[A');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('keyBarSendsEncodedKeysWhileLeading', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    await _key(t, 'Up');
    await _key(t, 'Control C');
    expect(_typed(h), '\x1b[A\x03');
    expect(_types(h), 0);
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('composerSendSendsALineOnTheClaim', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.enterText(find.byKey(const Key('composer')), 'ls');
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    await t.pump();
    expect(_claims(h), hasLength(1));
    expect(find.text('ls'), findsNothing);
    await _leader(h);
    expect(_typed(h), 'ls');
    await t.pump(const Duration(milliseconds: 20));
    expect(_typed(h), 'ls\r');
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(_typed(h), 'ls\r\r');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('pasteArrivesOnTheClaim', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (c) async => c.method == 'Clipboard.getData' ? {'text': 'echo hi'} : null);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _key(t, 'Paste');
    await t.pump();
    await t.pump();
    expect(_claims(h), hasLength(1));
    await _leader(h);
    expect(_typed(h), 'echo hi');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('answerButtonArrivesOnTheClaim', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = 'Proceed?\n❯ 1. Yes\n  2. No';
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('\$ ')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    await t.tap(find.byKey(const Key('answer-1')));
    await t.pump();
    await t.pump();
    expect(_claims(h), hasLength(1));
    await _leader(h);
    expect(_typed(h), '1');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('aPaneBecomingLiveDuringAFitClaimsAfterTheReset', (t) async {
    final h = Harness(t, treeOf(live: false));
    h.r.held['session.grid'] = [];
    await h.start();
    expect(h.r.grids, hasLength(1));
    await h.retree(treeOf());
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    expect(_claims(h), isEmpty);
    final fit = h.r.held.remove('session.grid')!;
    h.r.held['session.grid'] = [];
    fit.forEach(h.r.send);
    await t.pump();
    await t.pump();
    await t.pump();
    expect(h.r.grids.last, {'pane': 'left', 'reset': true});
    expect(_claims(h), isEmpty);
    h.r.held.remove('session.grid')!.forEach(h.r.send);
    await t.pump();
    await t.pump();
    expect(_claims(h), hasLength(1));
    await _leader(h);
    await t.pump(const Duration(seconds: 1));
    expect(_typed(h), '\x1b[A');
    await h.stop();
  });

  testWidgets('refusedClaimReplaysTheQueueIndirectly', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _key(t, 'Up');
    await _key(t, 'Control C');
    await t.enterText(find.byKey(const Key('composer')), 'ls');
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(h.r.lastChannel, _claimCh);
    expect(find.byKey(const Key('lead')), findsOneWidget);
    expect(_types(h), 0);
    h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('session not realized'), findsOneWidget);
    expect(find.byKey(const Key('lead')), findsNothing);
    expect(h.r.typed, ['\x1b[A', '\x03', 'ls', '\r']);
    await _key(t, 'Down');
    await t.pump();
    expect(h.r.typed.last, '\x1b[B');
    expect(_claims(h), hasLength(1));
    expect(find.text('session not realized'), findsOneWidget);
    await h.stop();
  });

  testWidgets('refusedInputKeepsTheComposerText', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.held['session.grid'] = []; // the claim stays pending
    for (var i = 0; i < 256; i++) {
      await t.tap(find.byKey(const Key('key-Up')));
    }
    await t.pump();
    expect(find.text(_busy), findsNothing);
    await t.enterText(find.byKey(const Key('composer')), 'ls');
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(find.text(_busy), findsOneWidget);
    expect(find.text('ls'), findsOneWidget);
    await h.stop();
  });

  testWidgets('paneSwitchDropsThePendingQueue', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    expect(h.r.lastChannel, _claimCh);
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    await _leader(h); // too late: closed at once
    await h.opened();
    await t.pump(const Duration(seconds: 1));
    expect(h.r.closes, containsAll([2, _claimCh]));
    expect([for (final f in h.r.frames) if (f.channel >= 2 && f.kind == LinkKind.data) f], isEmpty);
    expect(_types(h), 0);
    expect([for (final c in _claims(h)) c['pane']], ['left', 'right']);
    await h.stop();
  });

  testWidgets('inputAfterAResumeGoesToTheNewClaim', (t) async {
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
    final watch = h.r.lastWatch;
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    final claim = h.r.lastChannel;
    expect((claim, _claims(h).length), (watch + 1, 2));
    await _leader(h, claim);
    expect(_typed(h, claim), '\x1b[A');
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    expect(h.r.closes, containsAll([watch, claim]));
    await h.stop();
  });

  testWidgets('macTakeBackThenAKeyClaimsAgain', (t) async {
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
    h.r.send(frame(LinkKind.data, 2, utf8.encode('x')));
    await t.pump();
    await t.pump();
    expect(find.text('The computer took the lead back.'), findsOneWidget); // said once
    await _key(t, 'Up');
    await t.pump();
    expect(_claims(h), hasLength(2));
    expect(h.r.lastChannel, _claimCh + 1);
    expect(find.text('The computer took the lead back.'), findsOneWidget);
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('aKeyBeforeARefusedWatchArrivesIndirectly', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await _key(t, 'Up');
    await t.pump();
    h.r.send(json(LinkKind.opened, 2, {'error': _refusal}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.typed, ['\x1b[A']);
    await t.pump(const Duration(seconds: 1));
    expect(h.r.typed, ['\x1b[A']);
    await h.stop();
  });

  testWidgets('aKeyBeforeAMidStreamCloseArrivesIndirectly', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _key(t, 'Up');
    await _key(t, 'Down');
    await t.pump();
    expect(h.r.lastChannel, _claimCh);
    h.r.send(json(LinkKind.close, 2, {'reason': 'stalled'}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.typed, ['\x1b[A', '\x1b[B']);
    expect(_typed(h), '');
    await h.stop();
  });

  testWidgets('lostInputIsSaidOnce', (t) async {
    var clip = 'x' * (1 << 20);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (c) async => c.method == 'Clipboard.getData' ? {'text': clip} : null);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    await _key(t, 'Paste');
    await t.pump();
    await t.enterText(find.byKey(const Key('composer')), 'a');
    await t.tap(find.byKey(const Key('send')));
    clip = 'y' * 20000;
    await t.tap(find.byKey(const Key('key-Paste'))); // still in view; queued behind the line's Enter, inside its gap
    await t.pump();
    expect(find.text(_busy), findsNothing);
    await t.pump(const Duration(milliseconds: 20));
    await t.pump();
    expect(find.text(_busy), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(find.text(_busy), findsOneWidget);
    await h.stop();
  });

  testWidgets('notLivePaneTypesIndirectly', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await _key(t, 'Up');
    await t.pump();
    expect(h.r.typed, ['\x1b[A']);
    expect(h.r.opens, isEmpty);
    expect(find.byKey(const Key('lead')), findsNothing);
    await h.stop();
  });

  testWidgets('chipShowsPendingThenLeadsThenClears', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    expect(_label(t, 'lead'), 'Leading…');
    await _leader(h);
    expect(_label(t, 'lead'), 'Leading');
    h.r.send([...json(LinkKind.lead, _claimCh, {'role': 'follower'}), ...json(LinkKind.close, _claimCh, {'reason': 'the computer took the lead back'})]);
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('lead')), findsNothing);
    await h.stop();
  });

  testWidgets('historyKeepsUpdatingWhileLeading', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('\$ ')));
    await t.pump();
    await t.pump();
    await _lead(h);
    expect(find.byKey(const Key('screen')), findsOneWidget);
    h.r.text = 'later';
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.text('later'), findsOneWidget);
    expect(find.byKey(const Key('term')), findsNothing);
    await h.stop();
  });

  testWidgets('historyScrollDoesNotClaim', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = List.generate(200, (i) => 'line $i').join('\n');
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('\$ ')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await _takeBack(h);
    final history = t.state<ScrollableState>(find.ancestor(of: find.byKey(const Key('screen')), matching: find.byType(Scrollable)).first).position;
    final at = history.pixels;
    await t.dragFrom(_historyBox(t).center, const Offset(0, 200));
    await t.pump(const Duration(seconds: 1));
    expect(history.pixels, isNot(at)); // the drag reached the history
    expect(_claims(h), hasLength(1));
    expect(h.r.scrolls, isEmpty);
    expect(_typed(h), '');
    await h.stop();
  });

  testWidgets('toolbarIsEmptyWithoutASplit', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    expect(find.byKey(const Key('toolbar')), findsNothing);
    expect(find.text('Take over'), findsNothing);
    await h.stop();
  });

  testWidgets('terminalRunsEdgeToEdge', (t) async {
    _phone(t);
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    final box = t.getRect(find.byKey(const Key('term')));
    expect((box.left, box.width), (0, 360));
    expect(t.getRect(find.byType(TerminalView)).left, 0);
    final advance = (TextPainter(
            text: TextSpan(text: 'M' * 100, style: const TextStyle(fontFamily: mono, fontSize: 12)),
            textDirection: TextDirection.ltr)
          ..layout())
        .width /
        100;
    final cols = _claims(h).single['cols'] as int;
    expect(cols, (360 / advance).floor());
    expect(cols, greaterThan((336 / advance).floor())); // the old 12 px each side
    h.vts.single.alt = false;
    h.r.send(frame(LinkKind.data, 2, utf8.encode('\$ ')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final text = t.getRect(find.byKey(const Key('screen')));
    expect((text.left, text.width), (0, 360));
    await h.stop();
  });

  testWidgets('wheelMapsTheCellFromTheBoxEdge', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    final box = t.getRect(find.byKey(const Key('term')));
    final grid = t.getRect(find.byType(TerminalView));
    final cell = CellMetrics.fit(box.width, h.vts.single.cols);
    final g = await t.startGesture(Offset(box.left + cell.w * 1.5, grid.top + cell.h * 0.5));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(Offset(0, cell.h));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final hits = RegExp(r'wheel up (\d+),(\d+)').allMatches(_typed(h)).toList();
    expect(hits, isNotEmpty);
    for (final m in hits) {
      expect(m[1], '1'); // the second column: no margin before the first
      expect(int.parse(m[2]!), inInclusiveRange(0, 4));
    }
    await h.stop();
  });

  testWidgets('dragSendsWheelWhileLeading', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    final term = find.byKey(const Key('term'));
    final row = CellMetrics.fit(t.getSize(term).width, h.vts.single.cols).h;
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
    final cell = CellMetrics.fit(t.getSize(find.byKey(const Key('term'))).width, h.vts.single.cols);
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

  testWidgets('wheelAboveAShortGridHitsItsTopRows', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.r.send(frame(LinkKind.grid, _claimCh, LinkFrame.resize(_claimCh, 40, 3).payload));
    await t.pump();
    await t.pump();
    h.vts.single.tracksMouse = true;
    final box = t.getRect(find.byKey(const Key('term')));
    final cell = CellMetrics.fit(box.width, h.vts.single.cols);
    Future<List<String>> drag(Offset from) async {
      final before = RegExp(r'wheel up \d+,(\d+)').allMatches(_typed(h)).length;
      final g = await t.startGesture(from);
      for (var i = 0; i < 4; i++) {
        await g.moveBy(Offset(0, cell.h));
        await t.pump();
      }
      await g.up();
      await t.pump(const Duration(milliseconds: 400));
      return [for (final m in RegExp(r'wheel up \d+,(\d+)').allMatches(_typed(h)).skip(before)) m[1]!];
    }

    expect(await drag(box.bottomCenter - Offset(0, cell.h * 0.5 + 4 * cell.h)), isNotEmpty); // a lower row first
    expect(t.getRect(find.byType(TerminalView)).top, greaterThan(box.top)); // an empty strip above the grid
    expect((await drag(box.topCenter + const Offset(0, 4))).map(int.parse), everyElement(lessThan(4))); // the finger's rows, not the earlier one
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

  testWidgets('paneSwitchDuringTheResetStaysQuiet', (t) async {
    final h = Harness(t, treeOf(split: true, live: false));
    await h.start();
    h.r.held['session.grid'] = [];
    await h.retree(treeOf(split: true)); // the fitted pane becomes Live: its fit is reset before the claim
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    h.r.held.remove('session.grid')!.forEach(h.r.send);
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
    await h.opened();
    expect([for (final c in _claims(h)) c['pane']], ['right']);
    expect(find.text('closed'), findsNothing);
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('aRefusedResetKeepsTheFitAndTypesIndirectly', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    h.r.refused.add('session.grid');
    await h.retree(treeOf());
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
    expect(find.text('refused session.grid'), findsOneWidget);
    expect(h.m.fitted['s1/left'], isNotNull);
    expect(_claims(h), isEmpty);
    expect(h.r.typed, ['\x1b[A']);
    await t.pump(const Duration(seconds: 4)); // past its retries
    final resets = _resets(h);
    h.nav.currentState!.pop();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(_resets(h), resets + 1); // leaving gives it back
    await h.stop();
  });

  testWidgets('linkLossClaimsAgainOnTheNewLink', (t) async {
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
    expect(_label(t, 'lead'), 'Leading…');
    expect(find.text('Disconnected.'), findsNothing);
    expect(_claims(h), hasLength(1));
    expect(h.r.grids, isEmpty);
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
    expect(_claims(h), hasLength(2));
    expect(_types(h), 0);
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
    expect(segs, findsNWidgets(2));
    for (final e in segs.evaluate()) {
      final r = t.getRect(find.byWidget(e.widget));
      expect((r.left >= 0, r.right <= 360), (true, true));
    }
    await expectLater(bar, matchesGoldenFile('goldens/session_toolbar_split.png'));
    await h.stop();
  });

  testWidgets('appBarShowsTheLead', (t) async {
    await _loadFonts();
    _phone(t);
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/session_screen.png'));
    await expectLater(find.byType(AppBar), matchesGoldenFile('goldens/session_appbar_pending.png'));
    expect(t.renderObject<RenderParagraph>(find.text('shell')).didExceedMaxLines, isFalse); // the name is not cut
    await _leader(h);
    await t.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(AppBar), matchesGoldenFile('goldens/session_appbar_lead.png'));
    expect(t.renderObject<RenderParagraph>(find.text('shell')).didExceedMaxLines, isFalse); // the name is not cut
    await h.stop();
  });
  testWidgets('coveredFitAfterOwnReleaseRetries', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final fits = _fits(h).length;
    h.r.refusedFits = 1;
    await h.retree(treeOf(live: false)); // restarted on the Mac: the text view is fitted
    await t.pump(const Duration(milliseconds: 10));
    expect(_fits(h).length, fits + 1);
    expect(h.m.fitted['s1/left'], isNull);
    await h.m.refresh();
    await t.pump(const Duration(milliseconds: 500));
    expect(_fits(h).length, fits + 1); // the retry waits its second
    await t.pump(const Duration(milliseconds: 600));
    await t.pump();
    expect(_fits(h).length, fits + 2);
    expect(h.m.fitted['s1/left'], isNotNull);
    expect(find.text('refused session.grid'), findsNothing);
    await h.stop();
  });

  testWidgets('fourthCoveredRefusalIsReported', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final fits = _fits(h).length;
    h.r.refusedFits = 4;
    await h.retree(treeOf(live: false));
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text('refused session.grid'), findsNothing);
      await t.pump(const Duration(seconds: 1));
    }
    await t.pump();
    expect(_fits(h).length, fits + 4);
    expect(find.text('refused session.grid'), findsOneWidget);
    await h.m.refresh();
    await t.pump(const Duration(seconds: 3));
    expect(_fits(h).length, fits + 4);
    expect(h.m.fitted['s1/left'], isNull);
    await h.stop();
  });

  testWidgets('macTakeBackKeepsTheFitOff', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final fits = _fits(h).length;
    h.r.send([...json(LinkKind.lead, _claimCh, {'role': 'follower'}), ...json(LinkKind.close, _claimCh, {'reason': 'the computer took the lead back'})]);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await _key(t, 'Left');
    await t.pump();
    await _leader(h, h.r.lastChannel);
    await _pauseResume(h);
    await h.opened();
    await t.pump(const Duration(seconds: 2));
    expect(_fits(h), hasLength(fits));
    await h.stop();
  });

  testWidgets('aRefusedClaimOnACoveredPaneSaysOneMessage', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.r.refusedFits = 1;
    h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.refusedFits, 0);
    await _key(t, 'Up');
    expect(find.text('session not realized'), findsOneWidget);
    expect(find.text('refused session.grid'), findsNothing);
    await t.pump(const Duration(seconds: 5));
    expect(find.text('refused session.grid'), findsNothing);
    expect(_fits(h), hasLength(1), reason: 'not retried');
    await h.stop();
  });

  testWidgets('refusedClaimResumesTheFit', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    expect(h.m.fitted['s1/left'], isNull);
    final fits = _fits(h).length;
    h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(_fits(h), hasLength(fits + 1));
    expect(h.m.fitted['s1/left'], isNotNull);
    await h.stop();
  });

  testWidgets('keyboardDoesNotResizeTheLead', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final grids = h.r.grids.length;
    addTearDown(t.view.reset);
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final keyboardTop = t.view.physicalSize.height / t.view.devicePixelRatio - 300;
    expect(t.getRect(find.byType(TerminalView)).bottom, lessThanOrEqualTo(keyboardTop));
    t.view.resetViewInsets();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), isEmpty);
    expect(h.r.grids, hasLength(grids));
    await h.stop();
  });

  testWidgets('keyboardOverASafeAreaDoesNotResizeTheLead', (t) async {
    final h = Harness(t, treeOf());
    addTearDown(t.view.reset);
    t.view.padding = t.view.viewPadding = const FakeViewPadding(bottom: 144); // a gesture bar
    await h.start();
    await h.opened();
    await _lead(h);
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    t.view.padding = FakeViewPadding.zero; // the keyboard covers the bar
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    t.view.resetViewInsets();
    t.view.padding = const FakeViewPadding(bottom: 144);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), isEmpty);
    await h.stop();
  });

  testWidgets('keyboardDuringThePendingClaimChangesNothing', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    final box = t.getSize(find.byKey(const Key('term')));
    addTearDown(t.view.reset);
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final claim = _claims(h).single;
    expect(claim['rows'], (box.height / CellMetrics.fit(box.width, claim['cols'] as int).h).floor());
    t.view.resetViewInsets();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _leader(h);
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), isEmpty);
    await h.stop();
  });

  testWidgets('rotationResizesTheLeadOnce', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final vt = h.vts.single;
    final before = (vt.cols, vt.rows);
    addTearDown(t.view.reset);
    final s = t.view.physicalSize;
    t.view.physicalSize = Size(s.height, s.width);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(h.r.of(LinkKind.resize), isEmpty);
    await t.pump(const Duration(milliseconds: 150));
    final resize = h.r.of(LinkKind.resize).single;
    expect(resize.channel, _claimCh);
    expect((vt.cols, vt.rows), before);
    h.r.send([...frame(LinkKind.resync, 2), ...grid(2, resize.size!.cols, resize.size!.rows)]);
    await t.pump();
    expect((vt.cols, vt.rows), (resize.size!.cols, resize.size!.rows));
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), hasLength(1));
    await h.stop();
  });

  testWidgets('aResyncKeepsTheViewUntilTheReplay', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    final texts = h.r.texts;
    h.r.send([...frame(LinkKind.resync, 2), ...grid(2, 40, 20)]);
    await t.pump();
    await t.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    h.vts.single.alt = true;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.r.texts, texts, reason: 'no history read for a reset');

    h.r.send([...frame(LinkKind.resync, 2), ...grid(2, 40, 20)]);
    await t.pump();
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('screen')), findsOneWidget, reason: 'the replay drew the main screen');
    await h.stop();
  });

  testWidgets('aPaneSwitchClosesAPendingClaimBeforeTheNextOne', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    final pending = h.r.lastChannel;
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    expect(h.r.closes, contains(pending), reason: 'closed before its OPENED, so the relay never attaches it');
    await t.tap(find.text('Left pane'));
    await t.pump();
    await h.opened();
    expect([for (final c in _claims(h)) c['pane']], ['left', 'left']); // the right pane never opened
    await h.stop();
  });

  testWidgets('answerRowDoesNotResizeTheLead', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    await _lead(h);
    h.r.text = 'Proceed?\n❯ 1. Yes\n  2. No';
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.byKey(const Key('answer-1')), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), isEmpty);
    expect(t.getRect(find.byKey(const Key('screen'))).bottom, lessThanOrEqualTo(t.getRect(find.byKey(const Key('answer-1'))).top));
    h.r.text = 'plain text';
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('answer-1')), findsNothing);
    expect(h.r.of(LinkKind.resize), isEmpty);
    await h.stop();
  });

  testWidgets('aClaimByAnAnswerButtonTakesTheRowsWithoutIt', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = 'Proceed?\n❯ 1. Yes\n  2. No';
    await h.start();
    await h.opened();
    await _takeBack(h);
    h.vts.single.alt = false;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    await t.tap(find.byKey(const Key('answer-1')));
    await t.pump();
    await t.pump();
    expect(_claims(h), hasLength(2));
    await _leader(h, h.r.lastChannel);
    h.r.text = 'plain text';
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('answer-1')), findsNothing);
    expect(h.r.of(LinkKind.resize), isEmpty);
    await h.stop();
  });

  testWidgets('aGrowingComposerDoesNotResizeTheLead', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final composer = t.getRect(find.byKey(const Key('composer')));
    await t.enterText(find.byKey(const Key('composer')), 'a\nb\nc\nd');
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(t.getRect(find.byKey(const Key('composer'))).top, lessThan(composer.top));
    expect(h.r.of(LinkKind.resize), isEmpty);
    expect(t.getRect(find.byType(TerminalView)).bottom, lessThanOrEqualTo(t.getRect(find.byKey(const Key('composer'))).top));
    await h.stop();
  });

  testWidgets('directTypingOnTheHistoryReadsItBackSoon', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    await _lead(h);
    await t.pump(const Duration(seconds: 1));
    final texts = h.r.texts;
    while (h.r.texts == texts) {
      await t.pump(const Duration(milliseconds: 10)); // a poll tick: the next is 700 ms away
    }
    for (final send in [() => _key(t, 'Up'), () => t.enterText(find.byKey(const Key('composer')), 'ls').then((_) => t.tap(find.byKey(const Key('send'))))]) {
      final before = h.r.texts;
      await send();
      await t.pump(const Duration(milliseconds: 200));
      expect(h.r.texts, before + 1);
      await t.pump(const Duration(milliseconds: 500));
      while (h.r.texts == before + 1) {
        await t.pump(const Duration(milliseconds: 10));
      }
    }
    await h.stop();
  });

  testWidgets('aRefusedResetIsSaidOnceAndRetriedBoundedly', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    h.r.refused.add('session.grid');
    await h.retree(treeOf());
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
    expect(find.text('refused session.grid'), findsOneWidget);
    expect(_resets(h), 1);
    for (var i = 0; i < 10; i++) {
      await _key(t, 'Down'); // each session.type refreshes the model
      await t.pump(const Duration(milliseconds: 600));
    }
    expect(_resets(h), 4);
    expect(find.text('refused session.grid'), findsNothing);
    expect(h.m.fitted['s1/left'], isNotNull);
    await h.stop();
  });

  testWidgets('aReplayedKeyArrivesBeforeANewClaim', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _key(t, 'Up');
    await t.pump();
    expect(h.r.lastChannel, _claimCh);
    h.r.held['session.type'] = [];
    h.r.send(json(LinkKind.close, 2, {'reason': 'stalled'}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.typed, ['\x1b[A']);
    await h.opened();
    await _key(t, 'Down');
    await t.pump(const Duration(milliseconds: 100));
    expect(_claims(h), hasLength(1));
    h.r.held.remove('session.type')!.forEach(h.r.send);
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(_claims(h), hasLength(2));
    await _leader(h, h.r.lastChannel);
    expect(_typed(h, h.r.lastChannel), '\x1b[B');
    expect(h.r.typed, ['\x1b[A']);
    await h.stop();
  });

  testWidgets('tapClicksTheCellUnderTheFinger', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    await _tap(t, _cell(h, 3, 2));
    expect(h.vts.single.clicks, [(3, 2)]);
    expect(_typed(h), contains('click 3,2'));
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('zoomedTapHitsTheCellUnderTheFinger', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    final c = t.getCenter(find.byKey(const Key('term')));
    await _pinch(t, c);
    expect(_zoom(t), greaterThan(1.5));
    final at = t.renderObject<RenderBox>(find.byType(TerminalView)).globalToLocal(c + const Offset(60, 0));
    final cell = CellMetrics.fit(t.getSize(find.byKey(const Key('term'))).width, h.vts.single.cols);
    await _tap(t, c + const Offset(60, 0));
    expect(h.vts.single.clicks, [((at.dx / cell.w).floor(), (at.dy / cell.h).floor())]);
    await h.stop();
  });

  testWidgets('tapOutsideTheGridSendsNoClick', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _shortGrid(h, 2);
    final box = t.getRect(find.byKey(const Key('term')));
    expect(t.getRect(find.byType(TerminalView)).top, greaterThan(box.top + 10));
    await _tap(t, box.topCenter + const Offset(0, 4));
    expect(_claims(h), hasLength(1));
    await _leader(h);
    await _shortGrid(h, _claimCh);
    h.vts.single.tracksMouse = true;
    await _tap(t, box.topCenter + const Offset(0, 4));
    expect(h.vts.single.clicks, isEmpty);
    expect(_typed(h), isNot(contains('click')));
    await h.stop();
  });

  testWidgets('tapOnTheHistoryViewSendsNoClick', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    await _tap(t, t.getCenter(find.byKey(const Key('screen'))));
    expect(_claims(h), hasLength(1));
    await _leader(h);
    h.vts.single.tracksMouse = true;
    await _tap(t, t.getCenter(find.byKey(const Key('screen'))));
    expect(h.vts.single.clicks, isEmpty);
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('tapWithMouseOffSendsNothing', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _tap(t, _cell(h, 3, 2));
    expect(_claims(h), hasLength(1));
    await _leader(h);
    await _tap(t, _cell(h, 3, 2));
    expect(h.vts.single.clicks, [(3, 2), (3, 2)]);
    expect(_typed(h), '');
    await h.stop();
  });

  testWidgets('tapOnAnIndirectPaneSendsNothing', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await t.pump(const Duration(seconds: 1));
    await _tap(t, t.getCenter(find.byKey(const Key('screen'))));
    expect(_types(h), 0);
    expect(h.r.opens, isEmpty);
    expect(h.keyboards, 0); // no live terminal, no cursor
    await h.stop();
  });

  testWidgets('scrollBeforeTheLeadIsDroppedThenSendsWheel', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.tracksMouse = true;
    final term = find.byKey(const Key('term'));
    final row = CellMetrics.fit(t.getSize(term).width, h.vts.single.cols).h;
    await _drag(t, t.getCenter(term), 3 * row);
    expect(_claims(h), hasLength(1));
    expect(h.r.scrolls, isEmpty);
    await _leader(h);
    expect(_typed(h), ''); // the notches before the lead are dropped
    await _drag(t, t.getCenter(term), 3 * CellMetrics.fit(t.getSize(term).width, h.vts.single.cols).h + 1);
    expect(RegExp('wheel up').allMatches(_typed(h)), hasLength(3));
    expect(h.r.scrolls, isEmpty);
    await h.stop();
  });

  testWidgets('dragInFlightAtTakeBackDoesNotReclaim', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single.tracksMouse = true;
    final term = find.byKey(const Key('term'));
    final row = CellMetrics.fit(t.getSize(term).width, h.vts.single.cols).h;
    final g = await t.startGesture(t.getCenter(term));
    await g.moveBy(Offset(0, 2 * row));
    await t.pump();
    h.r.send([...json(LinkKind.lead, _claimCh, {'role': 'follower'}), ...json(LinkKind.close, _claimCh, {'reason': 'the computer took the lead back'})]);
    await t.pump();
    await t.pump();
    for (var i = 0; i < 4; i++) {
      await g.moveBy(Offset(0, row));
      await t.pump();
    }
    await g.up();
    await t.pump(const Duration(milliseconds: 400));
    expect(_claims(h), hasLength(1));
    expect(h.r.scrolls, isEmpty);
    await _drag(t, t.getCenter(term), 3 * row);
    expect(_claims(h), hasLength(2));
    await h.stop();
  });

  testWidgets('zoomAndDoubleTapDoNotClaim', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _takeBack(h);
    final c = t.getCenter(find.byKey(const Key('term')));
    await _pinch(t, c);
    expect(_zoom(t), greaterThan(1.5));
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 400));
    expect(_zoom(t), 1);
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await h.stop();
  });

  testWidgets('onlyATapOnTheVisibleCursorRowAsksForTheKeyboard', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    h.vts.single
      ..cursorY = 5
      ..cursorVisible = true;
    await _dirty(h);
    await _tap(t, _cell(h, 2, 3));
    expect(h.keyboards, 0);
    await _tap(t, _cell(h, 30, 5)); // any column of the caret's row
    expect(h.keyboards, 1);
    await t.tapAt(_cell(h, 30, 5));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(_cell(h, 30, 5));
    await t.pump(const Duration(milliseconds: 400));
    expect(h.keyboards, 1); // a double tap is looking
    h.vts.single.cursorVisible = false;
    await _dirty(h);
    await _tap(t, _cell(h, 30, 5));
    expect(h.keyboards, 1);
    await h.stop();
  });

  testWidgets('historyCursorRowIsItsLastLineAtTheBottom', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = List.generate(200, (i) => 'line $i').join('\n');
    await h.start();
    await h.opened();
    h.vts.single
      ..alt = false
      ..cursorVisible = true;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    final screen = t.getRect(find.byKey(const Key('screen')));
    await _tap(t, screen.bottomCenter - const Offset(0, 3)); // the last line
    expect(h.keyboards, 1);
    await _tap(t, screen.bottomCenter - const Offset(0, 80));
    expect(h.keyboards, 1);
    await t.dragFrom(screen.bottomCenter - const Offset(0, 150), const Offset(0, 200));
    await t.pump(const Duration(seconds: 1));
    expect(t.getRect(find.byKey(const Key('screen'))).bottom, greaterThan(screen.bottom));
    await _tap(t, screen.bottomCenter - const Offset(0, 3)); // scrolled up: the caret is not on screen
    expect(h.keyboards, 1);
    await h.stop();
  });

  testWidgets('historyWithAHiddenCursorNeverAsksForTheKeyboard', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.alt = false;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    await _tap(t, t.getRect(find.byKey(const Key('screen'))).bottomCenter - const Offset(0, 3));
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await h.stop();
  });

  testWidgets('cursorRowTapOnARefusedPaneAsksForTheKeyboardAndSendsNothing', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _refuse(h);
    final typed = h.r.typed.length;
    h.vts.single
      ..cursorY = 5
      ..cursorVisible = true
      ..tracksMouse = true;
    await _dirty(h);
    await _tap(t, _cell(h, 3, 5));
    expect(h.keyboards, 1);
    expect(h.vts.single.clicks, isEmpty);
    expect(h.r.typed, hasLength(typed));
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('tapOnTheHistoryEmptyAreaClaims', (t) async {
    final h = await _shortHistory(t);
    await _takeBack(h);
    final view = _historyBox(t);
    expect(t.getRect(find.byKey(const Key('screen'))).top, greaterThan(view.top + 20)); // the text sits at the bottom
    await _tap(t, view.topCenter + const Offset(0, 4));
    expect(_claims(h), hasLength(2));
    expect(h.keyboards, 0);
    await h.stop();
  });

  testWidgets('doubleTapOnTheHistoryDoesNotClaim', (t) async {
    final h = await _shortHistory(t);
    await _takeBack(h);
    final at = t.getRect(find.byKey(const Key('screen'))).bottomCenter - const Offset(0, 3);
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 400));
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await h.stop();
  });

  testWidgets('historyEmptyAreaBelowTextIsTheCursorRow', (t) async {
    final h = await _shortHistory(t);
    final view = _historyBox(t);
    await _tap(t, view.bottomCenter - const Offset(0, 1)); // the box's last pixel row
    expect(h.keyboards, 1);
    await _tap(t, view.topCenter + const Offset(0, 4)); // the empty area above the text is not
    expect(h.keyboards, 1);
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('tapOnTheCursorRowOpensTheKeyboard', (t) async {
    final h = await _cursorAt5(t);
    await t.tapAt(_cell(h, 30, 5));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(_cell(h, 30, 5));
    await t.pump(const Duration(milliseconds: 400));
    expect(t.testTextInput.isVisible, isFalse);
    await _tap(t, _cell(h, 30, 5));
    expect(t.testTextInput.isVisible, isTrue);
    await h.stop();
  });

  testWidgets('tapOffTheCursorRowOnlyClicks', (t) async {
    final h = await _cursorAt5(t);
    await _lead(h);
    h.vts.single.tracksMouse = true;
    await _tap(t, _cell(h, 3, 2));
    expect(h.vts.single.clicks, [(3, 2)]);
    expect(t.testTextInput.isVisible, isFalse);
    await h.stop();
  });

  testWidgets('hiddenCursorNeverOpensTheKeyboard', (t) async {
    final h = await _cursorAt5(t);
    await _lead(h);
    h.vts.single
      ..cursorVisible = false
      ..tracksMouse = true;
    await _dirty(h);
    await _tap(t, _cell(h, 3, 5));
    expect(h.vts.single.clicks, [(3, 5)]);
    expect(t.testTextInput.isVisible, isFalse);
    await h.stop();
  });

  testWidgets('historyViewUsesTheLiveCursorRow', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = List.generate(200, (i) => 'line $i').join('\n');
    await h.start();
    await h.opened();
    h.vts.single
      ..alt = false
      ..cursorVisible = true;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    final screen = t.getRect(find.byKey(const Key('screen')));
    await _tap(t, screen.bottomCenter - const Offset(0, 80)); // an earlier line
    expect(t.testTextInput.isVisible, isFalse);
    await _tap(t, screen.bottomCenter - const Offset(0, 3)); // the last line
    expect(t.testTextInput.isVisible, isTrue);
    await _hide(t);
    h.vts.single.cursorVisible = false;
    await _dirty(h);
    await _tap(t, screen.bottomCenter - const Offset(0, 3));
    expect(t.testTextInput.isVisible, isFalse);
    h.vts.single.cursorVisible = true;
    await _dirty(h);
    await t.dragFrom(screen.bottomCenter - const Offset(0, 150), const Offset(0, 200));
    await t.pump(const Duration(seconds: 1));
    await _tap(t, screen.bottomCenter - const Offset(0, 3)); // scrolled up
    expect(t.testTextInput.isVisible, isFalse);
    await h.stop();
  });

  testWidgets('historyEmptyAreaBelowTheTextOpensTheKeyboard', (t) async {
    final h = await _shortHistory(t);
    await _tap(t, _historyBox(t).bottomCenter - const Offset(0, 1));
    expect(t.testTextInput.isVisible, isTrue);
    await h.stop();
  });

  testWidgets('keyBarAndComposerWorkWithAHiddenCursor', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _key(t, 'Up');
    await _leader(h);
    await t.enterText(find.byKey(const Key('composer')), 'ls');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 30));
    expect(_typed(h), '\x1b[Als\r');
    await h.stop();
  });

  testWidgets('typedKeysGoToTheClaim', (t) async {
    final h = await _cursorAt5(t);
    await _tap(t, _cell(h, 30, 5));
    expect(_claims(h), hasLength(1));
    await _leader(h);
    await _soft(t, 'l');
    await _soft(t, 's');
    await t.testTextInput.receiveAction(TextInputAction.none);
    await t.pump();
    expect(_typed(h), 'ls\r');
    expect(_types(h), 0);
    await h.stop();
  });

  testWidgets('typedKeysOnANonLivePaneUseSessionType', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await _focusField(t);
    h.r.held['session.type'] = [];
    await _soft(t, 'l');
    await _soft(t, 's');
    await t.testTextInput.receiveAction(TextInputAction.none);
    await t.pump();
    final held = h.r.held['session.type']!;
    for (final want in [['l'], ['l', 's'], ['l', 's', '\r']]) {
      expect(h.r.typed, want); // one at a time
      h.r.send(held.removeAt(0));
      await t.pump();
      await t.pump();
    }
    expect(h.r.opens, isEmpty);
    await h.stop();
  });

  testWidgets('aSoftBackspaceOnANonLivePaneIsDel', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await _focusField(t);
    await _soft(t, ''); // a Backspace
    expect(h.r.typed, ['\x7f']);
    await h.stop();
  });

  testWidgets('cursorRowTapAfterHidingShowsTheKeyboardAgain', (t) async {
    final h = await _cursorAt5(t);
    await _tap(t, _cell(h, 30, 5));
    expect(t.testTextInput.isVisible, isTrue);
    await _hide(t);
    expect(t.testTextInput.isVisible, isFalse);
    await _tap(t, _cell(h, 3, 2));
    expect(t.testTextInput.isVisible, isFalse);
    await _tap(t, _cell(h, 30, 5));
    expect(t.testTextInput.isVisible, isTrue);
    await h.stop();
  });

  testWidgets('tappingTheProgramKeepsTyping', (t) async {
    final h = await _cursorAt5(t);
    await _lead(h);
    h.vts.single.tracksMouse = true;
    await _tap(t, _cell(h, 30, 5));
    await _tap(t, _cell(h, 3, 2));
    expect(h.vts.single.clicks, [(30, 5), (3, 2)]);
    expect(t.testTextInput.isVisible, isTrue);
    await _soft(t, 'x');
    expect(_typed(h), endsWith('x'));
    await h.stop();
  });

  testWidgets('tappingTheHistoryKeepsTyping', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = List.generate(200, (i) => 'line $i').join('\n');
    await h.start();
    await h.opened();
    h.vts.single
      ..alt = false
      ..cursorVisible = true;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    final screen = t.getRect(find.byKey(const Key('screen')));
    await _tap(t, screen.bottomCenter - const Offset(0, 3));
    await _leader(h);
    await _tap(t, screen.bottomCenter - const Offset(0, 80));
    expect(t.testTextInput.isVisible, isTrue);
    await _soft(t, 'x');
    expect(_typed(h), 'x');
    await h.stop();
  });

  testWidgets('historyTextSelectsWithTheKeyboardUp', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = List.generate(200, (i) => 'line $i').join('\n');
    await h.start();
    await h.opened();
    h.vts.single
      ..alt = false
      ..cursorVisible = true;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    final screen = t.getRect(find.byKey(const Key('screen')));
    await _tap(t, screen.bottomCenter - const Offset(0, 3));
    await t.longPressAt(screen.bottomLeft + const Offset(10, -80));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Copy'), findsOneWidget);
    await h.stop();
  });

  testWidgets('keyboardShownByATapDoesNotResize', (t) async {
    final h = await _cursorAt5(t);
    await _lead(h);
    final grids = h.r.grids.length;
    await _tap(t, _cell(h, 30, 5));
    expect(t.testTextInput.isVisible, isTrue);
    addTearDown(t.view.reset);
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(h.r.of(LinkKind.resize), isEmpty);
    expect(h.r.grids, hasLength(grids));
    await h.stop();
  });

  testWidgets('composerFocusTakesTypingUntilTheNextTap', (t) async {
    final h = await _cursorAt5(t);
    await _lead(h);
    await _tap(t, _cell(h, 30, 5));
    await t.tap(find.byKey(const Key('composer')));
    await t.pump();
    t.testTextInput.enterText('hi');
    await t.pump();
    expect(find.text('hi'), findsOneWidget);
    expect(_typed(h), '');
    await _tap(t, _cell(h, 30, 5));
    await _soft(t, 'x');
    expect(_typed(h), 'x');
    expect(find.text('hi'), findsOneWidget);
    await h.stop();
  });

  testWidgets('aTapOffTheCursorRowTakesTypingBackFromTheComposer', (t) async {
    final h = await _cursorAt5(t);
    await _lead(h);
    await _tap(t, _cell(h, 30, 5));
    await t.tap(find.byKey(const Key('composer')));
    await t.pump();
    addTearDown(t.view.reset);
    t.view.viewInsets = const FakeViewPadding(bottom: 900); // the keyboard is up
    await t.pump();
    await _tap(t, t.getCenter(find.byKey(const Key('term')))); // a row the keyboard leaves in view, not the cursor's
    expect(h.keyboards, 1);
    expect(t.testTextInput.isVisible, isTrue);
    await _soft(t, 'x');
    expect(_typed(h), 'x');
    expect(find.text('x'), findsNothing);
    await h.stop();
  });

  testWidgets('aTapOffTheCursorRowNeverOpensAHiddenKeyboard', (t) async {
    final h = await _cursorAt5(t);
    await t.tap(find.byKey(const Key('composer')));
    await t.pump();
    await _hide(t);
    await _tap(t, _cell(h, 3, 2));
    expect(t.testTextInput.isVisible, isFalse);
    await h.stop();
  });

  testWidgets('aTripleTapOnTheTermViewIsLooking', (t) async {
    final h = await _cursorAt5(t);
    await _takeBack(h);
    for (var i = 0; i < 3; i++) {
      await t.tapAt(_cell(h, 30, 5));
      await t.pump(const Duration(milliseconds: 50));
    }
    await t.pump(const Duration(milliseconds: 400));
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await _tap(t, _cell(h, 30, 5)); // the next tap acts again
    expect(_claims(h), hasLength(2));
    await h.stop();
  });

  testWidgets('modifiedKeysOnANonLivePaneSendXtermSequences', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await _focusField(t);
    Future<void> chord(LogicalKeyboardKey mod, LogicalKeyboardKey key) async {
      await t.sendKeyDownEvent(mod);
      await t.sendKeyEvent(key);
      await t.sendKeyUpEvent(mod);
      await t.pump();
      await t.pump();
    }

    await chord(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.backspace);
    await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowUp);
    await chord(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.end);
    await chord(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.pageUp);
    await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyA);
    await chord(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.keyX);
    expect(h.r.typed, ['\x1b\x7f', '\x1b[1;5A', '\x1b[1;2F', '\x1b[5;3~', '\x01', '\x1bx']);
    await h.stop();
  });

  testWidgets('anIndirectSoftKeyRefreshesTheText', (t) async {
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await _focusField(t);
    final polled = h.r.texts;
    while (h.r.texts == polled) {
      await t.pump(const Duration(milliseconds: 10));
    }
    final n = h.r.texts;
    await _soft(t, 'l');
    await t.pump(const Duration(milliseconds: 160));
    expect(h.r.texts, n + 1); // the 700 ms poll is far off
    await h.stop();
  });

  testWidgets('aLongPressIsLookingOnTheTermView', (t) async {
    final h = await _cursorAt5(t);
    await _takeBack(h);
    await t.longPressAt(_cell(h, 30, 5));
    await t.pump(const Duration(milliseconds: 400));
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await h.stop();
  });

  testWidgets('aLongPressIsLookingOnTheHistoryView', (t) async {
    final h = await _shortHistory(t);
    await _takeBack(h);
    await t.longPressAt(_historyBox(t).bottomCenter - const Offset(0, 1));
    await t.pump(const Duration(milliseconds: 400));
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await h.stop();
  });

  testWidgets('aTripleTapOnTheHistoryIsLooking', (t) async {
    final h = await _shortHistory(t);
    await _takeBack(h);
    final at = t.getRect(find.byKey(const Key('screen'))).bottomCenter - const Offset(0, 3);
    for (var i = 0; i < 3; i++) {
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 50));
    }
    await t.pump(const Duration(milliseconds: 400));
    expect(_claims(h), hasLength(1));
    expect(h.keyboards, 0);
    await _tap(t, at); // the next tap acts again
    expect(_claims(h), hasLength(2));
    await h.stop();
  });

  testWidgets('rotationRefitsAndTheKeyboardDoesNot', (t) async {
    _phone(t);
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _refuse(h); // a pane the phone does not lead is fitted
    final portrait = _fits(h).single;
    addTearDown(t.view.reset);
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(_fits(h), hasLength(1));
    t.view.resetViewInsets();
    final s = t.view.physicalSize;
    t.view.physicalSize = Size(s.height, s.width);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final landscape = _fits(h).last;
    expect(_fits(h), hasLength(2));
    expect(landscape['columns'], greaterThan(portrait['columns'] as int));
    expect(landscape['rows'], lessThan(portrait['rows'] as int));
    expect((h.vts.single.cols, h.vts.single.rows), (landscape['columns'], landscape['rows']));
    await h.stop();
  });

  testWidgets('rotationResizesTheLeadOnTheHistory', (t) async {
    _phone(t);
    final h = await _shortHistory(t);
    await _lead(h);
    final claim = _claims(h).single;
    addTearDown(t.view.reset);
    final s = t.view.physicalSize;
    t.view.physicalSize = Size(s.height, s.width);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final resize = h.r.of(LinkKind.resize).single;
    expect(resize.size!.cols, greaterThan(claim['cols'] as int));
    expect(resize.size!.rows, lessThan(claim['rows'] as int));
    await h.stop();
  });

  testWidgets('theFitAndTheLeadHaveTheSameGrid', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    final claim = _claims(h).single;
    await _refuse(h);
    final fit = _fits(h).single;
    expect((claim['cols'], claim['rows']), (fit['columns'], fit['rows']));
    await h.stop();
  });

  testWidgets('aTapBeforeTheLeadClicksAfterIt', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.tracksMouse = true;
    await _tap(t, _cell(h, 3, 2));
    expect(_claims(h), hasLength(1));
    expect(h.vts.single.clicks, isEmpty);
    await _leader(h);
    expect(h.vts.single.clicks, [(3, 2)]);
    expect(_typed(h), 'click 3,2');
    await h.stop();
  });

  testWidgets('aRefusedClaimTypesNoClick', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    h.vts.single.tracksMouse = true;
    await _tap(t, _cell(h, 3, 2));
    h.r.send(json(LinkKind.opened, _claimCh, {'error': 'session not realized'}));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(h.r.typed, isEmpty);
    await h.stop();
  });

  testWidgets('aTapOnTheHistoryDrawsNoCaretHandle', (t) async {
    final h = Harness(t, treeOf());
    h.r.text = List.generate(200, (i) => 'line $i').join('\n');
    await h.start();
    await h.opened();
    h.vts.single
      ..alt = false
      ..cursorVisible = true;
    await _dirty(h);
    await t.pump(const Duration(seconds: 1));
    await _tap(t, t.getRect(find.byKey(const Key('screen'))).bottomCenter - const Offset(0, 3));
    await t.pump(const Duration(seconds: 1));
    expect(find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_TextSelectionHandlePainter'), findsNothing);
    await h.stop();
  });

  testWidgets('composerIsHiddenByDefault', (t) async {
    ComposerPref.shown = false;
    final h = Harness(t, treeOf());
    await h.start();
    expect(find.text('Type, then send with Enter'), findsNothing);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(find.byKey(const Key('key-Up')), findsOneWidget);
    await h.stop();
  });

  testWidgets('menuShowsTheComposerAndRemembers', (t) async {
    ComposerPref.shown = false;
    final h = Harness(t, treeOf());
    await h.start();
    await _toggleComposer(t, 'Show composer');
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(ComposerPref.shown, isTrue);
    await t.tap(find.byKey(const Key('sessionMenu')));
    await t.pumpAndSettle();
    expect(_label(t, 'composerToggle'), 'Hide composer');
    await h.stop();
  });

  testWidgets('listSheetHasNoComposerToggle', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    unawaited(showSessionActions(h.nav.currentContext!, h.m, h.m.session('s1')!));
    await t.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.byKey(const Key('composerToggle')), findsNothing);
    await h.stop();
  });

  testWidgets('composerToggleWhileLeadingResizesOnce', (t) async {
    ComposerPref.shown = false;
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final claim = _claims(h).single;
    await _toggleComposer(t, 'Show composer');
    await t.pump(const Duration(seconds: 1));
    final resize = h.r.of(LinkKind.resize).single;
    expect(resize.channel, _claimCh);
    expect(resize.size!.cols, claim['cols']);
    expect(resize.size!.rows, lessThan(claim['rows'] as int));
    await h.stop();
  });

  testWidgets('hidingTheComposerWhileLeadingResizesOnce', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _lead(h);
    final claim = _claims(h).single;
    await _toggleComposer(t, 'Hide composer');
    await t.pump(const Duration(seconds: 1));
    final resize = h.r.of(LinkKind.resize).single;
    expect(resize.size!.rows, greaterThan(claim['rows'] as int));
    await h.stop();
  });

  testWidgets('hiddenComposerStillTypesIndirectly', (t) async {
    ComposerPref.shown = false;
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await _key(t, 'Up');
    await t.pump();
    expect(h.r.typed, ['\x1b[A']);
    expect(find.byKey(const Key('composer')), findsNothing);
    await h.stop();
  });

  testWidgets('keyboardKeyOpensTheKeyboardOnANonLivePane', (t) async {
    ComposerPref.shown = false;
    final h = Harness(t, treeOf(live: false));
    await h.start();
    await t.tap(find.byKey(const Key('softKeyboard')));
    await t.pump();
    expect(t.testTextInput.isVisible, isTrue);
    await _soft(t, 'l');
    expect(h.r.typed, ['l']);
    await h.stop();
  });

  testWidgets('keyboardKeyTogglesTheKeyboardAndNeverClaims', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _takeBack(h);
    await t.tap(find.byKey(const Key('softKeyboard')));
    await t.pump();
    expect(t.testTextInput.isVisible, isTrue);
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(t.view.reset);
    await t.pump();
    await t.tap(find.byKey(const Key('softKeyboard')));
    await t.pump();
    expect(t.testTextInput.isVisible, isFalse);
    expect(_claims(h), hasLength(1));
    await h.stop();
  });

  testWidgets('keyboardKeyHidesTheKeyboardOverTheComposer', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await t.tap(find.byKey(const Key('composer')));
    await t.pump();
    t.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(t.view.reset);
    await t.pump();
    await t.tap(find.byKey(const Key('softKeyboard')));
    await t.pump();
    expect(t.testTextInput.isVisible, isFalse);
    await h.stop();
  });

  testWidgets('aRefusedOpenClaimIsSaidAtTheFirstInput', (t) async {
    final h = Harness(t, treeOf());
    await h.start();
    await h.opened();
    await _refuse(h);
    await _key(t, 'Up');
    expect(find.text('session not realized'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await _key(t, 'Down');
    expect(find.text('session not realized'), findsNothing);
    await h.stop();
  });

  testWidgets('aPaneSwitchAfterATakeBackClaims', (t) async {
    final h = Harness(t, treeOf(split: true));
    await h.start();
    await h.opened();
    await _takeBack(h);
    await t.tap(find.byKey(const Key('rightPane')));
    await t.pump();
    await t.pump();
    await h.opened();
    expect([for (final c in _claims(h)) c['pane']], ['left', 'right']);
    await h.stop();
  });
}

/// Taps the session menu's composer item, which reads [label], and lets the sheet close.
Future<void> _toggleComposer(WidgetTester t, String label) async {
  await t.tap(find.byKey(const Key('sessionMenu')));
  await t.pumpAndSettle();
  expect(_label(t, 'composerToggle'), label);
  await t.tap(find.byKey(const Key('composerToggle')));
  await t.pumpAndSettle();
}

/// The Term view with a visible cursor on row 5.
Future<Harness> _cursorAt5(WidgetTester t) async {
  final h = Harness(t, treeOf());
  await h.start();
  await h.opened();
  h.vts.single
    ..cursorY = 5
    ..cursorVisible = true;
  await _dirty(h);
  return h;
}

/// A letter typed on the soft keyboard, as the IME reports it.
Future<void> _soft(WidgetTester t, String s) async {
  final edit = s.isEmpty
      ? {'oldText': '  ', 'deltaText': '', 'deltaStart': 1, 'deltaEnd': 2, 'selectionBase': 1, 'selectionExtent': 1}
      : {'oldText': '  ', 'deltaText': s, 'deltaStart': 2, 'deltaEnd': 2, 'selectionBase': 2 + s.length, 'selectionExtent': 2 + s.length};
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        -1,
        {
          'deltas': [edit],
        },
      ])),
      (_) {});
  await t.pump();
  await t.pump();
}

/// The hidden field takes the focus, as on a pane with no cursor only a test can.
Future<void> _focusField(WidgetTester t) async {
  t.widget<Focus>(find.descendant(of: find.byType(TermKeyboard), matching: find.byType(Focus)).first).focusNode!.requestFocus();
  await t.pump();
}

/// The user hides the soft keyboard; the field keeps the focus.
Future<void> _hide(WidgetTester t) async {
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await t.pump();
}

/// A plain shell's short history with a visible cursor.
Future<Harness> _shortHistory(WidgetTester t) async {
  final h = Harness(t, treeOf());
  await h.start();
  await h.opened();
  h.vts.single
    ..alt = false
    ..cursorVisible = true;
  await _dirty(h);
  await t.pump(const Duration(seconds: 1));
  return h;
}

Rect _historyBox(WidgetTester t) =>
    t.getRect(find.ancestor(of: find.byKey(const Key('screen')), matching: find.byType(SingleChildScrollView)));
