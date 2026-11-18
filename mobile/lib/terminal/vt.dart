import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _H = Pointer<Void>;
typedef _Out = Pointer<Uint8>;

/// The keys the phone sends, with their `GhosttyKey` values from `ghostty/vt/key/event.h`.
enum VtKey {
  escape(120),
  tab(64),
  enter(58),
  backspace(53),
  arrowUp(78),
  arrowDown(75),
  arrowLeft(76),
  arrowRight(77),
  home(71),
  end(69),
  pageUp(74),
  pageDown(73),
  c(22),
  d(23),
  l(31),
  r(37),
  z(45),
  u(40),
  unidentified(0);

  const VtKey(this.code);
  final int code;
}

/// `GhosttyMods` bits for [Vt.encodeKey].
const vtShift = 1, vtCtrl = 2, vtAlt = 4;

/// The vtshim functions, bound once per process by [Vt.open].
class _Lib {
  _Lib(DynamicLibrary l)
      : create = l.lookupFunction<_H Function(Uint16, Uint16, Uint32), _H Function(int, int, int)>('vts_new'),
        free = l.lookupFunction<Void Function(_H), void Function(_H)>('vts_free'),
        write = l.lookupFunction<Void Function(_H, Pointer<Uint8>, Size), void Function(_H, Pointer<Uint8>, int)>(
            'vts_write', isLeaf: true),
        resize = l.lookupFunction<Void Function(_H, Uint16, Uint16), void Function(_H, int, int)>('vts_resize', isLeaf: true),
        reset = l.lookupFunction<Void Function(_H), void Function(_H)>('vts_reset', isLeaf: true),
        mode = l.lookupFunction<Int32 Function(_H, Uint16), int Function(_H, int)>('vts_mode', isLeaf: true),
        snapshot = l.lookupFunction<Int32 Function(_H, Pointer<Uint32>, Int32), int Function(_H, Pointer<Uint32>, int)>(
            'vts_snapshot', isLeaf: true),
        encodeKey = l.lookupFunction<Int32 Function(_H, Uint32, Uint32, Uint32, _Out, Size, _Out, Int32),
            int Function(_H, int, int, int, _Out, int, _Out, int)>('vts_encode_key', isLeaf: true),
        encodePaste = l.lookupFunction<Int32 Function(_H, _Out, Size, _Out, Int32), int Function(_H, _Out, int, _Out, int)>(
            'vts_encode_paste', isLeaf: true),
        encodeWheel = l.lookupFunction<Int32 Function(_H, Int32, Uint16, Uint16, _Out, Int32),
            int Function(_H, int, int, int, _Out, int)>('vts_encode_wheel', isLeaf: true),
        encodeFocus = l.lookupFunction<Int32 Function(_H, Int32, _Out, Int32), int Function(_H, int, _Out, int)>(
            'vts_encode_focus', isLeaf: true),
        takeReplies = l.lookupFunction<Int32 Function(_H, _Out, Int32), int Function(_H, _Out, int)>(
            'vts_take_replies', isLeaf: true);

  final _H Function(int, int, int) create;
  final void Function(_H) free;
  final void Function(_H, Pointer<Uint8>, int) write;
  final void Function(_H, int, int) resize;
  final void Function(_H) reset;
  final int Function(_H, int) mode;
  final int Function(_H, Pointer<Uint32>, int) snapshot;
  final int Function(_H, int, int, int, _Out, int, _Out, int) encodeKey;
  final int Function(_H, _Out, int, _Out, int) encodePaste;
  final int Function(_H, int, int, int, _Out, int) encodeWheel;
  final int Function(_H, int, _Out, int) encodeFocus;
  final int Function(_H, _Out, int) takeReplies;
}

// Snapshot layout: see mobile/native/vtshim.c (header comment above vts_snapshot).
const _cellWords = 5;
const _hdrWords = 16;

/// One libghostty-vt terminal emulator. Call [dispose] to free its native memory.
class Vt {
  Vt(int cols, int rows, {int scrollback = 1000}) : _h = _bound.create(cols, rows, scrollback) {
    if (_h == nullptr) throw StateError('vts_new failed');
    _cap = _hdrWords + cols * (rows + 1) * _cellWords;
    _buf = malloc<Uint32>(_cap);
  }

  static _Lib? _lib;
  static String? _path;
  static _Lib get _bound => _lib ?? (throw StateError('Vt.open was not called'));

  /// Loads the shim: `libvtshim.so` on Android, `build/vtshim/libvtshim.dylib` in host tests.
  static void open([String path = 'libvtshim.so']) {
    if (_path != null && _path != path) throw StateError('vtshim already opened from $_path');
    _lib ??= _Lib(DynamicLibrary.open(path));
    _path = path;
  }

  final _H _h;
  late int _cap;
  late Pointer<Uint32> _buf;
  Pointer<Uint8> _in = nullptr;
  int _inCap = 0;
  Pointer<Uint8> _out = nullptr;
  int _outCap = 0;
  bool _disposed = false;

  _H get _live => _disposed ? throw StateError('Vt used after dispose') : _h;

  void write(Uint8List bytes) {
    final h = _live;
    if (bytes.isEmpty) return;
    _stage(bytes);
    _bound.write(h, _in, bytes.length);
  }

  void _stage(List<int> bytes) {
    if (bytes.length > _inCap) {
      final grown = malloc<Uint8>(bytes.length);
      malloc.free(_in);
      _in = grown;
      _inCap = bytes.length;
    }
    _in.asTypedList(bytes.length).setAll(0, bytes);
  }

  // Runs a shim encoder into the output buffer, growing it once on -needed (the vts_snapshot convention).
  Uint8List _encode(int Function(_Out out, int cap) call) {
    if (_outCap == 0) {
      _out = malloc<Uint8>(_outCap = 256);
    }
    var n = call(_out, _outCap);
    if (n < 0) {
      malloc.free(_out);
      _out = malloc<Uint8>(_outCap = -n);
      n = call(_out, _outCap);
    }
    return n <= 0 ? Uint8List(0) : Uint8List.fromList(_out.asTypedList(n));
  }

  /// The bytes [key] sends under the program's current modes (cursor keys, kitty flags...); [text] is its UTF-8 text.
  Uint8List encodeKey(VtKey key, {int mods = 0, String text = ''}) {
    final h = _live;
    final utf8Text = utf8.encode(text);
    // a letter's unshifted codepoint lets ctrl and kitty encode it without text
    final unshifted = key.name.length == 1 ? key.name.codeUnitAt(0) : 0;
    return _encode((out, cap) {
      _stage(utf8Text);
      return _bound.encodeKey(h, key.code, mods, unshifted, _in, utf8Text.length, out, cap);
    });
  }

  /// Typed text as the program expects it, sent as one unidentified key.
  Uint8List encodeText(String text) => encodeKey(VtKey.unidentified, text: text);

  /// Pasted text: bracketed under mode 2004, newlines as carriage returns otherwise.
  Uint8List encodePaste(String text) {
    final h = _live;
    final bytes = utf8.encode(text);
    if (bytes.isEmpty) return Uint8List(0);
    return _encode((out, cap) {
      _stage(bytes); // the shim rewrites it in place
      return _bound.encodePaste(h, _in, bytes.length, out, cap);
    });
  }

  /// One wheel notch at a zero-based cell; empty when the program does not track the mouse.
  Uint8List encodeWheel({required bool up, required int col, required int row}) {
    final h = _live;
    return _encode((out, cap) => _bound.encodeWheel(h, up ? 1 : 0, col, row, out, cap));
  }

  /// Focus in/out; empty unless the program set mode 1004.
  Uint8List encodeFocus(bool gained) {
    final h = _live;
    return _encode((out, cap) => _bound.encodeFocus(h, gained ? 1 : 0, out, cap));
  }

  /// The emulator's replies to queries (DA, cursor position, size) since the last take, to send to the program.
  Uint8List takeReplies() {
    final h = _live;
    return _encode((out, cap) => _bound.takeReplies(h, out, cap));
  }

  void resize(int cols, int rows) => _bound.resize(_live, cols, rows);

  /// Full reset (RIS).
  void reset() => _bound.reset(_live);

  /// A DEC private mode, e.g. 2026 (synchronized output) or 1049 (alternate screen).
  bool mode(int mode) {
    final m = _bound.mode(_live, mode);
    if (m < 0) throw ArgumentError.value(mode, 'mode', 'unknown DEC private mode');
    return m == 1;
  }

  VtSnapshot snapshot() {
    final h = _live;
    var n = _bound.snapshot(h, _buf, _cap);
    if (n < 0) {
      final grown = malloc<Uint32>(-n);
      malloc.free(_buf);
      _buf = grown;
      _cap = -n;
      n = _bound.snapshot(h, _buf, _cap);
    }
    if (n <= 0) throw StateError('vts_snapshot failed ($n)');
    final s = _buf.asTypedList(n);
    // the cell grid spans s[12] rows (viewport plus overscan); row r of the viewport starts at r * cols either way
    if (s[12] < s[1]) throw StateError('vts_snapshot: ${s[12]} grid rows < ${s[1]} viewport rows');
    return VtSnapshot._(s);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bound.free(_h);
    malloc.free(_buf);
    malloc.free(_in);
    malloc.free(_out);
  }
}

/// A copy of the viewport, safe to keep after the next [Vt.snapshot].
class VtSnapshot {
  VtSnapshot._(Uint32List s)
      : cols = s[0],
        rows = s[1],
        cursorX = s[2],
        cursorY = s[3],
        cursorVisible = s[4] & 3 == 3,
        altScreen = s[10] == 1, // GHOSTTY_TERMINAL_SCREEN_ALTERNATE, whichever mode (47, 1047, 1049) switched it
        // only the viewport rows: the overscan row below them is not shown (no sub-row scroll in M4b)
        lines = List.generate(s[1], (r) => VtRow._(s, r));

  final int cols, rows, cursorX, cursorY;
  final bool cursorVisible;

  /// A full-screen program's screen, which has no history.
  final bool altScreen;
  final List<VtRow> lines;
}

class VtRow {
  VtRow._(Uint32List s, int r) : cells = List.generate(s[0], (c) => VtCell._(s, _hdrWords + (r * s[0] + c) * _cellWords));

  /// One cell per column; the right half of a wide character is a [VtCell.spacer].
  final List<VtCell> cells;

  // content equality (the cluster offsets in the raw words are left out): the painter's row cache keys on it
  @override
  late final int hashCode = Object.hashAll(cells);

  @override
  bool operator ==(Object other) =>
      other is VtRow && other.hashCode == hashCode && _sameCells(other.cells);

  bool _sameCells(List<VtCell> o) {
    if (o.length != cells.length) return false;
    for (var i = 0; i < o.length; i++) {
      if (o[i] != cells[i]) return false;
    }
    return true;
  }

  /// The row as plain text, trailing blanks trimmed (the form of `tmux capture-pane -p`).
  String get text {
    final b = StringBuffer();
    for (final c in cells) {
      if (!c.spacer) b.write(c.text.isEmpty ? ' ' : c.text);
    }
    return b.toString().trimRight();
  }
}

class VtCell {
  VtCell._(Uint32List s, int w)
      : text = _text(s, w),
        fg = _color(s[w + 2]),
        bg = _color(s[w + 3]),
        flags = s[w + 4];

  /// The grapheme cluster, '' for an empty cell or a spacer.
  final String text;

  /// ARGB, null for the default colour.
  final int? fg, bg;

  /// Raw shim flags: bold 1, italic 2, underline 4, inverse 8, faint 16, strike 32, invisible 64, wide 1<<8, spacer 1<<9.
  final int flags;

  bool get bold => flags & 1 != 0;
  bool get italic => flags & 2 != 0;
  bool get underline => flags & 4 != 0;
  bool get inverse => flags & 8 != 0;
  bool get faint => flags & 16 != 0;
  bool get strike => flags & 32 != 0;
  bool get invisible => flags & 64 != 0;
  bool get wide => flags & (1 << 8) != 0;
  bool get spacer => flags & (1 << 9) != 0;

  @override
  int get hashCode => Object.hash(text, fg, bg, flags);

  @override
  bool operator ==(Object other) => other is VtCell && other.text == text && other.fg == fg && other.bg == bg && other.flags == flags;

  static int? _color(int v) => v >> 24 == 0 ? null : v;

  static String _text(Uint32List s, int w) {
    final glen = s[w + 4] >> 16, off = s[w + 1];
    if (glen > 1 && off != 0) return String.fromCharCodes(s, off, off + glen);
    return s[w] == 0 ? '' : String.fromCharCode(s[w]);
  }
}
