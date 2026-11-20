import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/mux.dart';
import 'package:elis_mobile/pages/page_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

/// A forward channel; with [window] it holds input past that many unreleased bytes, as the relay's credit does.
class FakeForward implements ForwardChannel {
  FakeForward({this.window});

  final int? window;
  final _opened = Completer<void>();
  final _bytes = StreamController<Uint8List>();
  final sent = <int>[];
  final _changed = StreamController<void>.broadcast();
  final _closed = Completer<bool>();
  Completer<void>? _backlog;
  var _unreleased = 0;
  var refusedSend = false;
  bool? flushed;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<Uint8List> get bytes => _bytes.stream;

  @override
  Future<void>? get backlog => _backlog?.future;

  bool get closed => _closed.isCompleted;

  @override
  bool send(Uint8List bytes) {
    // stricter than the relay's 1 MiB queue: a tunnel that keeps reading while backlogged fails at once
    if (_backlog != null || _unreleased > 1 << 20) {
      refusedSend = true;
      return false;
    }
    sent.addAll(bytes);
    _unreleased += bytes.length;
    if (window case final w? when _unreleased > w) _backlog ??= Completer<void>();
    _changed.add(null);
    return true;
  }

  /// The relay took everything sent so far.
  void release() {
    _unreleased = 0;
    _backlog?.complete();
    _backlog = null;
  }

  @override
  Future<void> close({bool flush = true}) async {
    flushed ??= flush;
    if (!_closed.isCompleted) _closed.complete(flush);
    _changed.add(null);
    await _bytes.close();
  }

  void accept() => _opened.complete();

  void refuse(String reason) {
    _opened.completeError(ElisError(reason));
    unawaited(_bytes.close());
  }

  void reply(List<int> b) => _bytes.add(Uint8List.fromList(b));

  Future<void> until(int length) async {
    while (sent.length < length && !closed) {
      await _changed.stream.first;
    }
  }

  Future<void> get whenClosed => _closed.future;

  Future<void> get whenBacklogged async {
    while (_backlog == null) {
      await _changed.stream.first;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A client connection that records what it reads.
class Client {
  Client._(this.socket) {
    socket.listen((b) {
      got.addAll(b);
      _changed.add(null);
    }, onError: (Object _) => _end(), onDone: _end);
    unawaited(socket.done.catchError((Object _) {})); // the tunnel may reset while a request is still going out
  }

  static Future<Client> connect(int port) async => Client._(await Socket.connect(InternetAddress.loopbackIPv4, port));

  final Socket socket;
  final got = <int>[];
  final _changed = StreamController<void>.broadcast();
  final _ended = Completer<void>();

  void _end() {
    if (!_ended.isCompleted) _ended.complete();
    _changed.add(null);
  }

  /// Everything read once the tunnel ends the connection.
  Future<String> get ended async {
    await _ended.future;
    return latin1.decode(got);
  }

  Future<void> until(int length) async {
    while (got.length < length && !_ended.isCompleted) {
      await _changed.stream.first;
    }
  }
}

void main() {
  late StreamController<FakeForward> opens;
  late StreamIterator<FakeForward> nextOpen;
  late List<FakeForward> opened;
  late PageTunnel tunnel;
  int? window;

  Future<void> start({int preferredPort = 0, Duration headerTimeout = const Duration(seconds: 5)}) async {
    opened = [];
    opens = StreamController<FakeForward>();
    nextOpen = StreamIterator(opens.stream);
    tunnel = await PageTunnel.start(() {
      final f = FakeForward(window: window);
      opened.add(f);
      opens.add(f);
      return f;
    }, preferredPort: preferredPort, headerTimeout: headerTimeout);
  }

  Future<FakeForward> next() async {
    expect(await nextOpen.moveNext(), isTrue);
    return nextOpen.current;
  }

  setUp(() => window = null);
  tearDown(() => tunnel.close());

  Future<Client> client() => Client.connect(tunnel.port);

  String get(String path, {String? cookies, String extra = ''}) =>
      'GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\n${extra}Cookie: ${cookies ?? tunnel.cookie}\r\n\r\n';

  test('bytesGoBothWays', () async {
    await start();
    final c = await client();
    final request = '${get('/a')}body';
    c.socket.write(request);
    final f = await next();
    await f.until(request.length);
    expect(utf8.decode(f.sent), request);
    f
      ..accept()
      ..reply(utf8.encode('HTTP/1.1 200 OK\r\n\r\nhi'));
    await f.close();
    expect(await c.ended, 'HTTP/1.1 200 OK\r\n\r\nhi');
  });

  test('theClientsEndClosesTheChannel', () async {
    await start();
    final c = await client();
    c.socket.write(get('/'));
    final f = await next();
    await c.socket.close();
    await f.whenClosed;
    c.socket.destroy();
  });

  test('aRefusedChannelClosesTheSocket', () async {
    await start();
    final c = await client();
    c.socket.write(get('/'));
    (await next()).refuse('no such page');
    expect(await c.ended, isEmpty);
  });

  test('closeEndsEverySocketAndClosesItsChannelsAtOnce', () async {
    await start();
    final a = await client();
    final b = await client();
    a.socket.write(get('/a'));
    b.socket.write(get('/b'));
    await next();
    await next();
    expect(tunnel.connections, 2);
    await tunnel.close();
    await Future.wait([a.ended, b.ended]);
    expect(tunnel.connections, 0);
    expect(opened.map((f) => f.flushed), [false, false]);
  });

  test('anUploadPastTheQueueCapWaitsForTheRelay', () async {
    window = 64 * 1024;
    await start();
    final c = await client();
    final head = get('/upload', extra: 'Content-Length: ${2 << 20}\r\n');
    final body = Uint8List.fromList([for (var i = 0; i < 2 << 20; i++) i % 251]);
    c.socket.write(head);
    final f = await next();
    f.accept();
    c.socket.add(body);
    final total = head.length + body.length;
    while (f.sent.length < total && !f.closed) {
      await Future.any([f.whenBacklogged, f.until(total)]);
      await Future<void>.delayed(const Duration(milliseconds: 5)); // a slow relay: the client's next bytes are already here
      f.release();
    }
    expect(f.refusedSend, isFalse);
    expect(f.closed, isFalse);
    expect(f.sent.sublist(head.length), body);
    c.socket.destroy();
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
    Future<void> refused(String Function() request, {Duration headerTimeout = const Duration(seconds: 5)}) async {
      await start(headerTimeout: headerTimeout);
      final c = await client();
      c.socket.add(latin1.encode(request()));
      expect(await c.ended.timeout(const Duration(seconds: 30)), isEmpty);
      expect(opened, isEmpty);
    }

    test('noCookieClosesTheSocket', () => refused(() => 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'));

    test('aWrongCookieClosesTheSocket', () => refused(() => get('/', cookies: '${tunnel.cookie.substring(0, tunnel.cookie.length - 1)}0')));

    test('aCookieValuePrefixClosesTheSocket', () => refused(() => get('/', cookies: '${tunnel.cookie}x')));

    test('headersOver16KiBCloseTheSocket', () => refused(() => get('/', extra: 'X-Pad: ${'a' * PageTunnel.maxHeaderBytes}\r\n')));

    test('headersNotFinishedBeforeTheTimeoutCloseTheSocket',
        () => refused(() => 'GET / HTTP/1.1\r\nCookie: ${tunnel.cookie}\r\n', headerTimeout: const Duration(milliseconds: 200)));

    test('aWebSocketUpgradeWithTheCookiePasses', () async {
      await start();
      final c = await client();
      final request = 'GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\ncookie: theme=dark; ${tunnel.cookie}; other=1\r\n\r\n';
      c.socket.write(request);
      final f = await next();
      await f.until(request.length);
      expect(utf8.decode(f.sent), request);
      f.accept();
      final reply = [...utf8.encode('HTTP/1.1 101 Switching Protocols\r\n\r\n'), 0x81, 0x02, 0x68, 0x69];
      f.reply(reply);
      c.socket.add([0x81, 0x82, 0, 0, 0, 0, 0x68, 0x69]);
      await f.until(request.length + 8);
      expect(f.sent.sublist(request.length), [0x81, 0x82, 0, 0, 0, 0, 0x68, 0x69]);
      await c.until(reply.length);
      expect(c.got, reply);
      c.socket.destroy();
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
      expect(tunnel.cookie, startsWith('elis_tunnel_$free='));
    });

    test('aBusyPreferredPortFallsBackToARandomOneAndTheCookieNamesIt', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await start(preferredPort: busy.port);
      expect(tunnel.port, isNot(busy.port));
      expect(tunnel.cookie, matches(RegExp('^elis_tunnel_${tunnel.port}=[0-9a-f]{32}\$')));
      await busy.close();
    });

    test('twoTunnelsOnOnePreferredPortGetDistinctCookieNames', () async {
      await start();
      final first = tunnel;
      final second = await PageTunnel.start(FakeForward.new, preferredPort: first.port);
      expect(second.cookie.split('=').first, isNot(first.cookie.split('=').first));
      await second.close();
    });
  });
}
