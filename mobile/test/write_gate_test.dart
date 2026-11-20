import 'dart:async';
import 'dart:convert';

import 'package:elis_mobile/chat/checks.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/terminal/term_session.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show FakeRelay, dataOn, flush, frame, grid, json;
import 'term_session_test.dart' show lead, opens, sent, watched;

class Grids extends ChangeNotifier {
  Grid g = Grid(const []);
  void tick() => notifyListeners();
}

/// Records each write with the fake time it went out; [onWrite] is how the program answers it.
class Recorder implements GateWriter {
  Recorder(this.now, {this.onWrite});
  final Duration Function() now;
  final void Function(GateWrite w)? onWrite;
  final writes = <(GateWrite, Duration)>[];
  bool leads = true, accepts = true;

  @override
  Future<bool> lead() async => leads;
  @override
  Future<bool> write(GateWrite w) async {
    if (!accepts) return false;
    writes.add((w, now()));
    onWrite?.call(w);
    return true;
  }

  @override
  bool pasteSafe(String text) => !text.contains('\n');
}

const _claim = 3, _watch = 2;
bool _any(Grid _) => true;

GateStep _step(GateWrite w, {bool Function(Grid)? ready, bool Function(Grid)? done, String? why}) =>
    GateStep(w, ready: ready ?? _any, done: done ?? _any, why: why);

/// A gate over [grids] with a [Recorder] that ticks the grid after each write.
(WriteGate, Recorder) _gate(FakeAsync a, Grids grids, {bool remote = false, String? blocked, bool tick = true}) {
  final w = Recorder(() => a.elapsed, onWrite: tick ? (_) => scheduleMicrotask(grids.tick) : null);
  final gate = WriteGate(grids: grids, grid: () => grids.g, writer: () => w, remote: () => remote, blocked: () => blocked);
  return (gate, w);
}

GateResult? _run(FakeAsync a, WriteGate gate, int total, Future<void> Function(GateSequence s) body, {Duration until = Duration.zero}) {
  GateResult? r;
  gate.run(total, body).then((v) => r = v);
  a.elapse(until);
  a.flushMicrotasks();
  return r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('oneWritePerStepInOrder', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids);
        final writes = [TextWrite('a'), KeyWrite(VtKey.enter), PasteWrite('b')];
        final r = _run(a, gate, 3, (s) async {
          for (final (i, x) in writes.indexed) {
            await s.send(_step(x, done: (_) => w.writes.length == i + 1));
          }
        });
        expect(r?.outcome, GateOutcome.done);
        expect(r?.reason, '');
        expect([for (final (x, _) in w.writes) x], writes);
      }));

  test('readyMismatchStopsBeforeWriting', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids);
        final r = _run(a, gate, 3, (s) async {
          await s.send(_step(TextWrite('a')));
          await s.send(_step(TextWrite('b'), ready: (_) => false, why: 'No input row'));
          await s.send(_step(TextWrite('c')));
        });
        expect((r?.outcome, r?.step, r?.total, r?.reason), (GateOutcome.mismatch, 2, 3, 'No input row'));
        expect(w.writes, hasLength(1));
      }));

  test('timeoutStops', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids, tick: false);
        GateResult? r;
        gate.run(1, (s) => s.send(_step(TextWrite('a')))).then((v) => r = v);
        a.elapse(checks.timeout - const Duration(milliseconds: 1));
        expect(r, isNull);
        a.elapse(const Duration(milliseconds: 1));
        expect((r?.outcome, r?.step), (GateOutcome.timeout, 1));
        expect(w.writes, hasLength(1));
      }));

  test('remoteTimeoutCountsFromGrid', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, _) = _gate(a, grids, remote: true, tick: false);
        var answered = false;
        GateResult? r;
        gate.run(1, (s) => s.send(_step(TextWrite('a'), done: (_) => answered))).then((v) => r = v);
        a.elapse(const Duration(seconds: 3));
        grids.tick();
        a.elapse(const Duration(seconds: 1));
        answered = true;
        grids.tick();
        a.flushMicrotasks();
        expect(r?.outcome, GateOutcome.done);
      }));

  test('remoteTimeoutIsCappedAt5s', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, _) = _gate(a, grids, remote: true, tick: false);
        GateResult? r;
        gate.run(1, (s) => s.send(_step(TextWrite('a'), done: (_) => false))).then((v) => r = v);
        a.elapse(const Duration(milliseconds: 4500));
        grids.tick();
        a.elapse(const Duration(milliseconds: 499));
        expect(r, isNull);
        a.elapse(const Duration(milliseconds: 1));
        expect(r?.outcome, GateOutcome.timeout);
      }));

  test('secondRunIsBusy', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids, tick: false);
        final first = _run(a, gate, 1, (s) => s.send(_step(TextWrite('a'))));
        expect(first, isNull);
        final second = _run(a, gate, 1, (s) => s.send(_step(TextWrite('b'))));
        expect((second?.outcome, second?.reason), (GateOutcome.busy, 'Another answer is being sent'));
        expect(w.writes, hasLength(1));
      }));

  test('progressCounts', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, _) = _gate(a, grids, tick: false);
        final seen = <String>[];
        var go = false;
        gate.run(2, (s) async {
          await s.send(_step(TextWrite('a'), done: (_) => go));
          await s.send(_step(TextWrite('b'), done: (_) => go));
        });
        a.flushMicrotasks();
        seen.add(gate.progress);
        go = true;
        grids.tick();
        a.flushMicrotasks();
        seen.add(gate.progress);
        expect(seen, ['Sending 1/2', 'Sending 2/2']);
        grids.tick();
        a.flushMicrotasks();
        expect(gate.running, isFalse);
      }));

  test('addStepsGrowsTheTotal', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, _) = _gate(a, grids);
        final r = _run(a, gate, 1, (s) async {
          s.addSteps(2);
          for (var i = 0; i < 3; i++) {
            await s.send(_step(TextWrite('$i')));
          }
        });
        expect((r?.step, r?.total), (3, 3));
      }));

  test('blockedNeverWrites', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids, blocked: 'The session ended');
        final r = _run(a, gate, 1, (s) => s.send(_step(TextWrite('a'))));
        expect((r?.outcome, r?.reason), (GateOutcome.blocked, 'The session ended'));
        expect(w.writes, isEmpty);
      }));

  test('everyStopHasAReason', () => fakeAsync((a) {
        Future<void> one(GateSequence s) => s.send(_step(TextWrite('a')));
        final grids = Grids();
        final results = <GateOutcome, String>{};
        void add(GateResult? r) => results[r!.outcome] = r.reason;

        var (gate, w) = _gate(a, grids);
        add(_run(a, gate, 1, one));
        add(_run(a, gate, 1, (s) => s.send(_step(TextWrite('a'), ready: (_) => false))));
        (gate, w) = _gate(a, grids, tick: false);
        add(_run(a, gate, 1, one, until: checks.timeout));
        w.accepts = false;
        add(_run(a, gate, 1, one));
        w.leads = false;
        add(_run(a, gate, 1, one));
        add(_run(a, _gate(a, grids, blocked: 'The session ended').$1, 1, one));
        expect(_run(a, gate = _gate(a, grids, tick: false).$1, 1, one), isNull);
        add(_run(a, gate, 1, one));

        expect(results, {
          GateOutcome.done: '',
          GateOutcome.mismatch: "Claude's screen is not as expected",
          GateOutcome.timeout: "Claude's screen did not change",
          GateOutcome.writeFailed: 'The key did not reach the computer',
          GateOutcome.noLead: 'Could not take over the session',
          GateOutcome.blocked: 'The session ended',
          GateOutcome.busy: 'Another answer is being sent',
        });
        a.elapse(checks.timeout);
      }));

  test('aThrowingBodyFreesTheGate', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, _) = _gate(a, grids);
        Object? err;
        gate.run(1, (s) async => throw StateError('boom')).catchError((Object e) {
          err = e;
          return GateResult(GateOutcome.done, 0, 0, '');
        });
        a.flushMicrotasks();
        expect(err, isStateError);
        expect(gate.running, isFalse);
      }));

  test('disposingMidRunIsQuiet', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, _) = _gate(a, grids, tick: false);
        GateResult? r;
        gate.run(1, (s) => s.send(_step(TextWrite('a')))).then((v) => r = v);
        a.flushMicrotasks();
        gate.dispose();
        a.elapse(checks.timeout);
        expect(r?.outcome, GateOutcome.timeout);
      }));

  test('escapeIsFollowedByAGap', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids);
        final r = _run(a, gate, 2, (s) async {
          await s.send(_step(KeyWrite(VtKey.escape)));
          await s.send(_step(TextWrite('x')));
        }, until: escapeGap);
        expect(r?.outcome, GateOutcome.done);
        expect([for (final (_, t) in w.writes) t], [Duration.zero, escapeGap]);
      }));

  test('gapSpansRuns', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids);
        expect(_run(a, gate, 1, (s) => s.send(_step(KeyWrite(VtKey.escape))))?.outcome, GateOutcome.done);
        a.elapse(const Duration(milliseconds: 40));
        var checkedAt = Duration.zero;
        final r = _run(a, gate, 1, (s) => s.send(_step(TextWrite('x'), ready: (_) {
              checkedAt = a.elapsed;
              return true;
            })), until: escapeGap);
        expect(r?.outcome, GateOutcome.done);
        expect(w.writes.last.$2, escapeGap);
        expect(checkedAt, escapeGap, reason: 'the ready check sees the grid after the Esc');
      }));

  test('noGapAfterOtherKeys', () => fakeAsync((a) {
        final grids = Grids();
        final (gate, w) = _gate(a, grids);
        final r = _run(a, gate, 2, (s) async {
          await s.send(_step(TextWrite('1')));
          await s.send(_step(TextWrite('2')));
        });
        expect(r?.outcome, GateOutcome.done);
        expect([for (final (_, t) in w.writes) t], [Duration.zero, Duration.zero]);
      }));

  test('typeWriterRefusesMultilinePaste', () async {
    final typed = <String>[];
    final w = TypeWriter((t) async {
      typed.add(t);
      return null;
    });
    expect(w.pasteSafe('one\ntwo'), isFalse);
    expect(w.pasteSafe('one two'), isTrue);
    expect(await w.lead(), isTrue);
    expect(await w.write(KeyWrite(VtKey.escape)), isTrue);
    expect(await w.write(KeyWrite(VtKey.tab, vtShift)), isTrue);
    expect(await w.write(TextWrite('hi')), isTrue);
    expect(typed, ['\x1b', '\x1b[Z', 'hi']);
    expect(await TypeWriter((_) async => 'refused').write(TextWrite('x')), isFalse);
    expect(await w.write(KeyWrite(VtKey.s, vtCtrl)), isFalse, reason: 'a key with no xterm form is refused, not thrown');
  });

  group('over a TermSession', () {
    Grid? view(TermSession s) => s.frame == null ? null : Grid.of(s.frame!);

    test('gateWaitsForLeadBeforeChecking', () async {
      final (s, r, _) = await watched();
      var claims = 0;
      final gate = WriteGate(
        grids: s,
        grid: () => view(s),
        writer: () => LeadWriter(() => s, () async {
          claims++;
          return await s.takeOver(40, 20) == null;
        }),
        remote: () => false,
        blocked: () => null,
      );
      bool? leadingAtReady;
      final run = gate.run(1, (q) => q.send(GateStep(KeyWrite(VtKey.enter), ready: (_) {
            leadingAtReady = s.leading;
            return true;
          }, done: (_) => true)));
      await flush();
      expect(claims, 1);
      expect(opens(r).last['claim'], isTrue);
      expect(dataOn(r, _claim), isEmpty);
      expect(leadingAtReady, isNull);

      r.send([
        ...json(LinkKind.opened, _claim, {'cols': 40, 'rows': 20}),
        ...json(LinkKind.lead, _claim, {'role': 'leader'}),
        ...frame(LinkKind.resync, _watch),
        ...grid(_watch, 40, 20),
      ]);
      await flush();
      await flush();
      expect(leadingAtReady, isNull, reason: 'the lead change resyncs: no grid to check until the replay');
      expect(dataOn(r, _claim).expand((f) => f.payload), isEmpty);
      r.send(frame(LinkKind.data, _watch, utf8.encode('x')));
      await flush();
      await flush();
      expect(leadingAtReady, isTrue);
      expect(sent(r), '\r');
      r.send(frame(LinkKind.data, _watch, utf8.encode('y')));
      expect((await run).outcome, GateOutcome.done);
      expect(sent(r), '\r');
    });

    test('pasteStopsWithoutBracketedPaste', () async {
      final (s, r, vt) = await watched();
      await lead(s, r);
      r.send(frame(LinkKind.data, _watch, utf8.encode('x'))); // the replay after the lead's Resync
      await flush();
      final w = LeadWriter(() => s, () async => false);
      final gate = WriteGate(grids: s, grid: () => view(s), writer: () => w, remote: () => false, blocked: () => null);
      final res = await gate.run(1, (q) => q.send(GateStep(PasteWrite('one\ntwo'), ready: _any, done: _any)));
      expect((res.outcome, res.reason), (GateOutcome.mismatch, 'Claude is not accepting pastes'));
      expect(sent(r), '');
      expect(w.pasteSafe('one two'), isTrue);
      vt.modes.add(2004);
      expect(w.pasteSafe('one\ntwo'), isTrue);
    });

    test('leadWaitsForASnapshot', () async {
      final (s, r, _) = await watched();
      r.send([...frame(LinkKind.resync, _watch), ...grid(_watch, 100, 30)]);
      await flush();
      expect(s.replaying, isTrue);
      final w = LeadWriter(() => s, () async {
        final snap = s.snapshot!;
        return await s.takeOver(snap.cols, snap.rows) == null;
      });
      bool? led;
      w.lead().then((v) => led = v);
      await flush();
      expect([for (final o in opens(r)) if (o['claim'] == true) o], isEmpty);

      r.send(frame(LinkKind.data, _watch, utf8.encode('x')));
      await flush();
      expect(opens(r).last, containsPair('cols', 100));
      expect(opens(r).last, containsPair('rows', 30));
      expect(led, isNull);
      r.send([...json(LinkKind.opened, _claim, {'cols': 100, 'rows': 30}), ...json(LinkKind.lead, _claim, {'role': 'leader'})]);
      await flush();
      await flush();
      expect(led, isTrue);
    });

    test('leadFailsWhenTheLeadNeverComes', () => fakeAsync((a) {
          late TermSession s;
          late FakeRelay r;
          watched().then((v) => (s, r, _) = v);
          a.elapse(Duration.zero);
          bool? led;
          LeadWriter(() => s, () async => await s.takeOver(40, 20) == null).lead().then((v) => led = v);
          a.elapse(const Duration(seconds: 9));
          expect(led, isNull);
          a.elapse(const Duration(seconds: 1));
          expect(led, isFalse);
          expect(r.frames, isNotEmpty);
        }));
  });
}
