import 'dart:convert';

import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/terminal/term_session.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:fake_async/fake_async.dart';
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

/// Takes the lead at [cols]x[rows]; the relay's lead-change RESYNC comes in the same read unless [resync] is false.
Future<void> lead(TermSession s, FakeRelay r, {bool resync = true, int cols = 60, int rows = 20}) async {
  final f = s.takeOver(cols, rows);
  await flush();
  r.send([
    ...json(LinkKind.opened, _claim, {'cols': cols, 'rows': rows}),
    ...json(LinkKind.lead, _claim, {'role': 'leader'}),
    if (resync) ...[...frame(LinkKind.resync, _watch), ...grid(_watch, cols, rows)],
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

/// Runs [body] under fake time with the session leading at 60x20.
void timed(void Function(FakeAsync a, TermSession s, FakeRelay r) body) => fakeAsync((a) {
  late (TermSession, FakeRelay, FakeVt) w;
  watched().then((v) async => await lead((w = v).$1, v.$2));
  a.elapse(Duration.zero);
  body(a, w.$1, w.$2);
});

List<(int, int)> resizes(FakeRelay r) => [for (final f in r.frames) if (f.kind == LinkKind.resize && f.channel == _claim) (f.size!.cols, f.size!.rows)];
/// The relay acknowledges 2 MiB, so everything the claim channel holds goes out.
void ackAll(FakeRelay r) => r.send([for (var i = 0; i < 128; i++) ...LinkFrame.credit(_claim, 16384).encode()]);
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
    expect(s.text('x'), isFalse);
    expect(s.key(VtKey.arrowUp, seq: '\x1b[A'), isFalse);
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

  test('aPendingClaimIsClosedAtRelease', () async {
    final (s, r, _) = await watched();
    final f = s.takeOver(60, 20);
    await flush();
    s.release();
    await flush();
    expect(closes(r), [_claim]);
    r.send([...json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}), ...json(LinkKind.lead, _claim, {'role': 'leader'})]);
    expect(await f, isNull);
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
    expect(closes(r), [3], reason: 'closed before its OPENED, so the relay never attaches it');
    r.send([...json(LinkKind.opened, 3, {'cols': 60, 'rows': 20}), ...json(LinkKind.opened, 4, {'cols': 70, 'rows': 20})]);
    expect(await first, isNull);
    expect(await second, isNull);
    await flush();
    expect(closes(r), [3]);
    expect(s.leading, isFalse, reason: 'no LEAD yet');
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
    expect(await f, isNull);
    await flush();
    expect(closes(r2), unorderedEquals([_watch, _claim]));
    expect(s2.leading, isFalse);
  });

  test('wheelFallsBackToArrowsOnTheAlternateScreen', () async {
    final (s, r, vt) = await watched();
    await lead(s, r);
    vt.alt = true; // the replay after the lead's reset
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

  test('resizeLeadSendsResizeOnly', () async {
    final (s, r, vt) = await watched();
    await lead(s, r);
    s.resizeLead(100, 40);
    s.resizeLead(5000, 0);
    expect(resizes(r), [(100, 40), (1000, 1)]);
    expect((vt.cols, vt.rows), (60, 20));
  });

  test('oldGridBytesAfterAResizeDrawAtTheOldGrid', () async {
    final (s, r, vt) = await watched();
    await lead(s, r, cols: 80, rows: 24);
    s.resizeLead(60, 20);
    expect(resizes(r), [(60, 20)]);
    r.send(frame(LinkKind.data, _watch, utf8.encode('old')));
    await flush();
    expect((vt.cols, vt.rows), (80, 24));
    r.send(frame(LinkKind.resync, _watch));
    await flush();
    expect((vt.cols, vt.rows), (80, 24));
    r.send(grid(_watch, 60, 20));
    await flush();
    expect((vt.cols, vt.rows), (60, 20));
  });

  test('resizeLeadBeforeLeaderWaitsForTheLead', () async {
    final (s, r, vt) = await watched();
    final f = s.takeOver(60, 20);
    await flush();
    r.send(json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}));
    expect(await f, isNull);
    s.resizeLead(100, 40);
    expect(resizes(r), isEmpty);
    expect((vt.cols, vt.rows), (80, 24));
    r.send(json(LinkKind.lead, _claim, {'role': 'leader'}));
    await flush();
    expect(resizes(r), [(100, 40)]);
    expect((vt.cols, vt.rows), (100, 40));
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

  test('inputBeforeTheLeadIsSentOnceAtTheLeaderReport', () async {
    final (s, r, vt) = await watched();
    vt.modes.add(1004);
    s.arm();
    expect(s.pending, isTrue);
    expect(s.key(VtKey.arrowUp, seq: '\x1b[A'), isTrue);
    expect(s.text('ls'), isTrue);
    await lead(s, r);
    expect(sent(r), '\x1b[I\x1b[Als');
    expect(s.pending, isFalse);
    expect(s.takeUnsent(), isEmpty);
  });

  test('lineSendsEnterAfter20ms', () => timed((a, s, r) {
    expect(s.line('ls'), isTrue);
    expect(sent(r), 'ls');
    a.elapse(const Duration(milliseconds: 19));
    expect(sent(r), 'ls');
    a.elapse(const Duration(milliseconds: 1));
    expect(sent(r), 'ls\r');
  }));

  test('aKeyInTheGapFollowsTheEnter', () => timed((a, s, r) {
    s.line('ls');
    expect(s.key(VtKey.tab, seq: '\t'), isTrue);
    expect(sent(r), 'ls');
    a.elapse(const Duration(milliseconds: 20));
    expect(sent(r), 'ls\r\t');
  }));

  test('aFlushedLineKeepsTheGap', () => fakeAsync((a) {
    late FakeRelay r;
    watched().then((v) async {
      r = v.$2;
      v.$1.arm();
      v.$1.line('ls');
      await lead(v.$1, r);
    });
    a.elapse(Duration.zero);
    expect(sent(r), 'ls');
    a.elapse(const Duration(milliseconds: 19));
    expect(sent(r), 'ls');
    a.elapse(const Duration(milliseconds: 1));
    expect(sent(r), 'ls\r');
  }));

  test('emptyLineSendsOnlyEnter', () async {
    final (s, r, _) = await watched();
    await lead(s, r);
    expect(s.line(''), isTrue);
    expect(sent(r), '\r');
  });

  test('refusalKeepsTheQueueForTakeUnsent', () async {
    final (s, r, _) = await watched();
    s.arm();
    s.key(VtKey.escape, seq: '\x1b');
    s.line('ls');
    final f = s.takeOver(60, 20);
    await flush();
    r.send(json(LinkKind.close, _claim, {'reason': 'pane is not live'}));
    expect(await f, 'pane is not live');
    expect(s.pending, isFalse);
    expect(s.takeUnsent(), ['\x1b', 'ls', '\r']);
    expect(s.takeUnsent(), isEmpty);
  });

  test('releaseBeforeTheLeadDropsTheQueue', () async {
    final (s, r, _) = await watched();
    s.arm();
    s.text('ls');
    final f = s.takeOver(60, 20);
    await flush();
    s.release();
    expect(s.pending, isFalse);
    expect(s.takeUnsent(), isEmpty);
    expect(s.text('x'), isFalse);
    r.send([...json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}), ...json(LinkKind.lead, _claim, {'role': 'leader'})]);
    expect(await f, isNull);
    await flush();
    expect(dataOn(r, _claim), isEmpty);
  });

  test('claimClosedDropsTheQueue', () async {
    final (s, r, _) = await watched();
    s.arm();
    final f = s.takeOver(60, 20);
    await flush();
    r.send(json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}));
    expect(await f, isNull);
    s.text('ls');
    r.send(json(LinkKind.close, _claim, {'reason': 'the computer took the lead back'}));
    await flush();
    expect(s.pending, isFalse);
    expect(s.takeUnsent(), isEmpty);
    expect(s.text('x'), isFalse);
  });

  test('queueRefusesPastItsBounds', () async {
    final (s, _, _) = await watched();
    s.arm();
    for (var i = 0; i < 256; i++) {
      expect(s.text('x'), isTrue);
    }
    expect(s.text('x'), isFalse);
    expect(s.takeUnsent(), hasLength(256));
    expect(s.paste('x' * ((1 << 20) + 1)), isFalse);
    expect(s.paste('x' * (1 << 20)), isTrue);
  });

  test('inputWithoutArmOrLeadReturnsFalse', () async {
    final (s, r, _) = await watched();
    expect(s.pending, isFalse);
    expect([s.key(VtKey.enter, seq: '\r'), s.text('a'), s.paste('b'), s.line('c')], [false, false, false, false]);
    expect(s.takeUnsent(), isEmpty);
    expect(r.frames.where((f) => f.channel == _claim), isEmpty);
  });

  test('releaseInTheGapKeepsTheGapThenCloses', () => fakeAsync((a) {
    late FakeRelay r;
    late TermSession s;
    watched().then((v) async {
      (s, r) = (v.$1, v.$2);
      v.$3.modes.add(1004);
      await lead(s, r);
    });
    a.elapse(Duration.zero);
    s.line('ls');
    s.text('x');
    s.release();
    a.elapse(Duration.zero);
    expect(sent(r), '\x1b[Ils');
    expect(closes(r), isEmpty);
    a.elapse(const Duration(milliseconds: 20));
    expect(sent(r), '\x1b[Ils\rx\x1b[O');
    expect(closes(r), [_claim]);
  }));

  test('closeInTheGapStillSendsTheEnter', () => fakeAsync((a) {
    late FakeRelay r;
    late TermSession s;
    watched().then((v) async {
      (s, r) = (v.$1, v.$2);
      await lead(s, r);
    });
    a.elapse(Duration.zero);
    s.line('ls');
    s.close();
    a.elapse(const Duration(milliseconds: 20));
    expect(sent(r), 'ls\r');
    expect(closes(r), unorderedEquals([_watch, _claim]));
  }));

  test('aPendingClickWaitsForTheLeadAndAWheelIsDropped', () async {
    final (s, r, vt) = await watched();
    vt.tracksMouse = true;
    s.arm();
    s.click(col: 1, row: 2);
    s.wheel(up: true, col: 1, row: 2);
    expect(vt.clicks, isEmpty);
    await lead(s, r);
    expect(sent(r), 'click 1,2');
  });

  test('aPendingClickIsNotTypedIndirectly', () async {
    final (s, _, _) = await watched();
    s.arm();
    s.click(col: 1, row: 2);
    s.text('a');
    expect(s.takeUnsent(), ['a']);
  });

  test('clickSendsTheEncodedBytesWhileLeading', () async {
    final (s, r, vt) = await watched();
    vt.tracksMouse = true;
    await lead(s, r);
    s.click(col: 3, row: 4);
    expect(sent(r), 'click 3,4');
    expect(vt.clicks, [(3, 4)]);
  });

  test('repliesArmWhenTheWatchOpensUnderAHeldClaim', () async {
    final (m, r, _) = await upgraded();
    FakeVt? vt;
    final s = TermSession(m, 's1', 'left', vt: (c, rows) => vt = FakeVt(c, rows));
    await flush();
    final f = s.takeOver(60, 20);
    await flush();
    r.send([...json(LinkKind.opened, _claim, {'cols': 60, 'rows': 20}), ...json(LinkKind.lead, _claim, {'role': 'leader'})]);
    expect(await f, isNull);
    await flush();
    expect(s.leading, isTrue);
    expect(s.text('ls'), isTrue);
    r.send(json(LinkKind.opened, _watch, {'cols': 80, 'rows': 24}));
    await flush();
    expect(sent(r), 'ls');
    await query(r, vt!);
    expect(sent(r), 'ls$_reply');
  });

  test('aRefusedLineDropsItsEnter', () async {
    final (s, r, _) = await watched();
    await lead(s, r);
    expect(s.paste('x' * (1 << 20)), isTrue);
    expect(s.line('y' * 20000), isFalse);
    expect(s.takeUnsent(), isEmpty);
  });

  test('aRefusedSendStopsTheDrain', () => timed((a, s, r) {
    var notified = 0;
    s.addListener(() => notified++);
    expect(s.paste('x' * (1 << 20)), isTrue);
    expect(s.line('a'), isTrue);
    expect(s.paste('y' * 20000), isTrue);
    expect(s.key(VtKey.tab, seq: '\t'), isTrue);
    a.elapse(const Duration(milliseconds: 20));
    ackAll(r);
    a.elapse(Duration.zero);
    expect(sent(r), '${'x' * (1 << 20)}a\r');
    expect(notified, 1);
    expect(s.inputLost, 'The computer has not taken the earlier input yet.');
    expect(s.inputLost, isNull);
    expect(s.takeUnsent(), isEmpty);
  }));

  test('aRefusedSendStopsTheLeadDrain', () async {
    final (s, r, _) = await watched();
    await lead(s, r);
    expect(s.paste('x' * (1 << 20)), isTrue);
    s.arm();
    r.send(json(LinkKind.lead, _claim, {'role': 'computer'}));
    await flush();
    expect(s.paste('y' * 20000), isTrue);
    expect(s.text('z'), isTrue);
    r.send(json(LinkKind.lead, _claim, {'role': 'leader'}));
    await flush();
    ackAll(r);
    await flush();
    expect(sent(r), 'x' * (1 << 20));
    expect(s.inputLost, 'The computer has not taken the earlier input yet.');
    expect(s.inputLost, isNull);
    expect(s.takeUnsent(), isEmpty);
  });
}
