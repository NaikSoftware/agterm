// The relay mux (control-api.md "Relay mux"): channel 0 carries the control lines, channel 1 the event rows,
// channels 2 and up one vt pane each, watched only (the phone never sends DATA or RESIZE on them).
import 'dart:async';
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

/// An event row saying rows were lost (`{"dropped":N}`, `{"gap":true}`): tree rows may be among them, so re-read `tree`.
bool rereadsTree(Map<String, dynamic> row) => row.containsKey('dropped') || row['gap'] == true;

const _creditBatch = 16 * 1024;
const _duplicateOpen = 'channel already open';

class Mux {
  Mux._(this._c);

  final Connection _c;
  final _decoder = LinkDecoder();
  final _control = LineBuffer();
  final _eventLines = LineBuffer();
  final _events = StreamController<Map<String, dynamic>>.broadcast(); // nobody may listen: rows are not kept
  final _channels = <int, VtChannel>{};
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

class VtChannel {
  VtChannel._(this._mux, this.id);

  final Mux _mux;
  final int id;
  final _events = StreamController<VtEvent>(); // single-subscription: DATA in the same read as OPENED is kept
  final _opened = Completer<VtChannel>();
  int _unconsumed = 0; // delivered in this window, not yet consumed
  int _stale = 0; // delivered before the last RESYNC, not yet consumed: never credited
  int _pending = 0; // consumed, not yet credited

  Stream<VtEvent> get events => _events.stream;

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

  void _onFrame(LinkFrame f) {
    switch (f.kind) {
      case LinkKind.opened:
        final o = _json(f.payload) ?? const {};
        final error = o['error'];
        if (error == _duplicateOpen) return; // a duplicate OPEN refused: this stream continues
        if (error == 'revoked') {
          _end(revokedMessage, revoked: true); // Revoked, not Disconnected, for this open
          return _mux._revoke();
        }
        if (error != null) return _end('$error');
        if (_opened.isCompleted) return;
        if ((o['cols'], o['rows']) case (final int cols, final int rows)) {
          _events.add(Opened(cols, rows));
        } else {
          _mux._add(LinkFrame.json(LinkKind.close, id, {'reason': 'closed'})); // the relay holds it open: free the slot
          return _end('the relay sent a bad OPENED');
        }
        _opened.complete(this);
      case LinkKind.data:
        _unconsumed += f.payload.length;
        _events.add(Data(f.payload));
      case LinkKind.grid:
        final s = f.size!;
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
