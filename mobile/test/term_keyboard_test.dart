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
}

Future<_Sink> _open(WidgetTester t) async {
  final s = _Sink();
  addTearDown(s.focus.dispose);
  await t.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: TermKeyboard(focus: s.focus, onKey: (k, m) => s.keys.add((k, m)), onText: s.texts.add, onPaste: s.pastes.add),
    ),
  ));
  s.focus.requestFocus();
  await t.pump();
  expect(t.testTextInput.hasAnyClients, isTrue);
  return s;
}

TextEditingValue _at(String text, {TextRange composing = TextRange.empty}) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length), composing: composing);

Future<void> _edit(WidgetTester t, String text, {TextRange composing = TextRange.empty}) async {
  t.testTextInput.updateEditingValue(_at(text, composing: composing));
  await t.pump();
}

void main() {
  testWidgets('aLetterIsText', (t) async {
    final s = await _open(t);
    await _edit(t, '  a');
    expect(s.texts, ['a']);
    expect(s.keys, isEmpty);
    expect(t.testTextInput.editingState!['text'], '  ');
  });

  testWidgets('backspaceIsAKey', (t) async {
    final s = await _open(t);
    await _edit(t, ' ');
    expect(s.keys, [(VtKey.backspace, 0)]);
    await _edit(t, '');
    expect(s.keys, List.filled(3, (VtKey.backspace, 0)));
    expect(s.texts, isEmpty);
  });

  testWidgets('backspaceRepeats', (t) async {
    final s = await _open(t);
    for (var i = 0; i < 3; i++) {
      await _edit(t, ' ');
    }
    expect(s.keys, List.filled(3, (VtKey.backspace, 0)));
  });

  testWidgets('enterActionIsAKeyAndKeepsFocus', (t) async {
    final s = await _open(t);
    await t.testTextInput.receiveAction(TextInputAction.none);
    await t.pump();
    expect(s.keys, [(VtKey.enter, 0)]);
    expect(s.focus.hasFocus, isTrue);
    await _edit(t, '  \n');
    expect(s.keys, [(VtKey.enter, 0), (VtKey.enter, 0)]);
    expect(s.pastes, isEmpty);
  });

  testWidgets('ukrainianCommitIsText', (t) async {
    final s = await _open(t);
    await _edit(t, '  привіт');
    expect(s.texts, ['привіт']);
  });

  testWidgets('composingSendsOnlyAtItsEnd', (t) async {
    final s = await _open(t);
    await _edit(t, '  п', composing: const TextRange(start: 2, end: 3));
    await _edit(t, '  при', composing: const TextRange(start: 2, end: 5));
    expect(s.texts, isEmpty);
    await _edit(t, '  привіт');
    expect(s.texts, ['привіт']);
    await _edit(t, '  так', composing: const TextRange(start: 2, end: 5));
    await _edit(t, '  так'); // the range ends with the same text
    expect(s.texts, ['привіт', 'так']);
    expect(s.keys, isEmpty);
  });

  testWidgets('aLargeEditIsAPaste', (t) async {
    final s = await _open(t);
    await _edit(t, '  ${'x' * 65}');
    await _edit(t, '  ${'y' * 64}');
    await _edit(t, '  a\nb');
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
  });
}
