import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../link/mux.dart';
import 'page_link.dart';

/// Carries a sheet's WebView connections to a loopback page on the origin, one `forward` channel each.
/// Any app or site on the phone can reach 127.0.0.1, so a connection gets a channel only when its first request
/// carries the sheet's cookie.
class PageTunnel {
  PageTunnel._(this._server, this._open, this._cookie, this._headerTimeout) {
    _server.listen(_accept);
  }

  final ServerSocket _server;
  final ForwardChannel Function() _open;
  final String _cookie;
  final Duration _headerTimeout;
  final _drops = <Socket, void Function()>{};

  static const maxHeaderBytes = 16 * 1024;

  /// Binds 127.0.0.1:[preferredPort], else 127.0.0.1:0. [cookie] is `name=value` the first request must carry.
  static Future<PageTunnel> start(ForwardChannel Function() open,
      {required int preferredPort, required String cookie, Duration headerTimeout = const Duration(seconds: 5)}) async {
    ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferredPort);
    } on SocketException {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    return PageTunnel._(server, open, cookie, headerTimeout);
  }

  static String newCookie(int port) => 'elis_tunnel_$port=${randomHex128()}';

  int get port => _server.port;

  Uri urlFor(Uri original) => original.replace(scheme: 'http', host: '127.0.0.1', port: port);

  /// Accepted sockets still open, those waiting at the gate included.
  int get connections => _drops.length;

  /// Closes the listener, every socket and every channel.
  Future<void> close() async {
    await _server.close();
    for (final drop in _drops.values.toList()) {
      drop();
    }
  }

  void _accept(Socket socket) {
    final head = <int>[];
    ForwardChannel? channel;
    late final StreamSubscription<Uint8List> reads;
    late final Timer gate;
    void drop() {
      if (_drops.remove(socket) == null) return;
      gate.cancel();
      unawaited(reads.cancel());
      socket.destroy();
      unawaited(channel?.close());
    }

    _drops[socket] = drop;
    gate = Timer(_headerTimeout, drop);
    reads = socket.listen((bytes) {
      if (channel case final ch?) {
        // shortcut: a client that outruns the relay by 1 MiB is dropped; pause reads on a full queue if uploads need it
        if (!ch.send(bytes)) drop();
        return;
      }
      head.addAll(bytes);
      final end = _headEnd(head);
      if (end == null) {
        if (head.length >= maxHeaderBytes) drop();
        return;
      }
      if (end > maxHeaderBytes || !_carriesCookie(latin1.decode(head.sublist(0, end)))) return drop();
      gate.cancel();
      final ch = channel = _open();
      ch.send(Uint8List.fromList(head));
      head.clear();
      unawaited(ch.opened.catchError((Object _) => drop()));
      unawaited(socket.addStream(ch.bytes).then((_) => socket.close()).catchError((Object _) {}).whenComplete(drop));
    }, onError: (Object _) => drop(), onDone: () => channel == null ? drop() : unawaited(channel?.close()));
  }

  /// Every header line must parse; any doubt closes the connection.
  bool _carriesCookie(String head) {
    var found = false;
    for (final line in head.split('\r\n').skip(1).where((l) => l.isNotEmpty)) {
      final colon = line.indexOf(':');
      if (colon <= 0) return false;
      if (line.substring(0, colon).trim().toLowerCase() != 'cookie') continue;
      found = found || line.substring(colon + 1).split(';').any((pair) => pair.trim() == _cookie);
    }
    return found;
  }
}

/// The length of the head through its blank line, or null while it is not complete.
int? _headEnd(List<int> b) {
  for (var i = 3; i < b.length; i++) {
    if (b[i] == 10 && b[i - 1] == 13 && b[i - 2] == 10 && b[i - 3] == 13) return i + 1;
  }
  return null;
}
