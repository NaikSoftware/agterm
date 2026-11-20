import 'package:flutter/material.dart';

import '../theme.dart';
import 'vt.dart';

// what each key-bar key types into the pane: xterm sequences, as Konsole sends them, or while the phone leads, the key
// the emulator encodes in the program's own modes
const keys = [
  ('esc', '\x1b', 'Escape', VtKey.escape, 0),
  ('tab', '\t', 'Tab', VtKey.tab, 0),
  ('⇧tab', '\x1b[Z', 'Shift Tab', VtKey.tab, vtShift),
  ('^C', '\x03', 'Control C', VtKey.c, vtCtrl),
  ('↑', '\x1b[A', 'Up', VtKey.arrowUp, 0),
  ('↓', '\x1b[B', 'Down', VtKey.arrowDown, 0),
  ('←', '\x1b[D', 'Left', VtKey.arrowLeft, 0),
  ('→', '\x1b[C', 'Right', VtKey.arrowRight, 0),
  ('⏎', '\r', 'Enter', VtKey.enter, 0),
  ('^D', '\x04', 'Control D', VtKey.d, vtCtrl),
  ('^L', '\x0c', 'Control L', VtKey.l, vtCtrl),
  ('^R', '\x12', 'Control R', VtKey.r, vtCtrl),
  ('^Z', '\x1a', 'Control Z', VtKey.z, vtCtrl),
  ('^U', '\x15', 'Control U', VtKey.u, vtCtrl),
  ('home', '\x1b[H', 'Home', VtKey.home, 0),
  ('end', '\x1b[F', 'End', VtKey.end, 0),
  ('pgup', '\x1b[5~', 'Page up', VtKey.pageUp, 0),
  ('pgdn', '\x1b[6~', 'Page down', VtKey.pageDown, 0),
  ('paste', null, 'Paste', null, 0), // the clipboard
];

/// What [key] with [mods] types indirectly, as xterm sends it: cursor keys carry the modifiers as `CSI 1;m`, other
/// keys take alt as a leading ESC.
String xtermSeq(VtKey key, int mods) {
  final m = 1 + (mods & vtShift != 0 ? 1 : 0) + (mods & vtAlt != 0 ? 2 : 0) + (mods & vtCtrl != 0 ? 4 : 0);
  final cursor = const {
    VtKey.arrowUp: '1;mA', VtKey.arrowDown: '1;mB', VtKey.arrowRight: '1;mC', VtKey.arrowLeft: '1;mD', //
    VtKey.home: '1;mH', VtKey.end: '1;mF', VtKey.pageUp: '5;m~', VtKey.pageDown: '6;m~',
  }[key];
  if (cursor != null && m > 1) return '\x1b[${cursor.replaceFirst('m', '$m')}';
  final plain = mods & ~vtAlt;
  final seq = key == VtKey.backspace ? '\x7f' : (keys.where((k) => k.$4 == key && k.$5 == plain).firstOrNull ?? keys.firstWhere((k) => k.$4 == key)).$2!;
  return mods & vtAlt != 0 ? '\x1b$seq' : seq;
}

/// The row of [keys] under a session, after a key that toggles the soft keyboard.
class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.onKey, required this.onKeyboard});
  final void Function(String? seq, VtKey? key, int mods) onKey;
  final VoidCallback onKeyboard;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 48,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          scrollDirection: Axis.horizontal,
          itemCount: keys.length + 1,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Tooltip(
                message: 'Keyboard',
                child: OutlinedButton(
                  key: const Key('softKeyboard'),
                  onPressed: onKeyboard,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 10), foregroundColor: C.text, backgroundColor: C.surface),
                  child: const Icon(Icons.keyboard_outlined, size: 18),
                ),
              );
            }
            final (label, seq, name, key, mods) = keys[i - 1];
            return Semantics(
              label: name,
              button: true,
              excludeSemantics: true,
              child: OutlinedButton(
                key: Key('key-$name'),
                onPressed: () => onKey(seq, key, mods),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: label == '⏎' ? C.accent : C.text,
                  backgroundColor: label == '⏎' ? C.surface2 : C.surface,
                ),
                child: Text(label, style: const TextStyle(fontFamily: mono, fontSize: 13)),
              ),
            );
          },
        ),
      );
}
