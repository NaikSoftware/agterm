import 'package:elis_mobile/terminal/term_keyboard.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Sink {
  final keys = <(VtKey, int)>[];
  final texts = <String>[];
  final pastes = <String>[];
  final focus = FocusNode();
  var screen = ''; // the program's input line as Backspace and text leave it

  void key(VtKey k, int m) {
    keys.add((k, m));
    if (k == VtKey.backspace && m == 0 && screen.isNotEmpty) screen = String.fromCharCodes(screen.runes.toList()..removeLast());
  }

  void text(String t) {
    texts.add(t);
    screen += t;
  }
}

Future<_Sink> _open(WidgetTester t) async {
  final s = _Sink();
  addTearDown(s.focus.dispose);
  await t.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: TermKeyboard(focus: s.focus, onKey: s.key, onText: s.text, onPaste: s.pastes.add),
    ),
  ));
  s.focus.requestFocus();
  await t.pump();
  expect(t.testTextInput.hasAnyClients, isTrue);
  return s;
}

/// One edit as the IME reports it: [old] is the IME's own text before it, which can predate the field's last reset.
Map<String, Object> _d(String old, int start, int end, String text, {TextRange composing = TextRange.empty}) {
  final caret = start + text.length;
  return {
    'oldText': old,
    'deltaText': text,
    'deltaStart': start,
    'deltaEnd': end,
    'selectionBase': caret,
    'selectionExtent': caret,
    'composingBase': composing.start,
    'composingExtent': composing.end,
  };
}

/// Deltas delivered in one message, before any reset reaches the IME.
Future<void> _deltas(WidgetTester t, List<Map<String, Object>> deltas) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        -1,
        {'deltas': deltas},
      ])),
      (_) {});
  await t.pump();
}

void main() {
  testWidgets('aLetterIsText', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 'a')]);
    expect(s.texts, ['a']);
    expect(s.keys, isEmpty);
    expect(t.testTextInput.editingState!['text'], '  ');
  });

  testWidgets('backspaceIsAKey', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 1, 2, '')]);
    expect(s.keys, [(VtKey.backspace, 0)]);
    await _deltas(t, [_d('  ', 0, 2, '')]);
    expect(s.keys, List.filled(3, (VtKey.backspace, 0)));
    expect(s.texts, isEmpty);
  });

  testWidgets('backspaceRepeats', (t) async {
    final s = await _open(t);
    for (var i = 0; i < 3; i++) {
      await _deltas(t, [_d('  ', 1, 2, '')]);
    }
    expect(s.keys, List.filled(3, (VtKey.backspace, 0)));
  });

  testWidgets('enterActionIsAKeyAndKeepsFocus', (t) async {
    final s = await _open(t);
    for (final a in [TextInputAction.none, TextInputAction.newline, TextInputAction.done, TextInputAction.go, TextInputAction.send]) {
      await t.testTextInput.receiveAction(a);
      await t.pump();
    }
    expect(s.keys, List.filled(5, (VtKey.enter, 0)));
    expect(s.focus.hasFocus, isTrue);
    await _deltas(t, [_d('  ', 2, 2, '\n')]);
    expect(s.keys, List.filled(6, (VtKey.enter, 0)));
    expect(s.pastes, isEmpty);
  });

  testWidgets('ukrainianCommitIsText', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 'привіт')]);
    expect(s.texts, ['привіт']);
  });

  testWidgets('composingSendsOnlyAtItsEnd', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 'п', composing: const TextRange(start: 2, end: 3))]);
    await _deltas(t, [_d('  п', 2, 3, 'при', composing: const TextRange(start: 2, end: 5))]);
    expect(s.texts, isEmpty);
    await _deltas(t, [_d('  при', 2, 5, 'привіт')]);
    expect(s.texts, ['привіт']);
    await _deltas(t, [_d('  ', 2, 2, 'так', composing: const TextRange(start: 2, end: 5))]);
    await _deltas(t, [_d('  так', -1, -1, '')]); // the range ends with the same text
    expect(s.texts, ['привіт', 'так']);
    expect(s.keys, isEmpty);
  });

  testWidgets('twoInsertsBackToBackSendEachOnce', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 'a'), _d('  a', 3, 3, 'b')]);
    await _deltas(t, [_d('  ab', 4, 4, 'c')]); // the IME had not seen a reset yet
    expect(s.texts, ['a', 'b', 'c']);
    expect(t.testTextInput.editingState!['text'], '  ');
  });

  testWidgets('twoDeletesBackToBackSendTwoBackspaces', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 1, 2, ''), _d(' ', 0, 1, '')]);
    await _deltas(t, [_d(' ', 0, 1, '')]);
    expect(s.keys, List.filled(3, (VtKey.backspace, 0)));
  });

  testWidgets('aReplacementErasesThenTypes', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 't'), _d('  t', 3, 3, 'e'), _d('  te', 4, 4, 'h')]);
    await _deltas(t, [_d('  teh', 2, 5, 'the ')]);
    expect(s.screen, 'the ');
    expect(s.keys, isNotEmpty);
    expect(s.keys.every((k) => k == (VtKey.backspace, 0)), isTrue);
    expect(s.texts.last.endsWith('he '), isTrue);
  });

  testWidgets('hardwareKeysDuringComposingStayWithTheIme', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 'п', composing: const TextRange(start: 2, end: 3))]);
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(s.keys, isEmpty);
  });

  testWidgets('modifiedLettersAreControlAndEscape', (t) async {
    final s = await _open(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(s.texts, ['\x01', '\x1bx']);
    expect(s.keys, [(VtKey.backspace, vtAlt)]);
  });

  testWidgets('aLargeEditIsAPaste', (t) async {
    final s = await _open(t);
    await _deltas(t, [_d('  ', 2, 2, 'x' * 65)]);
    await _deltas(t, [_d('  ', 2, 2, 'y' * 64)]);
    await _deltas(t, [_d('  ', 2, 2, 'a\nb')]);
    expect(s.pastes, ['x' * 65, 'a\nb']);
    expect(s.texts, ['y' * 64]);
  });

  testWidgets('arrowKeyEventIsAKey', (t) async {
    final s = await _open(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(s.keys, [(VtKey.arrowUp, 0), (VtKey.arrowUp, vtShift), (VtKey.c, vtCtrl), (VtKey.backspace, 0)]);
    expect(s.texts, isEmpty);
  });

  testWidgets('keyboardIsAskedWithoutSuggestions', (t) async {
    await _open(t);
    final config = t.testTextInput.setClientArgs!;
    expect((config['inputType'] as Map)['name'], 'TextInputType.visiblePassword');
    expect(config['autocorrect'], isFalse);
    expect(config['enableSuggestions'], isFalse);
    expect(config['enableIMEPersonalizedLearning'], isFalse);
    expect(config['enableDeltaModel'], isTrue);
  });
}
