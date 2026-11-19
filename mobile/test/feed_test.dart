import 'dart:async';

import 'package:elis_mobile/chat/feed.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Host {
  final calls = <(Map<String, dynamic>, Completer<Map<String, dynamic>>)>[];
  bool canPoll = true;

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) {
    final c = Completer<Map<String, dynamic>>();
    calls.add((args, c));
    return c.future;
  }

  Map<String, dynamic> get last => calls.last.$1;

  void reply(Map<String, dynamic> r, [int? i]) => calls[i ?? calls.length - 1].$2.complete(r);

  void fail(String message) => calls.last.$2.completeError(ElisError(message));
}

Map<String, dynamic> _item(String uuid, {String kind = 'text', Map<String, dynamic> extra = const {}}) =>
    {'kind': kind, 'uuid': uuid, 'at': 0, ...extra};

Map<String, dynamic> _page(List<Map<String, dynamic>> items,
        {String transcript = 't1', int start = 100, int next = 200, int? size, bool reset = false, List<Map<String, dynamic>>? commands}) =>
    {
      'transcript': transcript,
      'size': size ?? next,
      'start': start,
      'next': next,
      if (reset) 'reset': true,
      'items': items,
      'meta': {'title': 'T'},
      'commands': ?commands,
    };

(TranscriptFeed, _Host) _started(FakeAsync a, {bool remote = false}) {
  final h = _Host();
  final f = TranscriptFeed(call: h.call, canPoll: () => h.canPoll, remote: remote)..start();
  a.flushMicrotasks();
  return (f, h);
}

void _firstReply(FakeAsync a, _Host h) {
  h.reply(_page([_item('a'), _item('b')]));
  a.flushMicrotasks();
}

void main() {
  test('firstReadIsTheTailWithoutCursor', () => fakeAsync((a) {
        final (f, h) = _started(a);
        expect(f.loading, isTrue);
        expect(h.calls, hasLength(1));
        expect(h.last.keys, isNot(anyOf(contains('after'), contains('before'), contains('transcript'))));
        h.reply(_page([_item('a'), _item('b')], commands: [{'name': 'clear', 'description': 'd', 'source': 'builtin'}]));
        a.flushMicrotasks();
        expect(f.items.map((i) => i.uuid), ['a', 'b']);
        expect(f.meta!.title, 'T');
        expect(f.commands.single.name, 'clear');
        expect(f.transcript, 't1');
        expect(f.loading, isFalse);
        expect(f.fresh, isEmpty);
        f.dispose();
      }));

  test('noPollWhileCanPollIsFalse', () => fakeAsync((a) {
        final h = _Host()..canPoll = false;
        final f = TranscriptFeed(call: h.call, canPoll: () => h.canPoll, remote: false)..start();
        a.elapse(const Duration(seconds: 5));
        expect(h.calls, isEmpty);
        f.dispose();
      }));

  test('tailPollsAfterNext', () => fakeAsync((a) {
        final (f, h) = _started(a);
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 699));
        expect(h.calls, hasLength(1));
        a.elapse(const Duration(milliseconds: 1));
        expect(h.calls, hasLength(2));
        expect(h.last['after'], '200');
        expect(h.last['transcript'], 't1');
        h.reply(_page([_item('c')], start: 200, next: 260));
        a.flushMicrotasks();
        expect(f.items.map((i) => i.uuid), ['a', 'b', 'c']);
        expect(f.fresh, {'c'});
        a.elapse(const Duration(milliseconds: 700));
        expect(h.last['after'], '260');
        f.dispose();
      }));

  test('upsertReplacesInPlace', () => fakeAsync((a) {
        final (f, h) = _started(a);
        h.reply(_page([_item('a', kind: 'tool', extra: {'running': true}), _item('b')]));
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 700));
        h.reply(_page([_item('a', kind: 'tool', extra: {'mark': 'ok'})], start: 200, next: 260));
        a.flushMicrotasks();
        expect(f.items.map((i) => i.uuid), ['a', 'b']);
        expect(f.items.first.running, isFalse);
        expect(f.items.first.mark, 'ok');
        expect(f.fresh, isEmpty);
        f.dispose();
      }));

  test('nextBelowSizePollsAgainAtOnce', () => fakeAsync((a) {
        final (f, h) = _started(a);
        h.reply(_page([_item('a')], next: 200, size: 500));
        a.flushMicrotasks();
        expect(h.calls, hasLength(2));
        expect(h.last['after'], '200');
        f.dispose();
      }));

  test('remotePollsEvery2s', () => fakeAsync((a) {
        final (f, h) = _started(a, remote: true);
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 700));
        expect(h.calls, hasLength(1));
        a.elapse(const Duration(milliseconds: 1300));
        expect(h.calls, hasLength(2));
        f.dispose();
      }));

  test('resetDropsAndReloadsTail', () => fakeAsync((a) {
        final (f, h) = _started(a);
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 700));
        h.reply(_page([_item('x')], reset: true));
        a.flushMicrotasks();
        expect(f.items, isEmpty);
        expect(f.switches, 1);
        expect(h.calls, hasLength(3));
        expect(h.last.keys, isNot(anyOf(contains('after'), contains('transcript'))));
        h.reply(_page([_item('x'), _item('y')]));
        a.flushMicrotasks();
        expect(f.items.map((i) => i.uuid), ['x', 'y']);
        f.dispose();
      }));

  test('otherTranscriptIdSwitches', () => fakeAsync((a) {
        final (f, h) = _started(a);
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 700));
        h.reply(_page([_item('n')], transcript: 't2'));
        a.flushMicrotasks();
        expect(f.items, isEmpty);
        expect(f.switches, 1);
        expect(h.last.keys, isNot(anyOf(contains('after'), contains('transcript'))));
        h.reply(_page([_item('n')], transcript: 't2'));
        a.flushMicrotasks();
        expect(f.transcript, 't2');
        expect(f.items.map((i) => i.uuid), ['n']);
        f.dispose();
      }));

  test('loadEarlierPrependsAndPagesBack', () => fakeAsync((a) {
        final (f, h) = _started(a);
        _firstReply(a, h);
        expect(f.atStart, isFalse);
        unawaited(f.loadEarlier());
        expect(f.loadingEarlier, isTrue);
        expect(h.last['before'], '100');
        expect(h.last['transcript'], 't1');
        h.reply(_page([_item('o')], start: 0, next: 100, size: 200));
        a.flushMicrotasks();
        expect(f.items.map((i) => i.uuid), ['o', 'a', 'b']);
        expect(f.loadingEarlier, isFalse);
        expect(f.atStart, isTrue);
        expect(f.fresh, isEmpty);
        f.dispose();
      }));

  test('staleBeforeReplyIsDropped', () => fakeAsync((a) {
        final (f, h) = _started(a);
        _firstReply(a, h);
        unawaited(f.loadEarlier());
        final before = h.calls.length - 1;
        a.elapse(const Duration(milliseconds: 700));
        h.reply(_page([], reset: true));
        a.flushMicrotasks();
        h.reply(_page([_item('x')]));
        a.flushMicrotasks();
        h.reply(_page([_item('old')], start: 0, next: 100), before);
        a.flushMicrotasks();
        expect(f.items.map((i) => i.uuid), ['x']);
        expect(f.loadingEarlier, isFalse);
        expect(f.atStart, isFalse);
        f.dispose();
      }));

  test('oneCallInFlight', () => fakeAsync((a) {
        final (f, h) = _started(a);
        a.elapse(const Duration(seconds: 3));
        unawaited(f.pollNow());
        expect(h.calls, hasLength(1));
        _firstReply(a, h);
        unawaited(f.pollNow());
        expect(h.calls, hasLength(2));
        f.dispose();
      }));

  test('staleAfterTwoIntervalsWithoutReply', () => fakeAsync((a) {
        final (f, h) = _started(a);
        a.elapse(const Duration(seconds: 3));
        expect(f.stale, isFalse);
        expect(f.loading, isTrue);
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 1399));
        expect(f.stale, isFalse);
        a.elapse(const Duration(milliseconds: 1));
        expect(f.stale, isTrue);
        h.reply(_page([], start: 200, next: 200));
        a.flushMicrotasks();
        expect(f.stale, isFalse);
        f.dispose();
      }));

  test('remoteStaleAfter4s', () => fakeAsync((a) {
        final (f, h) = _started(a, remote: true);
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 3999));
        expect(f.stale, isFalse);
        a.elapse(const Duration(milliseconds: 1));
        expect(f.stale, isTrue);
        f.dispose();
      }));

  test('noStaleWhileNotPolling', () => fakeAsync((a) {
        final (f, h) = _started(a);
        _firstReply(a, h);
        h.canPoll = false;
        a.elapse(const Duration(seconds: 3));
        expect(f.stale, isFalse);
        h.canPoll = true;
        a.elapse(const Duration(milliseconds: 500));
        expect(h.calls, hasLength(2));
        expect(f.stale, isFalse);
        a.elapse(const Duration(milliseconds: 1399));
        expect(f.stale, isFalse);
        a.elapse(const Duration(milliseconds: 1));
        expect(f.stale, isTrue);
        f.dispose();
      }));

  test('hostTooOldStopsPolling', () => fakeAsync((a) {
        final (f, h) = _started(a);
        h.fail("unknown command 'session.transcript'");
        a.flushMicrotasks();
        expect(f.error, TranscriptError.hostTooOld);
        expect(f.loading, isFalse);
        a.elapse(const Duration(seconds: 5));
        expect(h.calls, hasLength(1));
        expect(f.stale, isFalse);
        f.retry();
        a.flushMicrotasks();
        expect(f.error, isNull);
        expect(h.calls, hasLength(2));
        expect(h.last.keys, isNot(contains('after')));
        _firstReply(a, h);
        a.elapse(const Duration(milliseconds: 700));
        expect(h.calls, hasLength(3));
        f.dispose();
      }));

  test('notFoundKeepsPolling', () => fakeAsync((a) {
        final (f, h) = _started(a);
        h.fail('transcript not found');
        a.flushMicrotasks();
        expect(f.error, TranscriptError.notFound);
        a.elapse(const Duration(milliseconds: 700));
        expect(h.calls, hasLength(2));
        _firstReply(a, h);
        expect(f.error, isNull);
        f.dispose();
      }));
}
