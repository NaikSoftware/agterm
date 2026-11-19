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

// Android reports a soft keyboard's Backspace only as a text change, so the field always holds two spaces to delete
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

class _TermKeyboardState extends State<TermKeyboard> {
  final _field = TextEditingController.fromValue(_sentinel);

  @override
  void initState() {
    super.initState();
    _field.addListener(_changed);
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _changed() {
    final v = _field.value;
    if (v == _sentinel || v.composing.isValid && !v.composing.isCollapsed) return;
    final t = v.text;
    var same = 0;
    while (same < 2 && same < t.length && t[same] == ' ') {
      same++;
    }
    for (var i = same; i < 2; i++) {
      widget.onKey(VtKey.backspace, 0);
    }
    final added = t.substring(same);
    if (added == '\n') {
      widget.onKey(VtKey.enter, 0);
    } else if (added.contains('\n') || added.length > 64) {
      widget.onPaste(added);
    } else if (added.isNotEmpty) {
      widget.onText(added);
    }
    _field.value = _sentinel;
  }

  // handled, or Android hands the key on to the IME and it arrives a second time as a text edit
  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final k = HardwareKeyboard.instance;
    final ctrl = k.isControlPressed;
    final letter = e.logicalKey.keyLabel.length == 1 ? VtKey.values.asNameMap()[e.logicalKey.keyLabel.toLowerCase()] : null;
    final key = _named[e.logicalKey] ?? (ctrl ? letter : null);
    if (key == null) return KeyEventResult.ignored;
    if (e is! KeyUpEvent) widget.onKey(key, (k.isShiftPressed ? vtShift : 0) | (ctrl ? vtCtrl : 0) | (k.isAltPressed ? vtAlt : 0));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: IgnorePointer(
          child: SizedBox.shrink(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _key,
              child: EditableText(
                controller: _field,
                focusNode: widget.focus,
                style: const TextStyle(fontSize: 1),
                cursorColor: const Color(0x00000000),
                backgroundCursorColor: const Color(0x00000000),
                maxLines: null, // single-line, the field would turn a pasted newline into a space
                showCursor: false,
                enableInteractiveSelection: false,
                keyboardType: TextInputType.visiblePassword,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.none,
                onEditingComplete: () => widget.onKey(VtKey.enter, 0), // keeps the focus
              ),
            ),
          ),
        ),
      );
}
