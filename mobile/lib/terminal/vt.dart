import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _H = Pointer<Void>;

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
            'vts_snapshot', isLeaf: true);

  final _H Function(int, int, int) create;
  final void Function(_H) free;
  final void Function(_H, Pointer<Uint8>, int) write;
  final void Function(_H, int, int) resize;
  final void Function(_H) reset;
  final int Function(_H, int) mode;
  final int Function(_H, Pointer<Uint32>, int) snapshot;
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
  static _Lib get _bound => _lib ?? (throw StateError('Vt.open was not called'));

  /// Loads the shim: `libvtshim.so` on Android, `build/vtshim/libvtshim.dylib` in host tests.
  static void open([String path = 'libvtshim.so']) => _lib ??= _Lib(DynamicLibrary.open(path));

  final _H _h;
  late int _cap;
  late Pointer<Uint32> _buf;
  Pointer<Uint8> _in = nullptr;
  int _inCap = 0;
  bool _disposed = false;

  void write(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (bytes.length > _inCap) {
      malloc.free(_in);
      _in = malloc<Uint8>(_inCap = bytes.length);
    }
    _in.asTypedList(bytes.length).setAll(0, bytes);
    _bound.write(_h, _in, bytes.length);
  }

  void resize(int cols, int rows) => _bound.resize(_h, cols, rows);

  /// Full reset (RIS).
  void reset() => _bound.reset(_h);

  /// A DEC private mode, e.g. 2026 (synchronized output) or 1049 (alternate screen).
  bool mode(int mode) {
    final m = _bound.mode(_h, mode);
    if (m < 0) throw ArgumentError.value(mode, 'mode', 'unknown DEC private mode');
    return m == 1;
  }

  VtSnapshot snapshot() {
    var n = _bound.snapshot(_h, _buf, _cap);
    if (n < 0) {
      malloc.free(_buf);
      _buf = malloc<Uint32>(_cap = -n);
      n = _bound.snapshot(_h, _buf, _cap);
    }
    if (n <= 0) throw StateError('vts_snapshot failed ($n)');
    return VtSnapshot._(_buf.asTypedList(n));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bound.free(_h);
    malloc.free(_buf);
    malloc.free(_in);
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
        lines = List.generate(s[1], (r) => VtRow._(s, r));

  final int cols, rows, cursorX, cursorY;
  final bool cursorVisible;
  final List<VtRow> lines;
}

class VtRow {
  VtRow._(Uint32List s, int r) : cells = List.generate(s[0], (c) => VtCell._(s, _hdrWords + (r * s[0] + c) * _cellWords));

  /// One cell per column; the right half of a wide character is a [VtCell.spacer].
  final List<VtCell> cells;

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

  static int? _color(int v) => v >> 24 == 0 ? null : v;

  static String _text(Uint32List s, int w) {
    final glen = s[w + 4] >> 16, off = s[w + 1];
    if (glen > 1 && off != 0) return String.fromCharCodes(s, off, off + glen);
    return s[w] == 0 ? '' : String.fromCharCode(s[w]);
  }
}
