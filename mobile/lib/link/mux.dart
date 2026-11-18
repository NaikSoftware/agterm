// The relay mux (control-api.md "Relay mux"): channel 0 carries the control lines, channel 1 the event rows,
// channels 2 and up one vt pane each: watched (the phone never sends DATA or RESIZE on them) or claimed (input only).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../client.dart';
import 'decoder.dart';
import 'frame.dart';
import 'messages.dart';

sealed class VtEvent {}

class Opened extends VtEvent {
  Opened(this.cols, this.rows);
  final int cols, rows;
}

class Data extends VtEvent {
  Data(this.bytes);
  final Uint8List bytes;
}

class Grid extends VtEvent {
  Grid(this.cols, this.rows);
  final int cols, rows;
}

/// Reset the emulator; a Grid follows, then a full screen. Data received before it must still be reported to
/// [VtChannel.consumed] (in order): those bytes leave the credit accounting there, not here.
class Resync extends VtEvent {}

class Closed extends VtEvent {
  Closed(this.reason);
  final String reason;
}

sealed class ClaimEvent {}

class Lead extends ClaimEvent {
  Lead(this.role);
  final String role;
}

class ClaimClosed extends ClaimEvent {
  ClaimClosed(this.reason);
  final String reason;
}

/// An event row saying rows were lost (`{"dropped":N}`, `{"gap":true}`): tree rows may be among them, so re-read `tree`.
bool rereadsTree(Map<String, dynamic> row) => row.containsKey('dropped') || row['gap'] == true;

const _creditBatch = 16 * 1024;
const _duplicateOpen = 'channel already open';
const _claimWindow = 16 * 1024; // the relay's receive window: more unacknowledged closes the channel `input overflow`
const _claimQueueCap = 1 << 20;

class Mux {
  Mux._(this._c);

  final Connection _c;
  final _decoder = LinkDecoder();
  final _control = LineBuffer();
  final _eventLines = LineBuffer();
  final _events = StreamController<Map<String, dynamic>>.broadcast(); // nobody may listen: rows are not kept
  final _channels = <int, _Channel>{};
  final _done = Completer<void>();
  var _nextChannel = 2;
  String _lostReason = 'Disconnected';

  /// Asks the relay for frames; null when it does not answer within [timeout] (an older Mac) or the link ended.
  static Future<Mux?> upgrade(Connection c, {Duration timeout = const Duration(seconds: 5)}) async {
    final m = Mux._(c);
    if (!await c.switchToFrames(timeout, frames: m._feed, sendLine: m._sendLine)) return null;
    unawaited(c.closed.then((_) => m._lost()));
    return m;
  }

  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args}) => _c.call(cmd, target: target, args: args);

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Emits once when the link ends; every channel is closed by then.
  Stream<void> get closed => _done.future.asStream();

  /// Completes on OPENED; a refusal throws ElisError with the relay's reason, `revoked` throws Revoked.
  Future<VtChannel> open(String target, {String? pane}) {
    if (_done.isCompleted) return Future.error(ElisError('Disconnected'));
    final ch = VtChannel._(this, _nextChannel++); // ids are used once per link
    _channels[ch.id] = ch;
    _add(LinkFrame.json(LinkKind.open, ch.id, {'type': 'vt', 'target': target, 'pane': ?pane}));
    return ch._opened.future;
  }

  /// [open] for input: completes on OPENED, after which the relay sends LEAD; a refusal throws as [open] does.
  Future<ClaimChannel> claim(String target, {String? pane, required int cols, required int rows}) {
    if (_done.isCompleted) return Future.error(ElisError('Disconnected'));
    final ch = ClaimChannel._(this, _nextChannel++);
    _channels[ch.id] = ch;
    _add(LinkFrame.json(LinkKind.open, ch.id, {'type': 'vt', 'target': target, 'pane': ?pane, 'claim': true, 'cols': cols, 'rows': rows}));
    return ch._opened.future;
  }

  void _add(LinkFrame f) => _c.addBytes(f.encode());

  void _sendLine(List<int> line) {
    for (var at = 0; at < line.length; at += linkMaxPayload) {
      _add(LinkFrame.data(0, line.sublist(at, min(at + linkMaxPayload, line.length))));
    }
  }

  void _feed(List<int> bytes) {
    final List<LinkFrame> frames;
    try {
      frames = _decoder.feed(bytes);
    } on LinkError {
      _c.close(); // the stream cannot be resynchronised
      return;
    }
    for (final f in frames) {
      _onFrame(f);
    }
  }

  void _onFrame(LinkFrame f) {
    if (f.channel == 0 && f.kind == LinkKind.data) {
      _control.add(f.payload);
      for (var line = _control.next(); line != null; line = _control.next()) {
        _c.controlLine(line);
      }
    } else if (f.channel == 1 && f.kind == LinkKind.data) {
      _eventLines.add(f.payload);
      for (var line = _eventLines.next(); line != null; line = _eventLines.next()) {
        if (_jsonLine(line) case final row?) _events.add(row);
      }
    } else {
      _channels[f.channel]?._onFrame(f); // unknown or closed here: in-flight frames are dropped
    }
  }

  void _revoke() {
    _lostReason = revokedMessage;
    _c.close();
  }

  void _lost() {
    for (final ch in _channels.values.toList()) {
      ch._end(_lostReason, revoked: _lostReason == revokedMessage);
    }
    unawaited(_events.close());
    if (!_done.isCompleted) _done.complete();
  }
}

Map<String, dynamic>? _json(List<int> bytes) => _jsonLine(utf8.decode(bytes, allowMalformed: true));

Map<String, dynamic>? _jsonLine(String line) {
  try {
    return (jsonDecode(line) as Map?)?.cast<String, dynamic>();
  } on Object {
    return null;
  }
}

abstract interface class _Channel {
  int get id;
  bool get _isOpened;
  void _onFrame(LinkFrame f);
  void _end(String? reason, {bool revoked = false});
}

bool _sane(int cols, int rows) => cols >= 1 && cols <= 1000 && rows >= 1 && rows <= 1000;

/// OPENED's size; null when there is nothing more to do: a duplicate refusal, a repeat, or the channel ended.
(int, int)? _openedSize(Mux mux, _Channel ch, LinkFrame f) {
  final o = _json(f.payload) ?? const {};
  final error = o['error'];
  if (error == _duplicateOpen) return null; // a duplicate OPEN refused: this stream continues
  if (error == 'revoked') {
    ch._end(revokedMessage, revoked: true); // Revoked, not Disconnected, for this open
    mux._revoke();
    return null;
  }
  if (error != null) {
    ch._end('$error');
    return null;
  }
  if (ch._isOpened) return null;
  if ((o['cols'], o['rows']) case (final int cols, final int rows) when _sane(cols, rows)) return (cols, rows);
  mux._add(LinkFrame.json(LinkKind.close, ch.id, {'reason': 'closed'})); // the relay holds it open: free the slot
  ch._end('the relay sent a bad OPENED');
  return null;
}

class VtChannel implements _Channel {
  VtChannel._(this._mux, this.id);

  final Mux _mux;
  @override
  final int id;
  final _events = StreamController<VtEvent>(); // single-subscription: DATA in the same read as OPENED is kept
  final _opened = Completer<VtChannel>();
  int _unconsumed = 0; // delivered in this window, not yet consumed
  int _stale = 0; // delivered before the last RESYNC, not yet consumed: never credited
  int _pending = 0; // consumed, not yet credited

  Stream<VtEvent> get events => _events.stream;

  @override
  bool get _isOpened => _opened.isCompleted;

  /// The emulator consumed [bytes] of Data: CREDIT once caught up with what arrived, or per 16 KiB.
  /// The caller must report every Data event it received, in order, those before a Resync included: unreported
  /// pre-Resync bytes would absorb later consumption, no CREDIT would go out, and the relay closes the channel `stalled`.
  void consumed(int bytes) {
    if (_events.isClosed) return;
    final old = min(bytes, _stale);
    _stale -= old;
    bytes = min(bytes - old, _unconsumed);
    _unconsumed -= bytes;
    _pending += bytes;
    if (_pending > 0 && (_unconsumed == 0 || _pending >= _creditBatch)) {
      _mux._add(LinkFrame.credit(id, _pending));
      _pending = 0;
    }
  }

  /// Sends CLOSE; the relay does not answer it, and frames still in flight are dropped.
  Future<void> close() async {
    if (_mux._channels[id] != this) return;
    _mux._add(LinkFrame.json(LinkKind.close, id, {'reason': 'closed'}));
    _end(null);
  }

  @override
  void _onFrame(LinkFrame f) {
    switch (f.kind) {
      case LinkKind.opened:
        if (_openedSize(_mux, this, f) case (final cols, final rows)) {
          _events.add(Opened(cols, rows));
          _opened.complete(this);
        }
      case LinkKind.data:
        _unconsumed += f.payload.length;
        _events.add(Data(f.payload));
      case LinkKind.grid:
        final s = f.size!;
        if (!_sane(s.cols, s.rows)) {
          _mux._add(LinkFrame.json(LinkKind.close, id, {'reason': 'closed'}));
          return _end('the relay sent a bad GRID');
        }
        _events.add(Grid(s.cols, s.rows));
      case LinkKind.resync:
        _stale += _unconsumed;
        _unconsumed = 0;
        _pending = 0;
        _events.add(Resync());
      case LinkKind.close:
        _end('${(_json(f.payload) ?? const {})['reason'] ?? 'closed'}');
      case LinkKind.open || LinkKind.credit || LinkKind.resize || LinkKind.lead:
        break; // not sent to a watching phone
    }
  }

  /// Removes the channel; [reason] null for a phone close. Before OPENED the open fails with the reason instead.
  @override
  void _end(String? reason, {bool revoked = false}) {
    _mux._channels.remove(id);
    if (!_opened.isCompleted) {
      _opened.completeError(revoked ? Revoked() : ElisError(reason ?? 'closed'));
    } else if (reason != null) {
      _events.add(Closed(reason));
    }
    unawaited(_events.close());
  }
}

/// A claiming channel: the phone's input goes out as DATA within the relay's window, released by its CREDIT.
class ClaimChannel implements _Channel {
  ClaimChannel._(this._mux, this.id);

  final Mux _mux;
  @override
  final int id;
  final _events = StreamController<ClaimEvent>(); // single-subscription: LEAD in the same read as OPENED is kept
  final _opened = Completer<ClaimChannel>();
  final _queue = ListQueue<Uint8List>();
  int _queued = 0;
  int _headAt = 0; // bytes of _queue.first already sent
  int _unacked = 0;

  Stream<ClaimEvent> get events => _events.stream;

  @override
  bool get _isOpened => _opened.isCompleted;

  /// Queues [bytes] for the relay; false, sending nothing, when the channel ended or more than 1 MiB would wait.
  bool send(Uint8List bytes) {
    // what the window takes now does not wait (a non-empty queue means the window is spent)
    if (_events.isClosed || _queued + bytes.length - (_claimWindow - _unacked) > _claimQueueCap) return false;
    if (bytes.isEmpty) return true;
    _queue.add(Uint8List.fromList(bytes)); // the caller may reuse its buffer
    _queued += bytes.length;
    _pump();
    return true;
  }

  void resize(int cols, int rows) {
    if (!_events.isClosed) _mux._add(LinkFrame.resize(id, cols, rows));
  }

  /// Sends CLOSE; the relay does not answer it, and unsent input is dropped.
  Future<void> close() async {
    if (_mux._channels[id] != this) return;
    _mux._add(LinkFrame.json(LinkKind.close, id, {'reason': 'closed'}));
    _end(null);
  }

  void _pump() {
    while (_queue.isNotEmpty && _unacked < _claimWindow) {
      final head = _queue.first;
      final n = min(head.length - _headAt, _claimWindow - _unacked);
      _mux._add(LinkFrame(LinkKind.data, id, Uint8List.sublistView(head, _headAt, _headAt + n)));
      _unacked += n;
      _queued -= n;
      _headAt += n;
      if (_headAt == head.length) {
        _queue.removeFirst();
        _headAt = 0;
      }
    }
  }

  @override
  void _onFrame(LinkFrame f) {
    switch (f.kind) {
      case LinkKind.opened:
        if (_openedSize(_mux, this, f) == null) return;
        _opened.complete(this);
      case LinkKind.lead:
        _events.add(Lead('${(_json(f.payload) ?? const {})['role']}'));
      case LinkKind.credit:
        _unacked = max(0, _unacked - (f.creditBytes ?? 0));
        _pump();
      case LinkKind.close:
        _end('${(_json(f.payload) ?? const {})['reason'] ?? 'closed'}');
      case LinkKind.open || LinkKind.data || LinkKind.resize || LinkKind.grid || LinkKind.resync:
        break; // not sent on a claim channel
    }
  }

  @override
  void _end(String? reason, {bool revoked = false}) {
    _mux._channels.remove(id);
    _queue.clear();
    _queued = 0;
    if (!_opened.isCompleted) {
      _opened.completeError(revoked ? Revoked() : ElisError(reason ?? 'closed'));
    } else if (reason != null) {
      _events.add(ClaimClosed(reason));
    }
    unawaited(_events.close());
  }
}
