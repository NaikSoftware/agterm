import 'dart:io';

import 'package:elis_mobile/chat/chat_composer.dart';
import 'package:elis_mobile/chat/checks.dart';
import 'package:elis_mobile/chat/claude_screen.dart';
import 'package:elis_mobile/chat/feed.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

Grid _g(String name) => gridFromAnsi(File('test/fixtures/grid/$name.ansi').readAsStringSync());

VtRow _row(String text) => VtRow([for (final r in text.runes) VtCell(String.fromCharCode(r))]);

/// [g] with Claude's input showing [text] on its first row and no further input rows.
Grid _withInput(Grid g, String text) {
  final (a, b) = ClaudeScreen.read(g).inputRows!;
  final rows = [...g.rows]..replaceRange(a, b, [_row('❯ $text')]);
  return Grid([for (var n = 0; n < b - a - 1; n++) VtRow(const []), ...rows]);
}

/// One Ctrl+U as check 5 saw it: the last input row loses its text, then the row itself.
Grid _ctrlU(Grid g) {
  final (a, b) = ClaudeScreen.read(g).inputRows!;
  final rows = [...g.rows];
  final last = b - 1;
  if (last > a && g.text(last).trim().isEmpty) {
    rows.removeAt(last);
    rows.insert(0, VtRow(const []));
  } else {
    rows[last] = _row(last == a ? '❯ ' : '');
  }
  return Grid(rows);
}

class _Grids extends ChangeNotifier {
  _Grids(this.g);
  Grid g;
  void set(Grid n) {
    g = n;
    notifyListeners();
  }
}

class _Writer implements GateWriter {
  _Writer(this.onWrite);
  final void Function(GateWrite w) onWrite;
  final writes = <GateWrite>[];
  VoidCallback? onLead;
  @override
  Future<bool> lead() async {
    onLead?.call();
    return true;
  }

  @override
  Future<bool> write(GateWrite w) async {
    writes.add(w);
    onWrite(w);
    return true;
  }

  @override
  bool pasteSafe(String text) => true;
}

class _C {
  _C(this.t, Grid g) : grids = _Grids(g);

  final WidgetTester t;
  final _Grids grids;
  late final writer = _Writer((w) => onWrite?.call(w));
  GateWriter? typeWriter;
  void Function(GateWrite w)? onWrite;
  final feed = TranscriptFeed(call: (_) async => const {}, canPoll: () => false, remote: false)..loading = false;
  late final gate = WriteGate(
      grids: grids, grid: () => grids.g, writer: () => typeWriter ?? writer, remote: () => false, blocked: () => null);
  bool remote = false, server = false;
  Checks checks = _proven;
  String? disabledBy;

  /// Scripts the grid's answer to each write, a microtask after it.
  void script(Grid? Function(GateWrite w) next) =>
      onWrite = (w) => Future.microtask(() => next(w)).then((g) => g == null ? null : grids.set(g));

  Future<void> pump() => t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: grids,
            builder: (context, _) => Column(children: [
              const Spacer(),
              ChatComposer(
                  feed: feed,
                  screen: () => ClaudeScreen.read(grids.g),
                  colours: grids.g.colours,
                  remote: remote,
                  server: server,
                  gate: gate,
                  disabledBy: disabledBy,
                  checks: checks),
            ]),
          ),
        ),
      ));

  String get field => t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text;
  bool get sendEnabled => t.widget<FilledButton>(find.byKey(const Key('send'))).onPressed != null;
  String? get sendLabel =>
      t.widget<Icon>(find.descendant(of: find.byKey(const Key('send')), matching: find.byType(Icon))).semanticLabel;

  Future<void> type(String text) async {
    await t.enterText(find.byKey(const Key('composer')), text);
    await t.pump();
  }

  Future<void> send() async {
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(seconds: 3));
    await t.pump();
  }

  Iterable<KeyWrite> get keys => writer.writes.whereType<KeyWrite>();
}

const _proven =
    Checks(keys: true, paste: true, pastedCommandRuns: true, pastedBangSwitches: true, clearInput: (VtKey.u, vtCtrl));
const _three = 'alpha line one\nbeta line two\ngamma line three';

bool _enter(GateWrite w) => w is KeyWrite && w.key == VtKey.enter;
bool _ctrlUWrite(GateWrite w) => w is KeyWrite && w.key == VtKey.u && w.mods == vtCtrl;

void main() {
  testWidgets('adoptsTypedDraftNotPlaceholder', (t) async {
    final c = _C(t, _g('idle-draft-45'));
    await c.pump();
    expect(c.field, 'hello there');
    await t.pumpWidget(const SizedBox());
    final p = _C(t, _g('idle-placeholder-45'));
    await p.pump();
    expect(p.field, '');
  });

  testWidgets('adoptsAtALaterFirstGrid', (t) async {
    final c = _C(t, Grid(const []));
    await c.pump();
    expect(c.field, '');
    c.grids.set(_g('idle-draft-45'));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(c.field, 'hello there');
  });

  testWidgets('aDialogBeforeThePasteIsNoChangedDraft', (t) async {
    final c = _C(t, _g('idle-placeholder-45'));
    c.writer.onLead = () => c.grids.g = _g('dialog-bash-45');
    await c.pump();
    await c.type('hi');
    await c.send();
    expect(c.writer.writes, isEmpty);
    expect(find.text("Claude's input changed on the computer"), findsNothing);
    expect(find.text("Claude's screen is not as expected"), findsOneWidget);
  });

  testWidgets('textTypedDuringTheRunStays', (t) async {
    final idle = _g('idle-placeholder-45');
    final c = _C(t, idle);
    var typed = false;
    c.script((w) => _enter(w) ? idle : _withInput(idle, 'hi'));
    c.writer.onLead = () {
      if (typed) return;
      typed = true;
      t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text = 'hi and more';
    };
    await c.pump();
    await c.type('hi');
    await c.send();
    expect(c.writer.writes.length, 2);
    expect(c.field, 'hi and more');
  });

  testWidgets('noAdoptionWithoutColours', (t) async {
    final c = _C(t, Grid(_g('idle-draft-45').rows, colours: false));
    await c.pump();
    expect(c.field, '');
  });

  testWidgets('noAdoptionOfAPastePlaceholder', (t) async {
    final c = _C(t, _g('paste-placeholder-45'));
    await c.pump();
    expect(c.field, '');
    await c.type('mine');
    await c.send();
    expect(c.writer.writes, isEmpty);
    expect(find.text("Claude's input changed on the computer"), findsOneWidget);
  });

  testWidgets('readoptsAfterStop', (t) async {
    final c = _C(t, _g('working-45'));
    await c.pump();
    expect(c.field, '');
    // a turn that ends on its own with a draft in the row is not adopted
    c.grids.set(_withInput(_g('idle-placeholder-45'), 'typed on the Mac'));
    await t.pump();
    expect(c.field, '');
    c.grids.set(_g('working-45'));
    await t.pump();
    c.script((_) => _g('idle-draft-45'));
    final r = c.gate.run(1, (q) => q.send(GateStep(KeyWrite(VtKey.escape), ready: (_) => true, done: (g) => !ClaudeScreen.read(g).busy)));
    await t.pump(const Duration(seconds: 1));
    expect((await r).ok, isTrue);
    await t.pump();
    expect(c.field, 'hello there');
  });

  testWidgets('sendPastesThenEnters', (t) async {
    final idle = _g('idle-placeholder-45');
    final c = _C(t, idle);
    c.script((w) => _enter(w) ? idle : _g('paste-inline-45'));
    await c.pump();
    await c.type('$_three \n');
    await c.send();
    expect(c.writer.writes.length, 2);
    expect((c.writer.writes[0] as PasteWrite).text, _three);
    expect(_enter(c.writer.writes[1]), isTrue);
    expect(c.field, '');
  });

  testWidgets('enterWaitsForThePaste', (t) async {
    final c = _C(t, _g('idle-placeholder-45'));
    await c.pump();
    await c.type(_three);
    await c.send();
    expect(c.writer.writes.single, isA<PasteWrite>());
    expect(c.field, _three);
    expect(find.text("Claude's screen did not change"), findsOneWidget);
  });

  test('pasteShownAcceptsInlineAndPlaceholder', () {
    expect(pasteShown(ClaudeScreen.read(_g('paste-inline-45')), _three), isTrue);
    expect(pasteShown(ClaudeScreen.read(_g('paste-placeholder-45')), 'five\nlines\nof\npasted\ntext'), isTrue);
    expect(pasteShown(ClaudeScreen.read(_g('idle-placeholder-45')), _three), isFalse);
  });

  test('pasteShownIgnoresTheDimPlaceholder', () {
    final s = ClaudeScreen.read(_g('idle-placeholder-45'));
    expect(s.input, isNotEmpty);
    expect(pasteShown(s, s.input!), isFalse);
  });

  testWidgets('sendClearsAdoptedDraftFirst', (t) async {
    final c = _C(t, _g('idle-draft-wrapped-45'));
    final drafts = <String>[];
    c.onWrite = (w) {
      drafts.add(ClaudeScreen.read(c.grids.g).draft);
      Future.microtask(() => c.grids.set(_ctrlUWrite(w)
          ? _ctrlU(c.grids.g)
          : _enter(w)
              ? _g('idle-placeholder-45')
              : _g('paste-inline-45')));
    };
    await c.pump();
    expect(norm(c.field), norm('first line\nthe middle line is long enough to wrap here ok\nthird line'));
    await c.type(_three);
    await t.tap(find.byKey(const Key('send')));
    for (var n = 0; n < 20; n++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    final w = c.writer.writes;
    final paste = w.indexWhere((w) => w is PasteWrite);
    expect(paste, greaterThanOrEqualTo(5));
    expect(w.take(paste).every(_ctrlUWrite), isTrue);
    expect(drafts[paste], '');
    expect(_enter(w.last), isTrue);
    expect(c.gate.total, paste + 2);
    expect(c.field, '');
  });

  testWidgets('clearStopsWhenTheInputDoesNotChange', (t) async {
    final c = _C(t, _g('idle-draft-45'));
    await c.pump();
    await c.type('something else');
    await c.send();
    expect(c.writer.writes.length, 1);
    expect(_ctrlUWrite(c.writer.writes.single), isTrue);
    expect(find.text("Claude's screen did not change"), findsOneWidget);
    expect(c.field, 'something else');
  });

  testWidgets('changedDraftOffersReplaceKeep', (t) async {
    final idle = _g('idle-placeholder-45');
    final c = _C(t, idle);
    await c.pump();
    c.grids.set(_g('idle-draft-45')); // typed on the computer after Chat opened
    await t.pump();
    expect(c.field, '');
    await c.type('hi');
    await c.send();
    expect(c.writer.writes, isEmpty);
    expect(find.text("Claude's input changed on the computer"), findsOneWidget);
    await t.tap(find.text('Keep'));
    await t.pump();
    expect(find.text("Claude's input changed on the computer"), findsNothing);
    expect(c.writer.writes, isEmpty);
    expect(c.field, 'hi');

    await c.send();
    c.script((w) => _ctrlUWrite(w) ? idle : _enter(w) ? idle : _withInput(idle, 'hi'));
    await t.tap(find.text('Replace'));
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    final w = c.writer.writes;
    expect(_ctrlUWrite(w[0]), isTrue);
    expect((w[1] as PasteWrite).text, 'hi');
    expect(_enter(w[2]), isTrue);
    expect(c.field, '');
  });

  testWidgets('queueLabelWhileWorking', (t) async {
    final c = _C(t, _g('working-45'));
    await c.pump();
    await c.type('next');
    expect(c.sendLabel, 'Queue');
    expect(c.sendEnabled, isTrue);
    await c.type('/model');
    expect(c.sendLabel, 'Send');
    c.grids.set(_g('idle-placeholder-45'));
    await c.type('next');
    expect(c.sendLabel, 'Send');
  });

  testWidgets('disabledReasonOnDialog', (t) async {
    final c = _C(t, _g('dialog-bash-45'));
    await c.pump();
    expect(find.text('Claude shows a dialog'), findsNothing); // no text, no reason
    await c.type('x');
    expect(c.sendEnabled, isFalse);
    expect(find.text('Claude shows a dialog'), findsOneWidget);
    c.grids.set(Grid(const []));
    await t.pump();
    expect(find.text("Waiting for Claude's screen"), findsOneWidget);
    c.disabledBy = 'Claude exited';
    c.grids.set(_g('dialog-bash-45'));
    await c.pump();
    expect(find.text('Claude exited'), findsOneWidget);
    expect(find.text('Claude shows a dialog'), findsNothing);
  });

  test('slashMatchesPrefixFirst', () {
    final all = [for (final n in ['discover', 'cost', 'Config', 'help', 'compact']) SlashCommand(n, '', false, false)];
    expect([for (final c in slashMatches(all, '/co')) c.name], ['cost', 'Config', 'compact', 'discover']);
    expect([for (final c in slashMatches(all, '/')) c.name], ['discover', 'cost', 'Config', 'help', 'compact']);
  });

  testWidgets('slashMenuFiltersAndInserts', (t) async {
    final c = _C(t, _g('idle-placeholder-45'));
    c.feed.commands = [
      SlashCommand('help', 'Show help', false, false),
      SlashCommand('cost', 'Show the cost', false, false),
      SlashCommand('compact', 'Compact the context', false, false),
    ];
    await c.pump();
    await c.type('/co');
    expect(find.text('/cost'), findsOneWidget);
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/help'), findsNothing);
    await t.tap(find.text('/cost'));
    await t.pump();
    expect(c.field, '/cost ');
    expect(find.text('/compact'), findsNothing);
    await c.type('co');
    expect(find.text('/cost'), findsNothing); // only a leading `/` opens it
  });

  testWidgets('menuPickSendsExactName', (t) async {
    final idle = _g('idle-placeholder-45');
    final c = _C(t, idle);
    c.feed.commands = [SlashCommand('cost', '', false, false), SlashCommand('compact', '', false, false)];
    c.script((w) => _enter(w) ? idle : _withInput(idle, '/cost'));
    await c.pump();
    await c.type('/cos');
    await t.tap(find.text('/cost'));
    await t.pump();
    await c.send();
    expect((c.writer.writes.first as PasteWrite).text, '/cost');
    expect(_enter(c.writer.writes.last), isTrue);
  });

  testWidgets('panelCommandsMarked', (t) async {
    final c = _C(t, _g('idle-placeholder-45'));
    c.feed.commands = [SlashCommand('model', 'Set the model', false, true), SlashCommand('memory', 'Edit memory', false, false)];
    await c.pump();
    await c.type('/m');
    expect(find.text('opens in panel'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('slash-model')), matching: find.text('opens in panel')), findsOneWidget);
  });

  testWidgets('nonLivePaneDoesNotQueue', (t) async {
    final working = _g('working-45');
    final c = _C(t, Grid.text([for (var r = 0; r < working.rows.length; r++) working.text(r)].join('\n')));
    await c.pump();
    await c.type('next');
    expect(c.sendEnabled, isFalse);
    expect(find.text('Claude is working: this pane sends only while Claude is idle'), findsOneWidget);
  });

  testWidgets('nonLiveSendTypesTextThenEnter', (t) async {
    final colour = _g('idle-placeholder-45');
    final screen = [for (var r = 0; r < colour.rows.length; r++) colour.text(r)].join('\n');
    expect(screen, contains('❯ Try "'));
    final c = _C(t, Grid.text(screen));
    final typed = <String>[];
    c.typeWriter = TypeWriter((text) async {
      typed.add(text);
      Future.microtask(() => c.grids.set(Grid.text(text == '\r' ? screen : screen.replaceFirst(RegExp(r'Try ".*"'), text))));
      return null;
    });
    await c.pump();
    expect(c.field, '');
    await c.type('hello');
    expect(c.sendEnabled, isTrue);
    await c.send();
    expect(typed, ['hello', '\r']);
    expect(c.field, '');
  });

  testWidgets('leadingSlashTypedWhenPasteFails', (t) async {
    final idle = _g('idle-placeholder-45');
    final c = _C(t, idle)..checks = const Checks(keys: true, paste: true);
    c.script((w) => _enter(w) ? idle : _withInput(idle, '/effort low'));
    await c.pump();
    await c.type('/effort low');
    await c.send();
    expect((c.writer.writes.first as TextWrite).text, '/effort low');
    expect(c.writer.writes.whereType<PasteWrite>(), isEmpty);
    expect(_enter(c.writer.writes.last), isTrue);
  });

  testWidgets('remoteRowWritesBlockedUntilProven', (t) async {
    final c = _C(t, _g('idle-placeholder-45'))..remote = true;
    await c.pump();
    await c.type('hi');
    expect(c.sendEnabled, isFalse);
    expect(find.text('Sending from the phone is not verified on remote sessions yet'), findsOneWidget);
    c.checks = const Checks(
        keys: true, paste: true, pastedCommandRuns: true, pastedBangSwitches: true, clearInput: (VtKey.u, vtCtrl), attached: true);
    await c.pump();
    expect(c.sendEnabled, isTrue);
  });

  testWidgets('serverRowSendsWithServerChecksOnly', (t) async {
    final c = _C(t, _g('idle-placeholder-45'))
      ..remote = true
      ..server = true
      ..checks = const Checks(
          keys: true, paste: true, pastedCommandRuns: true, pastedBangSwitches: true, clearInput: (VtKey.u, vtCtrl), server: true);
    await c.pump();
    await c.type('hi');
    expect(c.sendEnabled, isTrue);
    c.server = false; // a row attached from another Mac
    await c.pump();
    expect(c.sendEnabled, isFalse);
    expect(find.text('Sending from the phone is not verified on remote sessions yet'), findsOneWidget);
  });

  testWidgets('sendDisabledWhileUnproven', (t) async {
    final c = _C(t, _g('idle-placeholder-45'))..checks = const Checks();
    await c.pump();
    await c.type('hi');
    expect(c.sendEnabled, isFalse);
    expect(find.text('Sending from the phone is not verified yet'), findsOneWidget);
  });

  group('mode chip', () {
    bool chipEnabled(WidgetTester t) => t.widget<ActionChip>(find.byKey(const Key('mode-chip'))).onPressed != null;
    bool shiftTab(GateWrite w) => w is KeyWrite && w.key == VtKey.tab && w.mods == vtShift;

    testWidgets('chipCyclesToTarget', (t) async {
      final c = _C(t, _g('idle-placeholder-45'));
      final next = [_g('mode-accept-45'), _g('mode-plan-45'), _g('mode-auto-45')];
      c.script((w) => shiftTab(w) ? next.removeAt(0) : null);
      await c.pump();
      expect(chipEnabled(t), isTrue);
      await t.tap(find.byKey(const Key('mode-chip')));
      await t.pumpAndSettle();
      await t.tap(find.text('auto mode on'));
      await t.pumpAndSettle();
      expect(c.writer.writes, isEmpty);
      expect(find.text('Tap again to switch'), findsOneWidget);
      await t.tap(find.text('auto mode on'));
      await t.pumpAndSettle();
      expect(c.writer.writes.length, 3);
      expect(c.writer.writes.every(shiftTab), isTrue);
      expect(ClaudeScreen.read(c.grids.g).mode, ClaudeMode.auto);
    });

    testWidgets('chipStopsWhenModeUnchanged', (t) async {
      final c = _C(t, _g('idle-placeholder-45'));
      c.script((_) => null);
      await c.pump();
      await t.tap(find.byKey(const Key('mode-chip')));
      await t.pumpAndSettle();
      await t.tap(find.text('plan mode on'));
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      await t.pump();
      expect(c.writer.writes.length, 1);
      expect(find.text("Claude's screen did not change"), findsOneWidget);
    });

    testWidgets('chipStopsWhenTheStartModeReturns', (t) async {
      final c = _C(t, _g('idle-placeholder-45'));
      final next = [_g('mode-accept-45'), _g('idle-placeholder-45')];
      c.script((w) => next.isEmpty ? null : next.removeAt(0));
      await c.pump();
      await t.tap(find.byKey(const Key('mode-chip')));
      await t.pumpAndSettle();
      await t.tap(find.text('plan mode on'));
      await t.pumpAndSettle();
      expect(c.writer.writes.length, 2);
      expect(find.text('Claude did not reach plan mode on'), findsOneWidget);
    });

    testWidgets('chipDisabledWhileWorking', (t) async {
      final c = _C(t, _g('working-45'));
      await c.pump();
      expect(chipEnabled(t), isFalse);
    });

    testWidgets('chipDisabledWithoutAKnownMode', (t) async {
      final g = _g('idle-placeholder-45');
      final r = g.rows.lastIndexWhere((row) => row.text.contains('manual mode on'));
      g.rows[r] = _row('  ⏸ ручний режим');
      final c = _C(t, g);
      await c.pump();
      expect(chipEnabled(t), isFalse);
    });

    testWidgets('chipDisabledOnAnUnprovenRemoteRow', (t) async {
      final c = _C(t, _g('idle-placeholder-45'))..remote = true;
      await c.pump();
      expect(chipEnabled(t), isFalse);
      c.checks = const Checks(keys: true, paste: true, attached: true);
      await c.pump();
      expect(chipEnabled(t), isTrue);
    });

    testWidgets('chipEnabledOnAServerRowOnly', (t) async {
      final c = _C(t, _g('idle-placeholder-45'))
        ..remote = true
        ..server = true
        ..checks = const Checks(keys: true, paste: true, server: true);
      await c.pump();
      expect(chipEnabled(t), isTrue);
      c.server = false;
      await c.pump();
      expect(chipEnabled(t), isFalse);
    });

    testWidgets('chipShowsTheTranscriptModeWhileHidden', (t) async {
      final c = _C(t, _g('dialog-bash-45'));
      c.feed.meta = TranscriptMeta.fromJson(const {'permissionMode': 'plan'});
      await c.pump();
      expect(find.text('plan'), findsOneWidget);
      expect(chipEnabled(t), isFalse);
    });

    testWidgets('shellBadge', (t) async {
      final c = _C(t, _g('shell-45'));
      await c.pump();
      expect(find.text('1 shell'), findsOneWidget);
      c.grids.set(_g('idle-placeholder-45'));
      await t.pump();
      expect(find.text('1 shell'), findsNothing);
    });
  });
}
