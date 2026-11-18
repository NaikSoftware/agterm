// One watched pane: its vt channel feeding an emulator, and while the phone leads, a claim channel carrying its input.
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
  TermSession(this.mux, this.target, this.pane, {Vt Function(int cols, int rows) vt = openVt}) : _makeVt = vt {
    mux.open(target, pane: pane).then(_opened, onError: (Object e) => _end(e is ElisError ? e.message : '$e'));
  }

  final Mux mux;
  final String target, pane;
  final Vt Function(int, int) _makeVt;
  VtChannel? _ch;
  Vt? _vt;
  StreamSubscription<VtEvent>? _sub;
  bool _closed = false, _dirty = false;
  VtSnapshot? _snapshot;
  bool _hold = false;
  (int, int)? _fit; // the grid the phone asked for, which the relay reports up to 2 s after the program draws at it
  ClaimChannel? _claim;
  StreamSubscription<ClaimEvent>? _claimSub;
  int _claimGen = 0; // bumped to drop a claim still waiting for OPENED, which cannot be cancelled
  (int, int) _leadSize = (80, 24), _claimedSize = (80, 24);
  bool _leading = false;
  bool _resynced = false; // the watch channel's Resync after the leader report: earlier queries were the Mac's to answer

  /// Why the relay ended the phone's lead; cleared by [takeOver].
  String? leadLost;

  /// Grid reports so far: the one after a release says the Mac leads the pane again.
  int grids = 0;

  bool get leading => _leading;

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
            final replies = _vt?.takeReplies(); // drained always, or take-over would type stale replies
            if (replies != null && replies.isNotEmpty && _leading && _resynced) _claim?.send(replies);
          } finally {
            _ch?.consumed(bytes.length); // every Data, in order, or the relay closes the channel `stalled`
          }
        case Resync():
          _vt?.reset(); // a Grid follows
          if (_claim != null) _resynced = true; // the relay resyncs only after the leader report that preceded OPENED
        case Grid(:final cols, :final rows):
          grids++;
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

  /// Claims the pane at [cols]x[rows]; null once the claim is open or was dropped by [release], else the refusal.
  /// [leading] follows the relay's LEAD.
  Future<String?> takeOver(int cols, int rows) async {
    if (_closed) return ended ?? 'closed';
    release();
    leadLost = null;
    final gen = _claimGen;
    final size = _clamp(cols, rows);
    final ClaimChannel ch;
    try {
      ch = await mux.claim(target, pane: pane, cols: size.$1, rows: size.$2);
    } catch (e) {
      return e is ElisError ? e.message : '$e';
    }
    if (gen != _claimGen || _closed) {
      unawaited(ch.close());
      return null; // released before OPENED: nothing to show
    }
    _claim = ch;
    _leadSize = _claimedSize = size;
    _resynced = false;
    _claimSub = ch.events.listen(_onClaim);
    return null;
  }

  void _onClaim(ClaimEvent e) {
    switch (e) {
      case Lead(role: 'leader'):
        _leading = true;
        if (_leadSize != _claimedSize) _claim?.resize(_leadSize.$1, _leadSize.$2);
        _send(_vt?.encodeFocus(true));
        _fit = _leadSize;
        _vt?.resize(_leadSize.$1, _leadSize.$2);
        _dirty = true;
      case Lead():
        _leading = false;
      case ClaimClosed(:final reason):
        unawaited(_claimSub?.cancel());
        _leading = false;
        _claim = null;
        leadLost = reason;
    }
    notifyListeners();
  }

  bool _send(Uint8List? bytes) {
    final ch = _claim;
    if (!_leading || ch == null || bytes == null) return false;
    return ch.send(bytes);
  }

  void key(VtKey key, {int mods = 0}) => _send(_vt?.encodeKey(key, mods: mods));

  void text(String s) => _send(_vt?.encodeText(s));

  /// False when nothing was sent: not leading, or more than 1 MiB of input is waiting.
  bool paste(String s) => _send(_vt?.encodePaste(s));

  /// One wheel notch; on the alternate screen of a program that does not track the mouse, an arrow key (mode 1007).
  void wheel({required bool up, required int col, required int row}) {
    if (!_leading) return;
    final alt = snapshot?.altScreen ?? false; // may dispose the emulator: read it first
    final vt = _vt;
    if (vt == null) return;
    final bytes = vt.encodeWheel(up: up, col: col, row: row);
    if (bytes.isNotEmpty) {
      _send(bytes);
    } else if (alt && vt.mode(1007)) {
      _send(vt.encodeKey(up ? VtKey.arrowUp : VtKey.arrowDown));
    }
  }

  /// Before the relay's LEAD, only remembered: the phone still shows the Mac's grid.
  void resizeLead(int cols, int rows) {
    final ch = _claim;
    if (ch == null || _closed) return;
    _leadSize = _clamp(cols, rows);
    if (!_leading) return;
    ch.resize(_leadSize.$1, _leadSize.$2);
    fitted(_leadSize.$1, _leadSize.$2);
  }

  static (int, int) _clamp(int cols, int rows) => (cols.clamp(1, 1000), rows.clamp(1, 1000)); // the relay ignores others

  /// Ends the phone's lead (focus out, then CLOSE), or drops a claim still waiting for OPENED.
  void release() {
    _claimGen++;
    final ch = _claim;
    if (ch == null) return;
    _send(_vt?.encodeFocus(false));
    unawaited(_claimSub?.cancel());
    unawaited(ch.close());
    _claim = null;
    _leading = false;
    if (!_closed) notifyListeners();
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
    _closed = true; // first: release() must not notify from build (_read)
    release();
    unawaited(_sub?.cancel());
    _vt?.dispose();
    _vt = null;
  }
}
