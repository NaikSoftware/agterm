// One watched pane: its vt channel feeding an emulator. Watch only: nothing is sent on the channel but CREDIT and CLOSE.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../client.dart';
import '../link/mux.dart';
import 'vt.dart';

Vt openVt(int cols, int rows) {
  Vt.open(); // libvtshim.so from the app's jniLibs; once per process
  return Vt(cols, rows);
}

/// Notifies on every change; [snapshot] reads the emulator only when asked and at most once per change. Listeners that
/// do not ask (the screen, once the text view is cleared) leave the read to the build: one a frame.
class TermSession extends ChangeNotifier {
  TermSession(this.mux, String target, this.pane, {Vt Function(int cols, int rows) vt = openVt}) : _makeVt = vt {
    mux.open(target, pane: pane).then(_opened, onError: (Object e) => _end(e is ElisError ? e.message : '$e'));
  }

  final Mux mux;
  final String pane;
  final Vt Function(int, int) _makeVt;
  VtChannel? _ch;
  Vt? _vt;
  StreamSubscription<VtEvent>? _sub;
  bool _closed = false, _dirty = false;
  VtSnapshot? _snapshot;
  bool _hold = false;
  (int, int)? _fit; // the grid the phone asked for, which the relay reports up to 2 s after the program draws at it

  /// Why the stream ended (a refusal, a relay CLOSE, `Disconnected`); null while it runs or after [close].
  String? ended;

  /// OPENED arrived: an [ended] reason is a CLOSE mid-stream, not a refusal of the open.
  bool get opened => _ch != null;

  VtSnapshot? get snapshot {
    _read();
    return _snapshot;
  }

  /// Synchronized output (mode 2026) is set: the view keeps the last frame for at most 1 s.
  bool get hold {
    _read();
    return _hold;
  }

  void _read() {
    final vt = _vt;
    if (!_dirty || vt == null) return;
    _dirty = false;
    try {
      _snapshot = vt.snapshot();
      _hold = vt.mode(2026);
    } catch (err) {
      // read from build(): end the session now, tell the listeners after the frame
      unawaited(_ch?.close());
      ended = 'The terminal view is not available: $err';
      _snapshot = null;
      _release();
      scheduleMicrotask(notifyListeners);
    }
  }

  void _opened(VtChannel ch) {
    if (_closed) return unawaited(ch.close()); // the screen left, paused or changed pane before OPENED
    _ch = ch;
    _sub = ch.events.listen(_on);
  }

  void _on(VtEvent e) {
    try {
      switch (e) {
        case Opened(:final cols, :final rows):
          _vt ??= _makeVt(_fit?.$1 ?? cols, _fit?.$2 ?? rows);
        case Data(:final bytes):
          try {
            _vt?.write(bytes); // bytes before a Resync too: the reset follows
          } finally {
            _ch?.consumed(bytes.length); // every Data, in order, or the relay closes the channel `stalled`
          }
        case Resync():
          _vt?.reset(); // a Grid follows
        case Grid(:final cols, :final rows):
          _fit = null; // the relay's report is the truth from now on
          _vt?.resize(cols, rows);
        case Closed(:final reason):
          return _end(reason);
      }
    } catch (err) {
      // the emulator could not load or failed (an ABI without libvtshim.so): the text view takes over
      unawaited(_ch?.close());
      return _end('The terminal view is not available: $err');
    }
    _dirty = true;
    notifyListeners();
  }

  /// The Mac took the phone's grid: size the emulator now, as the program redraws at once.
  void fitted(int cols, int rows) {
    _fit = (cols, rows);
    final vt = _vt;
    if (vt == null || _closed) return;
    vt.resize(cols, rows);
    _dirty = true;
    notifyListeners();
  }

  void _end(String reason) {
    if (_closed) return;
    ended = reason;
    _release();
    notifyListeners();
  }

  /// Sends CLOSE (the Mac's viewer count drops) and frees the emulator.
  void close() {
    if (_closed) return;
    unawaited(_ch?.close());
    _release();
  }

  void _release() {
    _closed = true;
    unawaited(_sub?.cancel());
    _vt?.dispose();
    _vt = null;
  }
}
