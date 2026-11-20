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
  PageTunnel._(this._server, this._open, this._headerTimeout) : port = _server.port, cookie = newCookie(_server.port) {
    _server.listen(_accept);
  }

  final ServerSocket _server;
  final ForwardChannel Function() _open;

  /// `name=value` the first request must carry; the name carries the bound port, so two tunnels never share it.
  final String cookie;
  final Duration _headerTimeout;
  final _drops = <Socket, void Function()>{};

  /// Listeners closing, by port: a page sent again mounts its new sheet before the old one disposes.
  static final _closing = <int, Future<void>>{};

  static const maxHeaderBytes = 16 * 1024;

  /// Binds 127.0.0.1:[preferredPort], else 127.0.0.1:0.
  static Future<PageTunnel> start(ForwardChannel Function() open,
      {required int preferredPort, Duration headerTimeout = const Duration(seconds: 5)}) async {
    await Future<void>.value(); // lets a sheet replaced in this frame start closing first
    await _closing[preferredPort];
    ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferredPort);
    } on SocketException {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    return PageTunnel._(server, open, headerTimeout);
  }

  static String newCookie(int port) => 'elis_tunnel_$port=${randomHex128()}';

  final int port;

  Uri urlFor(Uri original) => original.replace(scheme: 'http', host: '127.0.0.1', port: port);

  /// Accepted sockets still open, those waiting at the gate included.
  int get connections => _drops.length;

  /// Closes the listener, every socket and every channel.
  Future<void> close() async {
    final closed = _server.close();
    final done = _closing[port] = closed.then((_) {}, onError: (Object _) {});
    unawaited(done.whenComplete(() {
      if (_closing[port] == done) _closing.remove(port);
    }));
    await closed;
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
      unawaited(channel?.close(flush: false));
    }

    // reads pause while the relay holds sent bytes, so a fast client cannot overflow the channel's queue
    void carry(ForwardChannel ch, Uint8List bytes) {
      if (!ch.send(bytes)) return drop();
      if (ch.backlog case final waiting?) {
        reads.pause();
        unawaited(waiting.whenComplete(reads.resume));
      }
    }

    _drops[socket] = drop;
    gate = Timer(_headerTimeout, drop);
    reads = socket.listen((bytes) {
      if (channel case final ch?) return carry(ch, bytes);
      head.addAll(bytes);
      final end = _headEnd(head);
      if (end == null) {
        if (head.length >= maxHeaderBytes) drop();
        return;
      }
      if (end > maxHeaderBytes || !_carriesCookie(latin1.decode(head.sublist(0, end)))) return drop();
      gate.cancel();
      final ch = channel = _open();
      unawaited(ch.opened.catchError((Object _) => drop()));
      unawaited(socket.addStream(ch.bytes).then((_) => socket.close()).catchError((Object _) {}).whenComplete(drop));
      carry(ch, Uint8List.fromList(head));
      head.clear();
      // a client's end closes the channel: WebView clients do not half-close, so a reply still due is not awaited
    }, onError: (Object _) => drop(), onDone: () => channel == null ? drop() : unawaited(channel?.close()));
  }

  /// Every header line must parse; any doubt closes the connection.
  bool _carriesCookie(String head) {
    var found = false;
    for (final line in head.split('\r\n').skip(1).where((l) => l.isNotEmpty)) {
      final colon = line.indexOf(':');
      if (colon <= 0) return false;
      if (line.substring(0, colon).trim().toLowerCase() != 'cookie') continue;
      found = found || line.substring(colon + 1).split(';').any((pair) => pair.trim() == cookie);
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
