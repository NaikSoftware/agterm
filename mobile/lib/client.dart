// The wire to `elisctl mobile serve`: TLS pinned to the pairing's certificate fingerprint, or the Bluetooth link
// (ble_transport.dart), then elisctl's own {cmd, target, args} JSON lines, each tagged with an id the relay echoes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'ble_transport.dart';
import 'link/messages.dart';

class Pairing {
  Pairing({required this.name, this.host, this.port, required this.token, required this.fingerprint, this.bluetooth = false});

  final String name, token, fingerprint;
  final String? host; // null: Bluetooth only
  final int? port;
  final bool bluetooth;

  // the computer's identity: its certificate, wherever it is reached
  String get key => fingerprint;
  String get address => host == null ? 'Bluetooth' : '$host:$port';

  // elis://pair?h=HOST&p=PORT&t=TOKEN&f=SHA256HEX&n=NAME[&b=1], as `elisctl mobile serve` prints it;
  // h and p are optional with b=1
  static Pairing? parse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'elis' || uri.host != 'pair') return null;
    final q = uri.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    // with b=1 an unusable address leaves the pairing Bluetooth only
    final host = q['h']?.isNotEmpty == true && port != null && port >= 1 && port <= 65535 ? q['h'] : null;
    final bluetooth = q['b'] == '1';
    final fp = (q['f'] ?? '').toLowerCase();
    if (host == null && !bluetooth) return null;
    if ((q['t'] ?? '').length < 32 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) return null;
    return Pairing(
      name: q['n']?.isNotEmpty == true ? q['n']! : host ?? 'Computer',
      host: host,
      port: host == null ? null : port,
      token: q['t']!,
      fingerprint: fp,
      bluetooth: bluetooth,
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port, 'token': token, 'fingerprint': fingerprint, 'bluetooth': bluetooth};

  // entries saved before Bluetooth carry no `bluetooth`
  static Pairing fromJson(Map<String, dynamic> j) =>
      Pairing(name: j['name'], host: j['host'], port: j['port'], token: j['token'], fingerprint: j['fingerprint'], bluetooth: j['bluetooth'] == true);
}

class ElisError implements Exception {
  ElisError(this.message);
  final String message;
  @override
  String toString() => message;
}

const revokedMessage = 'The pairing was revoked. Pair this computer again.';

/// The token is no longer valid: no transport can succeed, so nothing retries.
class Revoked extends ElisError {
  Revoked() : super(revokedMessage);
}

String certificateFingerprint(X509Certificate c) => sha256.convert(c.der).toString();

/// A byte pipe to the relay: the TLS socket, or the Bluetooth L2CAP channel (raw, or plaintext after the handshake).
class Link {
  Link(this.input, this.add, this.close, {required this.via});
  final Stream<List<int>> input;
  final void Function(List<int> bytes) add;
  final void Function() close;
  final String via; // the badge: 'Wi-Fi' or 'BT'
}

typedef TlsOpener = Future<Link> Function(Pairing p, Duration timeout);
typedef BleOpener = Future<Link> Function(Pairing p);

Future<Link> openTls(Pairing p, Duration timeout) async {
  SecureSocket? socket;
  final pending = SecureSocket.connect(
    p.host,
    p.port!,
    context: SecurityContext(withTrustedRoots: false), // trust nothing but the pinned certificate
    onBadCertificate: (c) => certificateFingerprint(c) == p.fingerprint,
    timeout: timeout,
  );
  try {
    // connect's own timeout covers TCP only, not the TLS handshake
    socket = await pending.timeout(timeout);
  } on HandshakeException {
    throw ElisError('The computer presented a different certificate. Pair it again.');
  } on TimeoutException {
    unawaited(pending.then((s) => s.destroy(), onError: (_) {}));
    rethrow;
  }
  final peer = socket.peerCertificate;
  if (peer == null || certificateFingerprint(peer) != p.fingerprint) {
    socket.destroy();
    throw ElisError('The computer presented a different certificate. Pair it again.');
  }
  return Link(socket, socket.add, socket.destroy, via: 'Wi-Fi');
}

// a definite answer (revoked, certificate, busy) beats "not found", which beats "cannot reach"
int _rank(Object? e) => switch (e) {
  null => -1,
  ElisError() => 2,
  BleNotFound() => 1,
  _ => 0,
};

class Connection {
  Connection._(this._link) {
    // raw bytes, split here: after the mux upgrade answer the rest of the stream is frames
    _link.input.listen(_onBytes, onDone: _onDone, onError: (_) => _onDone());
  }

  final Link _link;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _closed = Completer<void>();
  int _next = 1;
  final _lines = LineBuffer();
  void Function(List<int> bytes)? _frames; // set once upgraded: every input byte goes to the mux
  void Function(List<int> line)? _sendLine; // set once upgraded: request lines go out on channel 0
  void Function(bool upgraded)? _onUpgradeAnswer; // set while the upgrade waits, and after a timeout
  Future<void>? _upgrading;

  Future<void> get closed => _closed.future;
  String get via => _link.via;

  /// TLS when the pairing has an address, Bluetooth when it offers it; [preferBluetooth] flips the order.
  static Future<Connection> open(Pairing p, {bool preferBluetooth = false, TlsOpener tls = openTls, BleOpener ble = openBle}) async {
    final tlsTimeout = Duration(seconds: p.bluetooth ? 3 : 8); // short only when Bluetooth is there to fall back on
    final tries = [if (p.host != null) () => tls(p, tlsTimeout), if (p.bluetooth) () => ble(p)];
    Object? error;
    for (final t in preferBluetooth ? tries.reversed : tries) {
      try {
        return await _authenticate(await t(), p);
      } on Revoked {
        rethrow;
      } catch (e) {
        if (_rank(e) > _rank(error)) error = e;
      }
    }
    throw error ?? ElisError('This pairing has neither an address nor Bluetooth. Pair the computer again.');
  }

  static Future<Connection> _authenticate(Link link, Pairing p) async {
    final c = Connection._(link);
    try {
      final hello = await c._send({'auth': p.token}).timeout(const Duration(seconds: 8));
      if (hello['ok'] != true) throw hello['error'] == 'unauthorized' ? Revoked() : ElisError('${hello['error']}');
      return c;
    } catch (_) {
      c.close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> request) {
    if (_closed.isCompleted) return Future.error(ElisError('Disconnected'));
    final id = _next++;
    final done = Completer<Map<String, dynamic>>();
    _pending[id] = done;
    final line = utf8.encode('${jsonEncode({...request, 'id': id})}\n');
    (_sendLine ?? _link.add)(line);
    return done.future;
  }

  /// The mux seam (link/mux.dart). Sends the upgrade request; on its answer every later input byte, those read past the
  /// answer line included, goes to [frames], and request lines go to [sendLine]. False when the link ended or no answer
  /// came within [timeout], or a relay before M4a answered `{"id":null,…}`: the line protocol stays. Calls made meanwhile
  /// wait for the outcome.
  Future<bool> switchToFrames(Duration timeout, {required void Function(List<int>) frames, required void Function(List<int>) sendLine}) async {
    if (_closed.isCompleted || _upgrading != null || _frames != null) return false;
    final answered = Completer<bool>();
    final gate = Completer<void>();
    _upgrading = gate.future;
    _onUpgradeAnswer = (upgraded) {
      if (upgraded) {
        _frames = frames;
        _sendLine = sendLine;
      }
      answered.complete(upgraded);
    };
    _link.add(utf8.encode(linkUpgradeRequest));
    try {
      return await Future.any([answered.future, _closed.future.then((_) => false)]).timeout(timeout, onTimeout: () => false);
    } finally {
      // a late answer means the relay speaks frames, which the line protocol cannot read
      if (_frames == null && _onUpgradeAnswer != null) {
        _onUpgradeAnswer = (upgraded) {
          if (upgraded) close();
        };
      }
      _upgrading = null;
      gate.complete();
    }
  }

  /// The mux seam: raw bytes to the relay.
  void addBytes(List<int> bytes) {
    if (!_closed.isCompleted) _link.add(bytes);
  }

  /// The mux seam: one channel-0 line from the relay.
  void controlLine(String line) {
    if (_decode(line) case final o?) _answer(o);
  }

  /// One control command; the result object, or ElisError with the app's message.
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, String? window}) async {
    final a = {...?args, 'window': ?window};
    if (_upgrading case final u?) await u;
    final id = _next;
    final r = await _send({'cmd': cmd, 'target': ?target, if (a.isNotEmpty) 'args': a}).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('no answer to $cmd');
      },
    );
    if (r['ok'] != true) throw ElisError('${r['error'] ?? 'request failed'}');
    return (r['result'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  void _onBytes(List<int> bytes) {
    if (_closed.isCompleted) return;
    if (_frames case final f?) return f(bytes);
    _lines.add(bytes);
    for (var line = _lines.next(); line != null; line = _lines.next()) {
      final o = _decode(line);
      if (o == null) continue;
      if (_onUpgradeAnswer case final on?) {
        if (isLinkUpgradeReply(o)) {
          _onUpgradeAnswer = null;
          on(true);
          final rest = _lines.takeRest();
          if (_frames case final f? when rest.isNotEmpty) f(rest);
          return;
        }
        if (o.containsKey('id') && o['id'] == null) {
          // a relay before M4a ran {"mux":1} as a command: no mux, at once
          _onUpgradeAnswer = null;
          on(false);
          continue;
        }
      }
      _answer(o);
    }
  }

  static Map<String, dynamic>? _decode(String line) {
    try {
      final o = jsonDecode(line);
      return o is Map ? o.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  void _answer(Map<String, dynamic> o) => _pending.remove(o['id'])?.complete(o);

  void _onDone() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final p in _pending.values) {
      p.completeError(ElisError('Disconnected'));
    }
    _pending.clear();
  }

  void close() {
    _link.close();
    _onDone();
  }
}
