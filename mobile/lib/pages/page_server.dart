import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'page_link.dart';

/// Serves one sheet's file page to its WebView on 127.0.0.1; every GET under the secret becomes a fetch.
class PageServer {
  PageServer._(this._server, this._secret, this._fetch, this._javascript, this._head) {
    _server.listen((r) => unawaited(_serve(r)));
  }

  final HttpServer _server;
  final String _secret;
  final Future<PageFile> Function(String path) _fetch;
  final bool _javascript;
  final List<int>? _head;

  /// Without [javascript] the page's own scripts are blocked; the bridge adapter is injected by the WebView.
  /// [head] goes into every HTML document ahead of the page's own scripts, as the Mac's document-start scripts do.
  static Future<PageServer> start(Future<PageFile> Function(String path) fetch, {required bool javascript, String? head}) async =>
      PageServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), randomHex128(), fetch, javascript,
          head == null ? null : utf8.encode(head));

  /// [originPath] is absolute on the origin.
  Uri urlFor(String originPath) => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, path: '/$_secret$originPath');

  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments.first != _secret) {
        response.statusCode = HttpStatus.notFound;
      } else if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
      } else {
        final PageFile file;
        try {
          file = await _fetch('/${segments.skip(1).join('/')}');
        } on Object catch (e) {
          response
            ..statusCode = HttpStatus.notFound
            ..write('$e');
          return;
        }
        response.headers
          ..set(HttpHeaders.contentTypeHeader, file.mime)
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        if (!_javascript) response.headers.set('Content-Security-Policy', "script-src 'none'");
        final head = _head;
        await response.addStream(head != null && file.mime.startsWith('text/html') ? _withHead(file.bytes, head) : file.bytes);
      }
    } on Object {
      // the WebView went away, or the file failed mid-way and dart:io already broke the connection (a test covers it)
    } finally {
      await response.close().catchError((Object _) {});
    }
  }

  /// [bytes] with [head] after a leading doctype: anything before the doctype puts the page in quirks mode.
  static Stream<List<int>> _withHead(Stream<List<int>> bytes, List<int> head) async* {
    final start = <int>[];
    var placed = false;
    Iterable<List<int>> place() {
      placed = true;
      final at = _doctype.matchAsPrefix(latin1.decode(start))?.end ?? 0;
      return [start.sublist(0, at), head, start.sublist(at)];
    }

    await for (final chunk in bytes) {
      if (placed) {
        yield chunk;
        continue;
      }
      start.addAll(chunk);
      if (start.length >= 1024) yield* Stream.fromIterable(place());
    }
    if (!placed) yield* Stream.fromIterable(place());
  }

  // bytes as latin1 characters: a UTF-8 byte order mark is three of them
  static final _doctype = RegExp(r'(?:\xEF\xBB\xBF)?\s*<!doctype[^>]*>', caseSensitive: false);
}
