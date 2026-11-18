import 'dart:convert';

import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/terminal/term_session.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show FakeRelay, dataOn, flush, frame, grid, json, upgraded;
import 'session_term_test.dart' show FakeVt;

const _watch = 2, _claim = 3;
const _query = '\x1b[c', _reply = '\x1b[?62c';

/// A session watching `s1`'s left pane at 80x24 on channel 2.
Future<(TermSession, FakeRelay, FakeVt)> watched() async {
  final (m, r, _) = await upgraded();
  FakeVt? vt;
  final s = TermSession(m, 's1', 'left', vt: (c, rows) => vt = FakeVt(c, rows));
  await flush();
  r.send(json(LinkKind.opened, _watch, {'cols': 80, 'rows': 24}));
  await flush();
  return (s, r, vt!);
}

/// Takes the lead at 60x20; the relay's lead-change RESYNC comes in the same read unless [resync] is false.
Future<void> lead(TermSession s, FakeRelay r, {bool resync = true}) async {
  final f = s.takeOver(60, 20);
  await flush();
  r.send([
    ...json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}),
    ...json(LinkKind.lead, _claim, {'role': 'leader'}),
    if (resync) ...[...frame(LinkKind.resync, _watch), ...grid(_watch, 60, 20)],
  ]);
  expect(await f, isNull);
  await flush();
}

/// The program prints a DA query, which the emulator answers.
Future<void> query(FakeRelay r, FakeVt vt) async {
  vt.replies.addAll(utf8.encode(_reply));
  r.send(frame(LinkKind.data, _watch, utf8.encode(_query)));
  await flush();
}

String sent(FakeRelay r) => utf8.decode([for (final f in dataOn(r, _claim)) ...f.payload]);
List<int> closes(FakeRelay r) => [for (final f in r.frames) if (f.kind == LinkKind.close) f.channel];
List<Map> opens(FakeRelay r) => [for (final f in r.frames) if (f.kind == LinkKind.open) jsonDecode(utf8.decode(f.payload)) as Map];

void main() {
  test('takeOverOpensAClaimAtTheSize', () async {
    final (s, r, vt) = await watched();
    expect(s.leading, isFalse);
    await lead(s, r);
    expect(opens(r).last, {'type': 'vt', 'target': 's1', 'pane': 'left', 'claim': true, 'cols': 60, 'rows': 20});
    expect(s.leading, isTrue);
    expect((vt.cols, vt.rows), (60, 20));
    s.text('ls');
    expect(sent(r), 'ls');
  });

  test('takeOverReturnsTheRefusal', () async {
    final (s, r, _) = await watched();
    final f = s.takeOver(60, 20);
    await flush();
    r.send(json(LinkKind.close, _claim, {'reason': 'pane is not live'}));
    expect(await f, 'pane is not live');
    expect(s.leading, isFalse);
  });

  test('leaderSendsFocusGained', () async {
    final (s, r, vt) = await watched();
    await lead(s, r);
    expect(sent(r), '');

    final (s2, r2, vt2) = await watched();
    vt2.modes.add(1004);
    await lead(s2, r2);
    expect(sent(r2), '\x1b[I');
  });

  test('repliesAreSentOnlyWhileLeading', () async {
    final (s, r, vt) = await watched();
    await query(r, vt);
    expect(vt.replies, isEmpty);
    expect(dataOn(r, _claim), isEmpty);
    await lead(s, r);
    expect(sent(r), '');
    await query(r, vt);
    expect(sent(r), _reply);
  });

  test('repliesWaitForTheResyncAfterLeader', () async {
    final (s, r, vt) = await watched();
    await lead(s, r, resync: false);
    await query(r, vt);
    expect(sent(r), '');
    r.send([...frame(LinkKind.resync, _watch), ...grid(_watch, 60, 20)]);
    await flush();
    await query(r, vt);
    expect(sent(r), _reply);
  });

  test('leadLostReturnsToWatchAndStopsInput', () async {
    final (s, r, vt) = await watched();
    await lead(s, r);
    r.send([
      ...json(LinkKind.lead, _claim, {'role': 'computer'}),
      ...json(LinkKind.close, _claim, {'reason': 'the computer took the lead back'}),
    ]);
    await flush();
    expect(s.leading, isFalse);
    expect(s.leadLost, 'the computer took the lead back');
    s.text('x');
    s.key(VtKey.arrowUp);
    expect(s.paste('y'), isFalse);
    await query(r, vt);
    expect(sent(r), '');
    expect(s.ended, isNull);

    final f = s.takeOver(60, 20);
    expect(s.leadLost, isNull);
    await flush();
    r.send(json(LinkKind.close, 4, {'reason': 'refused'}));
    expect(await f, 'refused');
  });

  test('releaseSendsFocusLostThenClose', () async {
    final (s, r, vt) = await watched();
    vt.modes.add(1004);
    await lead(s, r);
    s.release();
    final after = [for (final f in r.frames) if (f.channel == _claim) f.kind].skipWhile((k) => k != LinkKind.data).toList();
    expect(after, [LinkKind.data, LinkKind.data, LinkKind.close]);
    expect(sent(r), '\x1b[I\x1b[O');
    expect((s.leading, s.leadLost), (false, null));
    s.text('x');
    expect(sent(r), '\x1b[I\x1b[O');
  });

  test('aPendingClaimIsClosedWhenItArrivesAfterRelease', () async {
    final (s, r, _) = await watched();
    final f = s.takeOver(60, 20);
    await flush();
    s.release();
    r.send([...json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}), ...json(LinkKind.lead, _claim, {'role': 'leader'})]);
    expect(await f, isNotNull);
    await flush();
    expect(closes(r), [_claim]);
    expect(s.leading, isFalse);
  });

  test('aSecondTakeOverSupersedesThePendingOne', () async {
    final (s, r, _) = await watched();
    final first = s.takeOver(60, 20);
    await flush();
    final second = s.takeOver(70, 20);
    await flush();
    r.send([...json(LinkKind.opened, 3, {'cols': 60, 'rows': 20}), ...json(LinkKind.opened, 4, {'cols': 70, 'rows': 20})]);
    expect(await first, isNotNull);
    expect(await second, isNull);
    await flush();
    expect(closes(r), [3]);
  });

  test('closeReleasesTheClaim', () async {
    final (s, r, _) = await watched();
    await lead(s, r);
    s.close();
    await flush();
    expect(closes(r), unorderedEquals([_watch, _claim]));
    expect(s.leading, isFalse);

    final (s2, r2, _) = await watched();
    final f = s2.takeOver(60, 20);
    await flush();
    s2.close();
    r2.send(json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}));
    expect(await f, isNotNull);
    await flush();
    expect(closes(r2), unorderedEquals([_watch, _claim]));
  });

  test('wheelFallsBackToArrowsOnTheAlternateScreen', () async {
    final (s, r, vt) = await watched();
    await lead(s, r);
    s.wheel(up: true, col: 3, row: 4);
    expect(sent(r), '', reason: 'no alternate scroll (1007)');
    vt.modes.add(1007);
    s.wheel(up: true, col: 3, row: 4);
    s.wheel(up: false, col: 3, row: 4);
    expect(sent(r), '\x1b[A\x1b[B');

    vt.alt = false;
    r.send(frame(LinkKind.data, _watch, utf8.encode('x')));
    await flush();
    s.wheel(up: true, col: 3, row: 4);
    expect(sent(r), '\x1b[A\x1b[B');

    vt.tracksMouse = true;
    s.wheel(up: true, col: 3, row: 4);
    expect(sent(r), '\x1b[A\x1b[Bwheel up 3,4');
  });

  test('resizeLeadSendsResizeAndSizesTheEmulator', () async {
    final (s, r, vt) = await watched();
    await lead(s, r);
    s.resizeLead(100, 40);
    s.resizeLead(5000, 0);
    final sizes = [for (final f in r.frames) if (f.kind == LinkKind.resize && f.channel == _claim) (f.size!.cols, f.size!.rows)];
    expect(sizes, [(100, 40), (1000, 1)]);
    expect((vt.cols, vt.rows), (1000, 1));
  });

  test('sessionEndWhileLeadingEndsBoth', () async {
    final (s, r, _) = await watched();
    await lead(s, r);
    r.send(json(LinkKind.close, _watch, {'reason': 'session ended'}));
    await flush();
    expect(s.ended, 'session ended');
    expect(s.leading, isFalse);
    expect(closes(r), [_claim]);
  });
}
