// The wire to `agtermctl mobile serve`: TLS pinned to the pairing's certificate fingerprint, then agtermctl's own
// {cmd, target, args} JSON lines, each tagged with an id the relay echoes on its answer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class Pairing {
  Pairing({required this.name, required this.host, required this.port, required this.token, required this.fingerprint});

  final String name, host, token, fingerprint;
  final int port;

  String get key => '$host:$port';

  // agterm://pair?h=HOST&p=PORT&t=TOKEN&f=SHA256HEX&n=NAME, as `agtermctl mobile serve` prints it
  static Pairing? parse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'agterm' || uri.host != 'pair') return null;
    final q = uri.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    final fp = (q['f'] ?? '').toLowerCase();
    if ((q['h'] ?? '').isEmpty || port == null || port < 1 || port > 65535) return null;
    if ((q['t'] ?? '').length < 32 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) return null;
    return Pairing(name: q['n']?.isNotEmpty == true ? q['n']! : q['h']!, host: q['h']!, port: port, token: q['t']!, fingerprint: fp);
  }

  Pairing copyWith({String? name, String? host}) =>
      Pairing(name: name ?? this.name, host: host ?? this.host, port: port, token: token, fingerprint: fingerprint);

  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port, 'token': token, 'fingerprint': fingerprint};

  static Pairing fromJson(Map<String, dynamic> j) =>
      Pairing(name: j['name'], host: j['host'], port: j['port'], token: j['token'], fingerprint: j['fingerprint']);
}

class AgtermError implements Exception {
  AgtermError(this.message);
  final String message;
  @override
  String toString() => message;
}

String certificateFingerprint(X509Certificate c) => sha256.convert(c.der).toString();

class Connection {
  Connection._(this._socket) {
    _socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine, onDone: _onDone, onError: (_) => _onDone());
  }

  final SecureSocket _socket;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _closed = Completer<void>();
  int _next = 1;

  Future<void> get closed => _closed.future;

  static Future<Connection> open(Pairing p, {Duration timeout = const Duration(seconds: 8)}) async {
    SecureSocket? socket;
    final pending = SecureSocket.connect(p.host, p.port,
        context: SecurityContext(withTrustedRoots: false), // trust nothing but the pinned certificate
        onBadCertificate: (c) => certificateFingerprint(c) == p.fingerprint,
        timeout: timeout);
    try {
      // connect's own timeout covers TCP only, not the TLS handshake
      socket = await pending.timeout(timeout);
    } on HandshakeException {
      throw AgtermError('The computer presented a different certificate. Pair it again.');
    } on TimeoutException {
      unawaited(pending.then((s) => s.destroy(), onError: (_) {}));
      rethrow;
    }
    final peer = socket.peerCertificate;
    if (peer == null || certificateFingerprint(peer) != p.fingerprint) {
      socket.destroy();
      throw AgtermError('The computer presented a different certificate. Pair it again.');
    }
    final c = Connection._(socket);
    try {
      final hello = await c._send({'auth': p.token}).timeout(timeout);
      if (hello['ok'] != true) {
        throw AgtermError(hello['error'] == 'unauthorized' ? 'The pairing was revoked. Pair this computer again.' : '${hello['error']}');
      }
      return c;
    } catch (_) {
      c.close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> request) {
    if (_closed.isCompleted) return Future.error(AgtermError('Disconnected'));
    final id = _next++;
    final done = Completer<Map<String, dynamic>>();
    _pending[id] = done;
    _socket.write('${jsonEncode({...request, 'id': id})}\n');
    return done.future;
  }

  /// One control command; the result object, or AgtermError with the app's message.
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, String? window}) async {
    final a = {...?args, 'window': ?window};
    final id = _next;
    final r = await _send({'cmd': cmd, 'target': ?target, if (a.isNotEmpty) 'args': a}).timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('no answer to $cmd');
    });
    if (r['ok'] != true) throw AgtermError('${r['error'] ?? 'request failed'}');
    return (r['result'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  void _onLine(String line) {
    final Object? o;
    try {
      o = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (o is! Map) return;
    _pending.remove(o['id'])?.complete(o.cast<String, dynamic>());
  }

  void _onDone() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final p in _pending.values) {
      p.completeError(AgtermError('Disconnected'));
    }
    _pending.clear();
  }

  void close() {
    _socket.destroy();
    _onDone();
  }
}
