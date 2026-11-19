// One watched pane: its vt channel feeding an emulator, and while the phone leads, a claim channel carrying its input.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

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
  ClaimChannel? _claim, _opening; // [_opening] waits for OPENED; closing it then keeps the relay from attaching it
  StreamSubscription<ClaimEvent>? _claimSub;
  int _claimGen = 0; // bumped to drop a claim still waiting for OPENED
  (int, int) _leadSize = (80, 24), _claimedSize = (80, 24);
  bool _leading = false;
  bool _resynced = false; // the watch channel's Resync after the leader report: earlier queries were the Mac's to answer
  bool _armed = false;
  final _queue = ListQueue<_Intent>();
  int _queuedBytes = 0;
  Timer? _gap; // holds the queue between a line's text and its Enter
  String? _inputLost;
  bool _replaying = false; // from a Resync to the first Data after it

  /// The emulator holds a Resync's reset, not the program's screen, until the replay's first bytes.
  bool get replaying => _replaying;

  /// Why the relay ended the phone's lead; cleared by [takeOver].
  String? leadLost;

  bool get leading => _leading;

  /// Set once when the claim channel refused queued input, which is dropped with everything behind it; cleared when read.
  String? get inputLost {
    final lost = _inputLost;
    _inputLost = null;
    return lost;
  }

  /// Input queues until the lead arrives: armed or claimed, and not leading.
  bool get pending => (_armed || _claim != null) && !_leading;

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
      _release(keep: true);
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
          if (_claim != null) {
            _resynced = true; // a fresh watch is past any leader report
            _drain(); // input that came under a lead that preceded the emulator
          }
        case Data(:final bytes):
          _replaying = false;
          try {
            _vt?.write(bytes); // bytes before a Resync too: the reset follows
            final replies = _vt?.takeReplies(); // drained always, or take-over would type stale replies
            if (replies != null && replies.isNotEmpty && _leading && _resynced) _claim?.send(replies);
          } finally {
            _ch?.consumed(bytes.length); // every Data, in order, or the relay closes the channel `stalled`
          }
        case Resync():
          _vt?.reset(); // a Grid follows
          _replaying = true;
          if (_claim != null) _resynced = true; // the relay resyncs only after the leader report that preceded OPENED
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

  /// Claims the pane at [cols]x[rows]; null once the claim is open or was dropped by [release], else the refusal.
  /// [leading] follows the relay's LEAD.
  Future<String?> takeOver(int cols, int rows) async {
    if (_closed) return ended ?? 'closed';
    _endClaim();
    leadLost = null;
    final gen = _claimGen;
    final size = _clamp(cols, rows);
    final ch = _opening = mux.claim(target, pane: pane, cols: size.$1, rows: size.$2);
    try {
      await ch.opened;
    } catch (e) {
      if (gen != _claimGen) return null; // released before OPENED: nothing to show
      _opening = null;
      _armed = false; // the queue stays for takeUnsent
      return e is ElisError ? e.message : '$e';
    }
    if (gen != _claimGen || _closed) {
      unawaited(ch.close());
      return null;
    }
    _opening = null;
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
        _drain();
      case Lead():
        _leading = false;
      case ClaimClosed(:final reason):
        unawaited(_claimSub?.cancel());
        _leading = false;
        _claim = null;
        leadLost = reason;
        _armed = false;
        _drop();
    }
    notifyListeners();
  }

  bool _send(Uint8List? bytes) {
    final ch = _claim;
    if (!_leading || ch == null || bytes == null) return false;
    return ch.send(bytes);
  }

  /// Sends [key] while leading, else queues it; [seq] is what [takeUnsent] gives back for it.
  /// False when neither: not armed and not leading, closed, or past 256 intents or 1 MiB.
  bool key(VtKey key, {int mods = 0, required String seq}) => _add([(seq, (vt) => vt.encodeKey(key, mods: mods), false)]);

  bool text(String s) => _add([(s, (vt) => vt.encodeText(s), false)]);

  bool paste(String s) => _add([(s, (vt) => vt.encodePaste(s), false)]);

  /// [s] typed, then Enter 20 ms later: a program reading Enter in the same read as the text takes it as a paste.
  bool line(String s) => _add([
    if (s.isNotEmpty) (s, (vt) => vt.encodeText(s), false),
    ('\r', (vt) => vt.encodeKey(VtKey.enter), s.isNotEmpty),
  ]);

  /// The queued input as `session.type` strings, in order; clears the queue. An [ended] term keeps it for this.
  List<String> takeUnsent() {
    final unsent = [for (final i in _queue) if (i.$1.isNotEmpty) i.$1]; // a click has no indirect form
    _drop();
    return unsent;
  }

  /// Input queues from now; [takeOver] follows.
  void arm() {
    if (!_closed) _armed = true;
  }

  bool _add(List<_Intent> intents) {
    if (_closed || !(_armed || _leading)) return false;
    final bytes = intents.fold(0, (n, i) => n + utf8.encode(i.$1).length);
    if (_queue.length + intents.length > 256 || _queuedBytes + bytes > 1 << 20) return false;
    _queue.addAll(intents);
    _queuedBytes += bytes;
    return _drain(fresh: intents.length);
  }

  /// Sends the queue while leading, stopping at a line's Enter for the gap.
  /// A refused send drops the rest of the queue, so nothing goes out of order; false when that happened. Losing more
  /// than the caller's [fresh] intents sets [inputLost].
  bool _drain({bool gapDone = false, int fresh = 0}) {
    while (_leading && _vt != null && _queue.isNotEmpty && _gap == null) {
      final (unsent, encode, gap) = _queue.first;
      if (gap && !gapDone) {
        _gap = Timer(const Duration(milliseconds: 20), () {
          _gap = null;
          _drain(gapDone: true);
        });
        break;
      }
      gapDone = false;
      _queue.removeFirst();
      _queuedBytes -= utf8.encode(unsent).length;
      if (_send(encode(_vt!))) continue;
      final lost = _queue.length + 1;
      _drop();
      if (lost > fresh && _inputLost == null) {
        _inputLost = 'The computer has not taken the earlier input yet.';
        if (!_closed) notifyListeners();
      }
      return false;
    }
    return true;
  }

  void _drop() {
    _gap?.cancel();
    _gap = null;
    _queue.clear();
    _queuedBytes = 0;
  }

  /// Sent while leading; queued while the lead is pending, encoded in the program's mouse mode when it arrives.
  void click({required int col, required int row}) => _add([('', (vt) => vt.encodeClick(col: col, row: row), false)]);

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

  /// Before the relay's LEAD, only remembered: the phone still shows the Mac's grid. While leading, the emulator takes
  /// the new size from the Resync and Grid that follow, as bytes for the old grid are still in flight.
  void resizeLead(int cols, int rows) {
    final ch = _claim;
    if (ch == null || _closed) return;
    _leadSize = _clamp(cols, rows);
    if (_leading) ch.resize(_leadSize.$1, _leadSize.$2);
  }

  static (int, int) _clamp(int cols, int rows) => (cols.clamp(1, 1000), rows.clamp(1, 1000)); // the relay ignores others

  /// Ends the phone's lead (the queued input, keeping a line's gap, then focus out and CLOSE), or closes a claim still
  /// waiting for OPENED; input that never led is dropped.
  void release() {
    _endClaim();
    _armed = false;
    _drop();
  }

  void _endClaim() {
    _claimGen++;
    unawaited(_opening?.close());
    _opening = null;
    final ch = _claim;
    if (ch == null) return;
    final vt = _vt;
    // encoded now: the emulator is freed before a gap ends when the session closes
    final rest = [
      if (_leading && vt != null) ...[for (final (_, encode, gap) in _queue) (encode(vt), gap), (vt.encodeFocus(false), false)],
    ];
    _drop();
    unawaited(_claimSub?.cancel());
    _claim = null;
    _leading = false;
    unawaited(_flush(ch, rest));
    if (!_closed) notifyListeners();
  }

  static Future<void> _flush(ClaimChannel ch, List<(Uint8List, bool)> rest) async {
    for (final (bytes, gap) in rest) {
      if (gap) await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!ch.send(bytes)) break;
    }
    await ch.close();
  }

  void _end(String reason) {
    if (_closed) return;
    ended = reason;
    _release(keep: true);
    notifyListeners();
  }

  /// Sends CLOSE (the Mac's viewer count drops) and frees the emulator.
  void close() {
    if (_closed) return;
    unawaited(_ch?.close());
    _release();
  }

  /// [keep]: the stream ended under the phone, so input that never led stays for [takeUnsent].
  void _release({bool keep = false}) {
    _closed = true; // first: release() must not notify from build (_read)
    _endClaim();
    _armed = false;
    if (!keep) _drop();
    unawaited(_sub?.cancel());
    _vt?.dispose();
    _vt = null;
  }
}

/// What [TermSession.takeUnsent] gives back, its encoding when sent, and whether it waits 20 ms (a line's Enter).
typedef _Intent = (String, Uint8List Function(Vt), bool);
