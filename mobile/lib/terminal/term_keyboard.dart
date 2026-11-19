import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'vt.dart';

/// A hidden input that turns soft-keyboard edits into terminal input.
class TermKeyboard extends StatefulWidget {
  const TermKeyboard({super.key, required this.focus, required this.onKey, required this.onText, required this.onPaste});
  final FocusNode focus;
  final void Function(VtKey key, int mods) onKey;
  final void Function(String text) onText;
  final void Function(String text) onPaste;

  @override
  State<TermKeyboard> createState() => _TermKeyboardState();
}

// Android reports a soft keyboard's Backspace only as a text change, so the field holds two spaces to delete
const _sentinel = TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2));

final _named = {
  LogicalKeyboardKey.arrowUp: VtKey.arrowUp,
  LogicalKeyboardKey.arrowDown: VtKey.arrowDown,
  LogicalKeyboardKey.arrowLeft: VtKey.arrowLeft,
  LogicalKeyboardKey.arrowRight: VtKey.arrowRight,
  LogicalKeyboardKey.home: VtKey.home,
  LogicalKeyboardKey.end: VtKey.end,
  LogicalKeyboardKey.pageUp: VtKey.pageUp,
  LogicalKeyboardKey.pageDown: VtKey.pageDown,
  LogicalKeyboardKey.tab: VtKey.tab,
  LogicalKeyboardKey.escape: VtKey.escape,
  LogicalKeyboardKey.backspace: VtKey.backspace,
  LogicalKeyboardKey.enter: VtKey.enter,
  LogicalKeyboardKey.numpadEnter: VtKey.enter,
};

// the platform's own text for the field: each IME edit is applied to the IME's text before it, never compared with a
// constant, so edits the IME made before a reset reached it count once
class _TermKeyboardState extends State<TermKeyboard> with TextInputClient, DeltaTextInputClient {
  TextInputConnection? _connection;
  TextEditingValue _value = _sentinel;

  bool get _composing => _value.composing.isValid && !_value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_focused);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focused);
    _connection?.close();
    super.dispose();
  }

  void _focused() {
    if (widget.focus.hasFocus && _connection == null) {
      _value = _sentinel;
      _connection = TextInput.attach(
          this,
          const TextInputConfiguration(
            inputType: TextInputType.visiblePassword,
            inputAction: TextInputAction.none,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            enableDeltaModel: true,
          ))
        ..setEditingState(_sentinel)
        ..show();
    } else if (!widget.focus.hasFocus) {
      _connection?.close();
      _connection = null;
    }
  }

  // the field's text with its composing range left out: what the program has been sent
  static String _sent(TextEditingValue v) {
    final c = v.composing;
    return c.isValid && !c.isCollapsed && c.end <= v.text.length ? v.text.replaceRange(c.start, c.end, '') : v.text;
  }

  void _edit(TextEditingValue before, TextEditingValue after) {
    final a = _sent(before), b = _sent(after);
    var same = 0;
    while (same < a.length && same < b.length && a.codeUnitAt(same) == b.codeUnitAt(same)) {
      same++;
    }
    if (same > 0 && (a.codeUnitAt(same - 1) & 0xFC00) == 0xD800) same--; // never split a surrogate pair
    for (var i = 0; i < a.substring(same).runes.length; i++) {
      widget.onKey(VtKey.backspace, 0);
    }
    final added = b.substring(same);
    if (added == '\n') {
      widget.onKey(VtKey.enter, 0);
    } else if (added.contains('\n') || added.length > 64) {
      widget.onPaste(added);
    } else if (added.isNotEmpty) {
      widget.onText(added);
    }
    _value = after;
    if (_composing || after == _sentinel) return;
    _value = _sentinel;
    _connection?.setEditingState(_sentinel);
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    for (final d in deltas) {
      // the composing range the IME had then is the last one it reported
      final before = TextEditingValue(text: d.oldText, composing: _value.composing.end <= d.oldText.length ? _value.composing : TextRange.empty);
      _edit(before, d.apply(before));
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) => _edit(_value, value);

  @override
  void performAction(TextInputAction action) => widget.onKey(VtKey.enter, 0);

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void connectionClosed() {
    _connection = null;
    widget.focus.unfocus();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  // handled, or Android hands the key on to the IME and it arrives a second time as a text edit; while composing, the
  // keys edit the composition
  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (_composing) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    final ctrl = k.isControlPressed, alt = k.isAltPressed;
    final label = e.logicalKey.keyLabel.toLowerCase();
    final letter = label.length == 1 && label.codeUnitAt(0) >= 0x61 && label.codeUnitAt(0) <= 0x7a ? label : null;
    final named = _named[e.logicalKey] ?? (ctrl && letter != null ? VtKey.values.asNameMap()[letter] : null);
    if (named == null && (letter == null || !ctrl && !alt)) return KeyEventResult.ignored;
    if (e is KeyUpEvent) return KeyEventResult.handled;
    if (named != null) {
      widget.onKey(named, (k.isShiftPressed ? vtShift : 0) | (ctrl ? vtCtrl : 0) | (alt ? vtAlt : 0));
    } else {
      final c = ctrl ? String.fromCharCode(letter!.codeUnitAt(0) & 0x1f) : k.isShiftPressed ? letter!.toUpperCase() : letter!;
      widget.onText('${alt ? '\x1b' : ''}$c');
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: widget.focus, skipTraversal: true, includeSemantics: false, onKeyEvent: _key, child: const SizedBox.shrink());
}
