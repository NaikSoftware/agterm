import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/feed.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/prompt_ledger.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

Grid _g(String name) => gridFromAnsi(File('test/fixtures/grid/$name.ansi').readAsStringSync());

final _pending = [
  for (final m in jsonDecode(File('test/fixtures/grid/card-bash.pending.json').readAsStringSync()) as List)
    PendingCall.fromJson(m as Map<String, dynamic>),
];
final _id = _pending.single.id;
const _closed = 'Closed on the computer';

class _Feed extends TranscriptFeed {
  _Feed() : super(call: (_) async => const {}, canPoll: () => false, remote: false);

  void set(List<PendingCall> p) {
    pending = p;
    notifyListeners();
  }

  void switched() {
    switches++;
    notifyListeners();
  }
}

class _L {
  _L() {
    feed.set(_pending);
    ledger = PromptLedger(grids: grids, grid: () => grid, feed: feed, blocked: () => blocked);
  }

  final grids = ValueNotifier(0);
  final feed = _Feed();
  Grid? grid;
  String? blocked;
  late final PromptLedger ledger;

  void show(Grid? g) {
    grid = g;
    grids.value++;
  }

  void idle(int n) {
    for (var i = 0; i < n; i++) {
      show(_g('idle-placeholder-45'));
    }
  }

  String? get mark => ledger.mark(_id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closedOnTheComputerAfterTwoGrids', () {
    final l = _L()..show(_g('card-bash-45'));
    l.ledger.shown(_id);
    l.show(_g('card-bash-45'));
    l.idle(1);
    expect(l.mark, isNull);
    l.idle(1);
    expect(l.mark, _closed);
  });

  test('answeredIsNeverClosed', () {
    final l = _L();
    l.ledger
      ..shown(_id)
      ..answered(_id);
    l.idle(3);
    expect(l.mark, isNull);
  });

  test('resultClearsMark', () {
    final l = _L();
    l.ledger.shown(_id);
    l.idle(2);
    expect(l.mark, _closed);
    l.feed.set(const []);
    expect(l.mark, isNull);
  });

  test('switchClearsAll', () {
    final l = _L();
    l.ledger
      ..shown(_id)
      ..stopped(_id);
    l.idle(2);
    expect(l.mark, _closed);
    l.feed.switched();
    expect(l.mark, isNull);
    expect(l.ledger.suppressed(_id), isFalse);
    l.idle(1);
    expect(l.mark, isNull); // the shown id went with the switch
  });

  test('resyncDoesNotClose', () {
    final l = _L();
    l.ledger.shown(_id);
    l
      ..show(null)
      ..show(null)
      ..show(Grid([VtRow(const [])]));
    expect(l.mark, isNull);
    l.idle(1);
    expect(l.mark, isNull);
  });

  test('exitClearsMark', () {
    final l = _L();
    l.ledger.shown(_id);
    l.idle(2);
    expect(l.mark, _closed);
    l.blocked = 'Claude exited';
    expect(l.mark, isNull);
    l.idle(3);
    expect(l.mark, isNull);
    l.blocked = null;
    expect(l.mark, isNull); // cleared, not hidden
    l.idle(2);
    expect(l.mark, _closed);
  });

  test('stoppedSuppressesUntilStack', () {
    final l = _L()..show(_g('card-bash-45'));
    l.ledger
      ..shown(_id)
      ..stopped(_id);
    expect(l.ledger.suppressed(_id), isTrue);
    l.show(_g('card-bash-45'));
    expect(l.ledger.suppressed(_id), isTrue);
    l.show(_g('idle-placeholder-45'));
    expect(l.ledger.suppressed(_id), isFalse);
  });

  test('anchoredGridResetsTheCount', () {
    final l = _L();
    l.ledger.shown(_id);
    l
      ..idle(1)
      ..show(_g('card-bash-45'))
      ..idle(1);
    expect(l.mark, isNull);
  });
}
