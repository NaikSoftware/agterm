import 'dart:io';

import 'package:elis_mobile/chat/chat_view.dart';
import 'package:elis_mobile/chat/feed.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

Grid _g(String name) => gridFromAnsi(File('test/fixtures/grid/$name.ansi').readAsStringSync());

class _Writer implements GateWriter {
  final writes = <GateWrite>[];
  @override
  Future<bool> lead() async => true;
  @override
  Future<bool> write(GateWrite w) async {
    writes.add(w);
    return true;
  }

  @override
  bool pasteSafe(String text) => true;
}

class _P {
  _P(this.t, this.g);

  final WidgetTester t;
  Grid? g;
  final grids = ValueNotifier(0);
  final writer = _Writer();
  late final gate = WriteGate(grids: grids, grid: () => g, writer: () => writer, remote: () => false, blocked: () => null);
  final feed = TranscriptFeed(call: (_) async => const {}, canPoll: () => false, remote: false)..loading = false;
  final keys = <(String?, VtKey?, int)>[];
  var gateRuns = 0;
  PromptCardBuilder? card;
  void Function(String?)? openPanel;

  Future<void> pump({bool exited = false, bool stale = false}) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    gate.addListener(() => gateRuns += gate.running ? 1 : 0);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ChatView(
            feed: feed,
            grid: () => g,
            grids: grids,
            gate: gate,
            s: Session({'id': 's1', 'name': 'One', 'cwd': '/work'}, 'w', 'W'),
            exited: exited,
            stale: stale,
            onTerm: () {},
            switcher: const SizedBox(),
            promptCard: (context, c) {
              openPanel = c.openPanel;
              return card?.call(context, c);
            },
            onKey: (seq, key, mods) => keys.add((seq, key, mods))),
      ),
    ));
  }

  Future<void> show(String name) async {
    g = _g(name);
    grids.value++;
    await t.pump();
  }

  bool get panel => find.byKey(const Key('panelSheet')).evaluate().isNotEmpty;
}

void main() {
  testWidgets('dialogOpensPanel', (t) async {
    final p = _P(t, _g('idle-placeholder-45'));
    await p.pump();
    await p.show('dialog-bash-45');
    expect(p.panel, isFalse);
    await p.show('dialog-bash-45');
    expect(p.panel, isTrue);
    expect(find.textContaining('Do you want to proceed?'), findsOneWidget);
    expect(find.byKey(const Key('answer-1')), findsOneWidget);
    expect(find.byKey(const Key('key-Escape')), findsOneWidget);
  });

  testWidgets('dialogOnOpenShowsAfterReread', (t) async {
    final p = _P(t, _g('dialog-bash-45'));
    await p.pump();
    expect(p.panel, isFalse);
    await t.pump(const Duration(milliseconds: 500));
    expect(p.panel, isTrue);
  });

  testWidgets('oneFrameDialogOpensNothing', (t) async {
    final p = _P(t, _g('idle-placeholder-45'));
    await p.pump();
    await p.show('dialog-bash-45');
    await p.show('idle-placeholder-45');
    await t.pump(const Duration(seconds: 1));
    expect(p.panel, isFalse);
  });

  testWidgets('noPanelWhileExitedOrStale', (t) async {
    for (final (exited, stale) in [(true, false), (false, true)]) {
      final p = _P(t, _g('dialog-bash-45'));
      await p.pump(exited: exited, stale: stale);
      await p.show('dialog-bash-45');
      await p.show('dialog-bash-45');
      await t.pump(const Duration(seconds: 1));
      expect(p.panel, isFalse);
    }
  });

  testWidgets('blankOrReplayingGridOpensNothing', (t) async {
    final p = _P(t, null);
    await p.pump();
    p.grids.value++;
    await t.pump();
    p.g = Grid([VtRow(const [])]);
    p.grids.value++;
    await t.pump(const Duration(seconds: 1));
    expect(p.panel, isFalse);
  });

  testWidgets('panelClosesWhenStackReturns', (t) async {
    final p = _P(t, _g('dialog-bash-45'));
    await p.pump();
    await p.show('dialog-bash-45');
    expect(p.panel, isTrue);
    await p.show('idle-placeholder-45');
    expect(p.panel, isFalse);
    expect(find.byKey(const Key('composerHeld')), findsNothing);
  });

  testWidgets('swipedPanelLeavesOpenHint', (t) async {
    final p = _P(t, _g('dialog-bash-45'));
    await p.pump();
    await p.show('dialog-bash-45');
    await t.drag(find.byKey(const Key('panelHandle')), const Offset(0, 200));
    await t.pump();
    expect(p.panel, isFalse);
    expect(find.textContaining('Claude shows a panel'), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('composer'))).enabled, isFalse);
    await p.show('dialog-bash-45');
    expect(p.panel, isFalse);
    await t.tap(find.byKey(const Key('panelOpen')));
    await t.pump();
    expect(p.panel, isTrue);
  });

  testWidgets('panelKeysBypassGate', (t) async {
    final p = _P(t, _g('dialog-bash-45'));
    await p.pump();
    await p.show('dialog-bash-45');
    await t.tap(find.byKey(const Key('key-Escape')));
    await t.pump();
    expect(p.keys, [('\x1b', VtKey.escape, 0)]);
    expect(p.writer.writes, isEmpty);
    expect(p.gateRuns, 0);
  });

  testWidgets('cardSlotDocksInsteadOfPanel', (t) async {
    final p = _P(t, _g('dialog-bash-45'))..card = (_, _) => const SizedBox(key: Key('stubCard'), height: 2000);
    await p.pump();
    await p.show('dialog-bash-45');
    expect(p.panel, isFalse);
    expect(find.byKey(const Key('stubCard')), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('promptCard'))).height, lessThanOrEqualTo(800 * 0.6));
    expect(find.text('Answer the prompt above'), findsOneWidget);
    expect(find.byKey(const Key('panelOpen')), findsNothing);
    expect(t.widget<TextField>(find.byKey(const Key('composer'))).enabled, isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('stoppedMessageUntilClose', (t) async {
    const stopped = 'Stopped at step 2 of 3: the options changed. The prompt may be half answered.';
    final p = _P(t, _g('dialog-bash-45'))..card = (_, _) => const SizedBox(key: Key('stubCard'), height: 40);
    await p.pump();
    await p.show('dialog-bash-45');
    p.openPanel!(stopped);
    await t.pump();
    expect(p.panel, isTrue);
    expect(find.text(stopped), findsOneWidget);
    await p.show('dialog-bash-45');
    expect(find.text(stopped), findsOneWidget);
    await p.show('idle-placeholder-45');
    expect(p.panel, isFalse);
    await p.show('dialog-bash-45');
    await p.show('dialog-bash-45');
    expect(find.text(stopped), findsNothing);
    expect(find.byKey(const Key('stubCard')), findsOneWidget);
  });
}
