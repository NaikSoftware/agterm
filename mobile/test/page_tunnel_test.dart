import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/mux.dart';
import 'package:elis_mobile/pages/page_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeForward implements ForwardChannel {
  final _opened = Completer<void>();
  final _bytes = StreamController<Uint8List>();
  final sent = <int>[];
  final _sentSome = StreamController<void>.broadcast();
  var closed = false;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<Uint8List> get bytes => _bytes.stream;

  @override
  bool send(Uint8List bytes) {
    sent.addAll(bytes);
    _sentSome.add(null);
    return true;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _bytes.close();
  }

  void accept() => _opened.complete();

  void refuse(String reason) {
    _opened.completeError(ElisError(reason));
    unawaited(_bytes.close());
  }

  void reply(String s) => _bytes.add(Uint8List.fromList(utf8.encode(s)));

  Future<void> until(int length) async {
    while (sent.length < length) {
      await _sentSome.stream.first;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const cookie = 'elis_tunnel_5173=00112233445566778899aabbccddeeff';

/// Everything the client reads until the tunnel ends the connection.
Future<String> readAll(Socket s) async {
  final got = <int>[];
  try {
    await s.forEach(got.addAll);
  } on SocketException {
    // a reset is an end too
  }
  return utf8.decode(got, allowMalformed: true);
}

void main() {
  late List<FakeForward> opened;
  late PageTunnel tunnel;

  Future<void> start({int preferredPort = 0, Duration headerTimeout = const Duration(seconds: 5)}) async {
    opened = [];
    tunnel = await PageTunnel.start(() {
      final f = FakeForward();
      opened.add(f);
      return f;
    }, preferredPort: preferredPort, cookie: cookie, headerTimeout: headerTimeout);
  }

  tearDown(() => tunnel.close());

  Future<Socket> client() => Socket.connect(InternetAddress.loopbackIPv4, tunnel.port);

  String get(String path, {String cookies = cookie, String extra = ''}) =>
      'GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\n${extra}Cookie: $cookies\r\n\r\n';

  test('bytesGoBothWays', () async {
    await start();
    final s = await client();
    final read = readAll(s);
    final request = '${get('/a')}body';
    s.write(request);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final f = opened.single;
    await f.until(request.length);
    expect(utf8.decode(f.sent), request);
    f.accept();
    f.reply('HTTP/1.1 200 OK\r\n\r\nhi');
    await f.close();
    expect(await read, 'HTTP/1.1 200 OK\r\n\r\nhi');
  });

  test('theClientsEndClosesTheChannel', () async {
    await start();
    final s = await client();
    s.write(get('/'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await s.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(opened.single.closed, isTrue);
    s.destroy();
  });

  test('aRefusedChannelClosesTheSocket', () async {
    await start();
    final s = await client();
    final read = readAll(s);
    s.write(get('/'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    opened.single.refuse('no such page');
    expect(await read, isEmpty);
  });

  test('closeEndsEverySocket', () async {
    await start();
    final a = await client();
    final b = await client();
    final reads = [readAll(a), readAll(b)];
    a.write(get('/a'));
    b.write(get('/b'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tunnel.connections, 2);
    await tunnel.close();
    await Future.wait(reads);
    expect(tunnel.connections, 0);
    expect(opened.every((f) => f.closed), isTrue);
  });

  test('urlForKeepsPathQueryAndFragment', () async {
    await start();
    expect(tunnel.urlFor(Uri.parse('http://localhost:5173/a?b#c')), Uri.parse('http://127.0.0.1:${tunnel.port}/a?b#c'));
  });

  test('newCookieNamesThePortAndCarries128Bits', () {
    final c = PageTunnel.newCookie(5173);
    expect(c, matches(RegExp(r'^elis_tunnel_5173=[0-9a-f]{32}$')));
    expect(PageTunnel.newCookie(5173), isNot(c));
  });

  group('gate', () {
    Future<void> refused(String request, {Duration headerTimeout = const Duration(seconds: 5)}) async {
      await start(headerTimeout: headerTimeout);
      final s = await client();
      final read = readAll(s);
      unawaited(s.done.catchError((Object _) {})); // the tunnel may reset while the request is still going out
      s.add(latin1.encode(request));
      expect(await read.timeout(const Duration(seconds: 3)), isEmpty);
      expect(opened, isEmpty);
    }

    test('noCookieClosesTheSocket', () => refused('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'));

    test('aWrongCookieClosesTheSocket', () => refused(get('/', cookies: 'elis_tunnel_5173=00112233445566778899aabbccddeefe')));

    test('aCookieValuePrefixClosesTheSocket', () => refused(get('/', cookies: 'elis_tunnel_5173=00112233445566778899aabbccddeeffx')));

    test('headersOver16KiBCloseTheSocket', () => refused(get('/', extra: 'X-Pad: ${'a' * PageTunnel.maxHeaderBytes}\r\n')));

    test('headersNotFinishedBeforeTheTimeoutCloseTheSocket',
        () => refused('GET / HTTP/1.1\r\nCookie: $cookie\r\n', headerTimeout: const Duration(milliseconds: 200)));

    test('aWebSocketUpgradeWithTheCookiePasses', () async {
      await start();
      final s = await client();
      final got = <int>[];
      s.listen(got.addAll);
      final request = 'GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\ncookie: theme=dark; $cookie; other=1\r\n\r\n';
      s.write(request);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final f = opened.single;
      await f.until(request.length);
      expect(utf8.decode(f.sent), request);
      f.accept();
      f.reply('HTTP/1.1 101 Switching Protocols\r\n\r\n\x81\x02hi');
      s.add([0x81, 0x82, 0, 0, 0, 0, 0x68, 0x69]);
      await f.until(request.length + 8);
      expect(f.sent.sublist(request.length), [0x81, 0x82, 0, 0, 0, 0, 0x68, 0x69]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(utf8.decode(got), 'HTTP/1.1 101 Switching Protocols\r\n\r\n\x81\x02hi');
      s.destroy();
    });

    test('aRequestAfterCloseIsRefused', () async {
      await start();
      final port = tunnel.port;
      await tunnel.close();
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
    });
  });

  group('port', () {
    test('thePreferredPortIsUsedWhenFree', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final free = probe.port;
      await probe.close();
      await start(preferredPort: free);
      expect(tunnel.port, free);
    });

    test('aBusyPreferredPortFallsBackToARandomOne', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await start(preferredPort: busy.port);
      expect(tunnel.port, isNot(busy.port));
      expect(tunnel.port, greaterThan(0));
      await busy.close();
    });
  });
}
