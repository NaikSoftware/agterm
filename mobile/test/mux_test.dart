import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/decoder.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/link/messages.dart';
import 'package:elis_mobile/link/mux.dart';
import 'package:elis_mobile/pages/page_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// The relay's end of the link: answers auth on lines, reads frames after `{"mux":1}` (unless [old]).
class FakeRelay {
  FakeRelay({this.old = false});

  final bool old;
  final _input = StreamController<Uint8List>();
  final lines = <String>[];
  final frames = <LinkFrame>[];
  final _decoder = LinkDecoder();
  var _buf = <int>[];
  var _framed = false;

  late final link = Link(_input.stream, _phone, () => unawaited(_input.close()), via: 'Wi-Fi');

  void _phone(List<int> bytes) {
    if (_framed) return frames.addAll(_decoder.feed(bytes));
    _buf.addAll(bytes);
    for (var nl = _buf.indexOf(10); nl >= 0; nl = _buf.indexOf(10)) {
      final line = utf8.decode(_buf.sublist(0, nl));
      _buf = _buf.sublist(nl + 1);
      lines.add(line);
      if ('$line\n' == linkUpgradeRequest && !old) {
        _framed = true;
        frames.addAll(_decoder.feed(_buf));
        _buf = [];
        return;
      }
      final o = jsonDecode(line) as Map;
      if (o.containsKey('auth')) send(answer(o['id']));
    }
  }

  void send(List<int> bytes) => _input.add(Uint8List.fromList(bytes));
  void drop() => unawaited(_input.close());

  /// The phone's channel-0 request lines.
  List<Map> get requests {
    final bytes = [for (final f in frames) if (f.channel == 0 && f.kind == LinkKind.data) ...f.payload];
    return [for (final l in const LineSplitter().convert(utf8.decode(bytes))) jsonDecode(l) as Map];
  }

  List<int?> get credits => [for (final f in frames) if (f.kind == LinkKind.credit) f.creditBytes];
}

List<int> answer(Object? id, [Map<String, Object> result = const {}]) => utf8.encode('${jsonEncode({'id': id, 'ok': true, 'result': result})}\n');
List<int> frame(LinkKind k, int ch, [List<int> payload = const []]) => LinkFrame(k, ch, Uint8List.fromList(payload)).encode();
List<int> json(LinkKind k, int ch, Map<String, Object> o) => LinkFrame.json(k, ch, o).encode();
List<int> grid(int ch, int cols, int rows) => frame(LinkKind.grid, ch, LinkFrame.resize(ch, cols, rows).payload);
final upgradeAnswer = utf8.encode('{"ok":true,"mux":1}\n');

String describe(VtEvent e) => switch (e) {
      Opened(:final cols, :final rows) => 'opened ${cols}x$rows',
      Data(:final bytes) => 'data ${utf8.decode(bytes)}',
      Grid(:final cols, :final rows) => 'grid ${cols}x$rows',
      Resync() => 'resync',
      Closed(:final reason) => 'closed $reason',
    };

final pairing = Pairing.parse('elis://pair?h=h&p=2&t=${'t' * 32}&f=${'a' * 64}')!;

Future<void> flush() => Future<void>.delayed(Duration.zero);

Future<(Connection, FakeRelay)> connect({bool old = false}) async {
  final r = FakeRelay(old: old);
  return (await Connection.open(pairing, tls: (p, t) async => r.link), r);
}

Future<(Mux, FakeRelay, Connection)> upgraded() async {
  final (c, r) = await connect();
  final m = Mux.upgrade(c);
  await flush();
  r.send(upgradeAnswer);
  return ((await m)!, r, c);
}

/// Opens a channel the relay accepts at 80x24; [seen] collects its events.
Future<VtChannel> openLive(Mux m, FakeRelay r, List<String> seen, {void Function()? onDone}) async {
  final f = m.open('w');
  await flush();
  r.send(json(LinkKind.opened, r.frames.last.channel, {'cols': 80, 'rows': 24}));
  final ch = await f;
  ch.events.listen((e) => seen.add(describe(e)), onDone: onDone);
  return ch;
}

String describeClaim(ClaimEvent e) => switch (e) {
      Lead(:final role) => 'lead $role',
      ClaimClosed(:final reason) => 'closed $reason',
    };

/// Claims a pane the relay accepts at 80x24 and leads; [seen] collects its events.
Future<ClaimChannel> claimLive(Mux m, FakeRelay r, List<String> seen) async {
  final f = m.claim('w', cols: 80, rows: 24).opened;
  await flush();
  final id = r.frames.last.channel;
  r.send([...json(LinkKind.opened, id, {'cols': 80, 'rows': 24}), ...json(LinkKind.lead, id, {'role': 'leader'})]);
  final ch = await f;
  ch.events.listen((e) => seen.add(describeClaim(e)));
  await flush();
  return ch;
}

List<LinkFrame> dataOn(FakeRelay r, int ch) => [for (final f in r.frames) if (f.channel == ch && f.kind == LinkKind.data) f];

void main() {
  test('upgradeSwitchesToFrames', () async {
    final (c, r) = await connect();
    final a = c.call('a');
    final m = Mux.upgrade(c);
    final b = c.call('b'); // held while the upgrade is pending: a line now would reach a relay that reads frames
    await flush();
    expect(r.lines.last, linkUpgradeRequest.trim());
    expect(r.lines.length, 3);
    final event = frame(LinkKind.data, 1, utf8.encode('{"event":"x"}\n'));
    // an earlier answer, the upgrade answer and half a frame in one read
    r.send([...answer(2, {'v': 'a'}), ...upgradeAnswer, ...event.sublist(0, 5)]);
    expect(await a, {'v': 'a'});
    final mux = (await m)!;
    final rows = <Map>[];
    mux.events.listen(rows.add);
    await flush();
    final req = r.requests.single;
    expect(req['cmd'], 'b');
    r.send([...event.sublist(5), ...frame(LinkKind.data, 0, answer(req['id'], {'v': 'b'}))]);
    expect(await b, {'v': 'b'});
    expect(rows, [{'event': 'x'}]);
    expect(r.lines.length, 3);
  });

  testWidgets('noAnswerKeepsTheLineProtocol', (t) async {
    final (c, r) = await connect(old: true);
    var closed = false;
    unawaited(c.closed.then((_) => closed = true));
    Mux? got;
    var done = false;
    unawaited(Mux.upgrade(c).then((v) => (got, done) = (v, true)));
    await t.pump(const Duration(milliseconds: 4900));
    expect(done, false);
    await t.pump(const Duration(milliseconds: 100));
    expect((done, got), (true, null));
    final a = c.call('a');
    await t.pump();
    final req = jsonDecode(r.lines.last) as Map;
    expect(req['cmd'], 'a');
    r.send(answer(req['id'], {'v': 'a'}));
    await t.pump();
    expect(await a, {'v': 'a'});
    // a late answer means the relay speaks frames now, which the line protocol cannot read
    r.send(upgradeAnswer);
    await t.pump();
    expect(closed, true);
  });

  test('controlCallsMatchById', () async {
    final (m, r, _) = await upgraded();
    final x = m.call('x');
    final y = m.call('y', target: 't', args: {'k': 1});
    await flush();
    final [rx, ry] = r.requests;
    expect(ry, {'cmd': 'y', 'target': 't', 'args': {'k': 1}, 'id': ry['id']});
    final ya = answer(ry['id'], {'v': 'y'});
    // y's answer spans two frames, x's follows in the second
    r.send([...frame(LinkKind.data, 0, ya.sublist(0, 4)), ...frame(LinkKind.data, 0, [...ya.sublist(4), ...answer(rx['id'], {'v': 'x'})])]);
    expect(await y, {'v': 'y'});
    expect(await x, {'v': 'x'});
  });

  test('eventsDroppedOrGapAskForATreeReread', () async {
    final (m, r, _) = await upgraded();
    final rows = <Map<String, dynamic>>[];
    m.events.listen(rows.add);
    final bytes = utf8.encode('{"event":"x"}\n{"dropped":3}\n{"gap":true}\n');
    r.send([...frame(LinkKind.data, 1, bytes.sublist(0, 7)), ...frame(LinkKind.data, 1, bytes.sublist(7))]);
    await flush();
    expect(rows, [{'event': 'x'}, {'dropped': 3}, {'gap': true}]);
    expect(rows.map(rereadsTree), [false, true, true]);
  });

  test('openStreamsData', () async {
    final (m, r, _) = await upgraded();
    final f = m.open('w1', pane: 'p2');
    await flush();
    final o = r.frames.last;
    expect((o.kind, o.channel), (LinkKind.open, 2));
    expect(jsonDecode(utf8.decode(o.payload)), {'type': 'vt', 'target': 'w1', 'pane': 'p2'});
    // DATA in the same read as OPENED is kept for the listener
    r.send([...json(LinkKind.opened, 2, {'cols': 80, 'rows': 24}), ...frame(LinkKind.data, 2, utf8.encode('AB')), ...grid(2, 100, 30)]);
    final ch = await f;
    final seen = <String>[];
    ch.events.listen((e) => seen.add(describe(e)));
    await flush();
    expect(seen, ['opened 80x24', 'data AB', 'grid 100x30']);
  });

  test('channelIdsAreUsedOnce', () async {
    final (m, r, _) = await upgraded();
    final seen = <String>[];
    await openLive(m, r, seen);
    r.send(json(LinkKind.close, 2, {'reason': 'session ended'}));
    await flush();
    expect(seen, ['opened 80x24', 'closed session ended']);
    final refused = m.open('w');
    await flush();
    r.send(json(LinkKind.opened, 3, {'error': 'too many open panes'}));
    await expectLater(refused, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'too many open panes')));
    unawaited(m.open('w'));
    await flush();
    expect([for (final f in r.frames) if (f.kind == LinkKind.open) f.channel], [2, 3, 4]);
  });

  test('duplicateRefusalDoesNotCloseALiveChannel', () async {
    final (m, r, _) = await upgraded();
    final f = m.open('w');
    await flush();
    r.send([...json(LinkKind.opened, 2, {'error': 'channel already open'}), ...json(LinkKind.opened, 2, {'cols': 80, 'rows': 24})]);
    final ch = await f;
    final seen = <String>[];
    ch.events.listen((e) => seen.add(describe(e)));
    r.send([...json(LinkKind.opened, 2, {'error': 'channel already open'}), ...frame(LinkKind.data, 2, utf8.encode('X'))]);
    await flush();
    expect(seen, ['opened 80x24', 'data X']);
  });

  test('creditFollowsConsumption', () async {
    final (m, r, _) = await upgraded();
    final ch = await openLive(m, r, []);
    r.send([...frame(LinkKind.data, 2, List.filled(100, 65)), ...frame(LinkKind.data, 2, List.filled(100, 65))]);
    await flush();
    ch.consumed(100);
    expect(r.credits, isEmpty, reason: 'the consumer has not caught up, and less than 16 KiB waits');
    ch.consumed(100);
    expect(r.credits, [200]);
    r.send(frame(LinkKind.data, 2, List.filled(40000, 65)));
    await flush();
    for (var i = 0; i < 40; i++) {
      ch.consumed(1000);
    }
    expect(r.credits, [200, 17000, 17000, 6000]);
  });

  test('resyncResetsTheEmulator', () async {
    final (m, r, _) = await upgraded();
    final seen = <String>[];
    final ch = await openLive(m, r, seen);
    r.send([
      ...frame(LinkKind.data, 2, utf8.encode('old')),
      ...frame(LinkKind.resync, 2),
      ...grid(2, 90, 20),
      ...frame(LinkKind.data, 2, utf8.encode('new')),
    ]);
    await flush();
    expect(seen, ['opened 80x24', 'data old', 'resync', 'grid 90x20', 'data new']);
    ch.consumed(3); // the bytes before RESYNC belong to the old window
    expect(r.credits, isEmpty);
    ch.consumed(3);
    expect(r.credits, [3]);
  });

  test('closeIsNotAnswered', () async {
    final (m, r, _) = await upgraded();
    final seen = <String>[];
    var ended = false;
    final ch = await openLive(m, r, seen, onDone: () => ended = true);
    await ch.close();
    final last = r.frames.last;
    expect((last.kind, last.channel), (LinkKind.close, 2));
    expect(jsonDecode(utf8.decode(last.payload)), {'reason': 'closed'});
    await flush();
    expect(ended, true);
    r.send(frame(LinkKind.data, 2, utf8.encode('late'))); // in flight before the CLOSE: dropped
    await flush();
    expect(seen, ['opened 80x24']);
  });

  test('revokedClosesTheLink', () async {
    final (m, r, c) = await upgraded();
    final seen = <String>[];
    await openLive(m, r, seen);
    final linkDone = m.closed.first;
    final f = m.open('w');
    await flush();
    r.send(json(LinkKind.opened, 3, {'error': 'revoked'}));
    await expectLater(f, throwsA(isA<Revoked>()));
    await c.closed;
    await linkDone;
    expect(seen, ['opened 80x24', 'closed $revokedMessage']);
  });

  test('linkLossClosesEveryChannel', () async {
    final (m, r, _) = await upgraded();
    final a = <String>[], b = <String>[];
    var ends = 0;
    await openLive(m, r, a, onDone: () => ends++);
    await openLive(m, r, b, onDone: () => ends++);
    final linkDone = m.closed.first;
    final pending = m.open('w');
    final call = m.call('x');
    await flush();
    final failed = [expectLater(pending, throwsA(isA<ElisError>())), expectLater(call, throwsA(isA<ElisError>()))];
    r.drop();
    await Future.wait(failed);
    await linkDone;
    await flush();
    expect([a, b, ends], [['opened 80x24', 'closed Disconnected'], ['opened 80x24', 'closed Disconnected'], 2]);
    await expectLater(m.open('w'), throwsA(isA<ElisError>()));
  });

  test('oldRelayErrorFallsBackAtOnce', () async {
    final (c, r) = await connect(old: true);
    final m = Mux.upgrade(c);
    final b = c.call('b'); // held during the upgrade, then sent as a line
    await flush();
    expect(r.lines.last, linkUpgradeRequest.trim());
    // a relay before M4a forwards {"mux":1} as a command and answers it without an id
    r.send(utf8.encode('{"id":null,"ok":false,"error":"unknown command"}\n'));
    expect(await m.timeout(const Duration(seconds: 1)), isNull);
    await flush();
    final req = jsonDecode(r.lines.last) as Map;
    expect(req['cmd'], 'b');
    r.send(answer(req['id'], {'v': 'b'}));
    expect(await b, {'v': 'b'});
  });

  test('linkLossDuringUpgradeFailsHeldCalls', () async {
    final (c, r) = await connect();
    final m = Mux.upgrade(c);
    final held = expectLater(c.call('b'), throwsA(isA<ElisError>()));
    await flush();
    r.drop();
    expect(await m.timeout(const Duration(seconds: 1)), isNull);
    await held;
  });

  test('aCharacterSplitAcrossReadsDecodesOnTheLinePath', () async {
    final (c, r) = await connect();
    final x = c.call('x');
    await flush();
    final bytes = answer((jsonDecode(r.lines.last) as Map)['id'], {'v': 'ü€'});
    final at = utf8.encode('{"id":2,"ok":true,"result":{"v":"ü').length + 1; // inside the 3-byte €
    r.send(bytes.sublist(0, at));
    r.send(bytes.sublist(at));
    expect(await x, {'v': 'ü€'});
  });

  test('aLongAnswerInSmallReadsParsesInLinearTime (4 MB in 500-byte reads)', () async {
    final (c, r) = await connect();
    final x = c.call('x');
    await flush();
    final big = 'a' * (4 << 20);
    final bytes = answer((jsonDecode(r.lines.last) as Map)['id'], {'v': big});
    final clock = Stopwatch()..start();
    for (var at = 0; at < bytes.length; at += 500) {
      r.send(bytes.sublist(at, min(at + 500, bytes.length)));
    }
    expect((await x)['v'], big);
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('aBadOpenedIsARefusalAndFreesTheSlot', () async {
    final (m, r, _) = await upgraded();
    final f = m.open('w');
    await flush();
    r.send(json(LinkKind.opened, 2, {'cols': '80', 'rows': 24}));
    await expectLater(f, throwsA(isA<ElisError>()));
    final last = r.frames.last;
    expect((last.kind, last.channel), (LinkKind.close, 2));
  });

  for (final (cols, rows) in [(0, 24), (80, 1001), (-1, 5)]) {
    test('anOutOfRangeOpenedIsRefused_${cols}x$rows', () async {
      final (m, r, _) = await upgraded();
      final f = m.open('w');
      await flush();
      r.send(json(LinkKind.opened, 2, {'cols': cols, 'rows': rows}));
      await expectLater(f, throwsA(isA<ElisError>()));
      expect((r.frames.last.kind, r.frames.last.channel), (LinkKind.close, 2));
    });
  }

  test('anOutOfRangeGridClosesTheChannel', () async {
    final (m, r, _) = await upgraded();
    final f = m.open('w');
    await flush();
    r.send(json(LinkKind.opened, 2, {'cols': 80, 'rows': 24}));
    final ch = await f;
    final seen = <String>[];
    ch.events.listen((e) => seen.add(describe(e)));
    r.send(grid(2, 80, 5000));
    await flush();
    expect(seen, ['opened 80x24', 'closed the relay sent a bad GRID']);
    expect((r.frames.last.kind, r.frames.last.channel), (LinkKind.close, 2));
  });

  test('claimOpenCarriesClaimAndSize', () async {
    final (m, r, _) = await upgraded();
    m.claim('w1', pane: 'p2', cols: 50, rows: 30);
    await flush();
    final o = r.frames.last;
    expect((o.kind, o.channel), (LinkKind.open, 2));
    expect(utf8.decode(o.payload), '{"claim":true,"cols":50,"pane":"p2","rows":30,"target":"w1","type":"vt"}');
  });

  test('claimCloseWaitsForTheQueuedInput', () => fakeAsync((a) {
    late FakeRelay r;
    late ClaimChannel ch;
    upgraded().then((v) async {
      r = v.$2;
      ch = await claimLive(v.$1, r, []);
    });
    a.elapse(Duration.zero);
    ch.send(Uint8List(16384 + 10));
    unawaited(ch.close());
    a.elapse(Duration.zero);
    expect(r.frames.where((f) => f.kind == LinkKind.close), isEmpty);
    r.send(LinkFrame.credit(ch.id, 16384).encode());
    a.elapse(Duration.zero);
    expect([for (final f in r.frames) if (f.channel == ch.id && f.kind != LinkKind.open) f.kind].skip(1).toList(),
        [LinkKind.data, LinkKind.close]);
  }));

  test('claimCloseIsBoundedWithoutCredit', () => fakeAsync((a) {
    late FakeRelay r;
    late ClaimChannel ch;
    upgraded().then((v) async {
      r = v.$2;
      ch = await claimLive(v.$1, r, []);
    });
    a.elapse(Duration.zero);
    ch.send(Uint8List(16384 + 10));
    unawaited(ch.close());
    a.elapse(const Duration(milliseconds: 999));
    expect(r.frames.where((f) => f.kind == LinkKind.close), isEmpty);
    a.elapse(const Duration(milliseconds: 1));
    expect(r.frames.where((f) => f.kind == LinkKind.close), hasLength(1));
  }));

  test('claimClosedBeforeOpenedThrowsAndSendsClose', () async {
    final (m, r, _) = await upgraded();
    final ch = m.claim('w', cols: 80, rows: 24);
    final opened = expectLater(ch.opened, throwsA(isA<ElisError>()));
    await ch.close();
    await opened;
    expect([for (final f in r.frames) if (f.channel == ch.id) f.kind], [LinkKind.open, LinkKind.close]);
  });

  test('claimRefusalThrows', () async {
    final (m, r, _) = await upgraded();
    final f = m.claim('w', cols: 80, rows: 24).opened;
    await flush();
    r.send(json(LinkKind.opened, 2, {'error': 'session not realized'}));
    await expectLater(f, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'session not realized')));
  });

  test('leadIsDelivered', () async {
    final (m, r, _) = await upgraded();
    final seen = <String>[];
    await claimLive(m, r, seen);
    r.send([...json(LinkKind.lead, 2, {'role': 'follower'}), ...json(LinkKind.close, 2, {'reason': 'the computer took the lead back'})]);
    await flush();
    expect(seen, ['lead leader', 'lead follower', 'closed the computer took the lead back']);
  });

  test('pasteIsSentByCredit', () async {
    final (m, r, _) = await upgraded();
    final ch = await claimLive(m, r, []);
    expect(ch.send(Uint8List(40 * 1024)), true);
    expect(dataOn(r, 2).map((d) => d.payload.length), [16384]);
    r.send(frame(LinkKind.credit, 2, LinkFrame.credit(2, 10000).payload));
    await flush();
    expect(dataOn(r, 2).map((d) => d.payload.length), [16384, 10000]);
    r.send([...frame(LinkKind.credit, 2, LinkFrame.credit(2, 6384).payload), ...frame(LinkKind.credit, 2, LinkFrame.credit(2, 16384).payload)]);
    await flush();
    final sizes = dataOn(r, 2).map((d) => d.payload.length).toList();
    expect(sizes.every((n) => n <= 16384), true);
    expect(sizes.fold(0, (a, n) => a + n), 40 * 1024);
  });

  test('sendCopiesTheCallersBuffer', () async {
    final (m, r, _) = await upgraded();
    final ch = await claimLive(m, r, []);
    ch.send(Uint8List(16384));
    final buf = Uint8List.fromList(utf8.encode('ab'));
    ch.send(buf);
    buf[0] = 120;
    r.send(frame(LinkKind.credit, 2, LinkFrame.credit(2, 16384).payload));
    await flush();
    expect(utf8.decode(dataOn(r, 2).last.payload), 'ab');
  });

  test('queueCapRefuses', () async {
    final (m, r, _) = await upgraded();
    final ch = await claimLive(m, r, []);
    expect(ch.send(Uint8List(16384 + (1 << 20))), true);
    expect(ch.send(Uint8List(1)), false);
    r.send(frame(LinkKind.credit, 2, LinkFrame.credit(2, 1).payload));
    await flush();
    expect(ch.send(Uint8List(1)), true);
  });

  test('resizeSendsAFrame', () async {
    final (m, r, _) = await upgraded();
    final ch = await claimLive(m, r, []);
    ch.resize(100, 40);
    final f = r.frames.last;
    expect((f.kind, f.channel, f.size), (LinkKind.resize, 2, (cols: 100, rows: 40)));
  });

  test('closeSendsCloseAndStopsSending', () async {
    final (m, r, _) = await upgraded();
    final ch = await claimLive(m, r, []);
    ch.send(Uint8List(20000));
    await ch.close();
    final last = r.frames.last;
    expect((last.kind, last.channel), (LinkKind.close, 2));
    expect(jsonDecode(utf8.decode(last.payload)), {'reason': 'closed'});
    r.send(frame(LinkKind.credit, 2, LinkFrame.credit(2, 16384).payload));
    await flush();
    expect(ch.send(Uint8List(1)), false);
    ch.resize(90, 30);
    expect(r.frames.last, same(last));
  });

  test('linkLossClosesTheClaim', () async {
    final (m, r, _) = await upgraded();
    final seen = <String>[];
    await claimLive(m, r, seen);
    final pending = m.claim('w', cols: 80, rows: 24).opened;
    await flush();
    final failed = expectLater(pending, throwsA(isA<ElisError>()));
    r.drop();
    await failed;
    await m.closed.first;
    await flush();
    expect(seen, ['lead leader', 'closed Disconnected']);
  });

  test('watchChannelIgnoresLead', () async {
    final (m, r, _) = await upgraded();
    final seen = <String>[];
    await openLive(m, r, seen);
    r.send([...json(LinkKind.lead, 2, {'role': 'leader'}), ...frame(LinkKind.data, 2, utf8.encode('X'))]);
    await flush();
    expect(seen, ['opened 80x24', 'data X']);
  });

  test('presentOpensAndDecodesLines', () async {
    final (m, r, _) = await upgraded();
    final ch = m.present('w');
    await flush();
    expect(r.frames.last.kind, LinkKind.open);
    expect(jsonDecode(utf8.decode(r.frames.last.payload)), {'type': 'present', 'target': 'w'});
    final id = r.frames.last.channel;
    final lines = <Map>[];
    ch.lines.listen(lines.add);
    final line = utf8.encode('${jsonEncode({'t': 'page', 'id': 'p1'})}\n');
    r.send([...json(LinkKind.opened, id, {}), ...frame(LinkKind.data, id, line.sublist(0, 7))]);
    await ch.opened;
    await flush();
    expect(lines, isEmpty);
    r.send(frame(LinkKind.data, id, line.sublist(7)));
    await flush();
    expect(lines, [{'t': 'page', 'id': 'p1'}]);
    expect(r.credits, [7, line.length - 7]);
    ch.send({'t': 'closed', 'id': 'p1', 'dismissed': true});
    expect(utf8.decode(dataOn(r, id).single.payload), '{"t":"closed","id":"p1","dismissed":true}\n');
    r.send(json(LinkKind.close, id, {'reason': 'presentation ended'}));
    await flush();
    expect(ch.ended, 'presentation ended');
  });

  test('presentEndsDisconnectedOnLinkLoss', () async {
    final (m, r, _) = await upgraded();
    final ch = m.present('w');
    await flush();
    r.send(json(LinkKind.opened, r.frames.last.channel, {}));
    await ch.opened;
    r.drop();
    await m.closed.first;
    expect(ch.ended, 'Disconnected');
  });

  test('aSecondPresentForTheSameTargetClosesTheFirstAndCanStillBeRefused', () async {
    final (m, r, _) = await upgraded();
    final first = m.present('w');
    unawaited(first.opened.catchError((Object _) {}));
    final second = m.present('w');
    await flush();
    expect(first.ended, 'closed');
    expect([for (final f in r.frames) if (f.channel != 0) (f.kind, f.channel)],
        [(LinkKind.open, first.id), (LinkKind.close, first.id), (LinkKind.open, second.id)]);
    r.send(json(LinkKind.opened, r.frames.last.channel, {'error': 'channel already open'}));
    await expectLater(second.opened, throwsA(isA<ElisError>()));
    expect(second.ended, 'channel already open');
  });

  test('anOlderRelayRefusesPresent', () async {
    final (m, r, _) = await upgraded();
    final link = PageLink(m, 'w');
    await flush();
    final opens = [for (final f in r.frames) if (f.kind == LinkKind.open) f];
    r.send(json(LinkKind.opened, opens.single.channel, {'error': 'unsupported channel type'}));
    await flush();
    expect(link.supported, isFalse);
    expect([for (final f in r.frames) if (f.kind == LinkKind.open) f], hasLength(1));
    final ch = m.present('w');
    await flush();
    r.send(json(LinkKind.opened, r.frames.last.channel, {'error': 'unsupported channel type'}));
    await expectLater(ch.opened, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'unsupported channel type')));
    link.dispose();
  });

  test('forwardOpensCarriesBytesAndCredits', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    final got = <String>[];
    ch.bytes.listen((b) => got.add(utf8.decode(b)));
    expect(ch.send(Uint8List.fromList(utf8.encode('GET / HTTP/1.1\r\n\r\n'))), true);
    await flush();
    final id = r.frames.firstWhere((f) => f.kind == LinkKind.open).channel;
    expect(jsonDecode(utf8.decode(r.frames.firstWhere((f) => f.kind == LinkKind.open).payload)),
        {'type': 'forward', 'target': 'w', 'page': 'p1'});
    expect(utf8.decode(dataOn(r, id).single.payload), 'GET / HTTP/1.1\r\n\r\n');
    r.send([...json(LinkKind.opened, id, {}), ...frame(LinkKind.data, id, utf8.encode('HTTP/1.1 200'))]);
    await ch.opened;
    await flush();
    expect(got, ['HTTP/1.1 200']);
    expect(r.credits, [12]);
  });

  test('forwardSendIsHeldByTheWindow', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    await flush();
    final id = r.frames.last.channel;
    r.send(json(LinkKind.opened, id, {}));
    await ch.opened;
    expect(ch.send(Uint8List(70000)), true);
    expect(dataOn(r, id).map((d) => d.payload.length), [65536]);
    r.send(frame(LinkKind.credit, id, LinkFrame.credit(id, 65536).payload));
    await flush();
    expect(dataOn(r, id).map((d) => d.payload.length), [65536, 70000 - 65536]);
  });

  test('aForwardBacklogEndsOnCreditAndAnUnflushedCloseGoesAtOnce', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    await flush();
    final id = r.frames.last.channel;
    expect(ch.send(Uint8List(65536)), true);
    expect(ch.backlog, isNull);
    expect(ch.send(Uint8List(10)), true);
    final backlog = ch.backlog!;
    r.send(frame(LinkKind.credit, id, LinkFrame.credit(id, 65536).payload));
    await backlog;
    expect(ch.backlog, isNull);
    ch.send(Uint8List(65536 + 10));
    unawaited(ch.close(flush: false));
    expect((r.frames.last.kind, r.frames.last.channel), (LinkKind.close, id));
  });

  test('aRefusedForwardThrowsTheReason', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    await flush();
    r.send(json(LinkKind.opened, r.frames.last.channel, {'error': 'too many connections'}));
    await expectLater(ch.opened, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'too many connections')));
    expect(ch.send(Uint8List(1)), false);
  });

  test('aCloseBeforeOpenedEndsTheForward', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    final done = ch.bytes.toList();
    await flush();
    r.send(json(LinkKind.close, r.frames.last.channel, {'reason': 'page closed'}));
    await expectLater(ch.opened, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'page closed')));
    expect(await done, isEmpty);
  });

  test('aForwardCloseEndsItsBytesAndSendsClose', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    final done = ch.bytes.toList();
    await flush();
    final id = r.frames.last.channel;
    r.send(json(LinkKind.opened, id, {}));
    await ch.opened;
    await ch.close();
    expect(await done, isEmpty);
    expect((r.frames.last.kind, r.frames.last.channel), (LinkKind.close, id));
  });

  test('aForwardEndsOnLinkLoss', () async {
    final (m, r, _) = await upgraded();
    final ch = m.forward('w', 'p1');
    final done = ch.bytes.toList();
    await flush();
    r.send(json(LinkKind.opened, r.frames.last.channel, {}));
    await ch.opened;
    r.drop();
    expect(await done, isEmpty);
  });
}
