import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'page_link.dart';

/// Serves one sheet's file page to its WebView on 127.0.0.1; every GET under the secret becomes a fetch.
class PageServer {
  PageServer._(this._server, this._secret, this._fetch, this._javascript) {
    _server.listen((r) => unawaited(_serve(r)));
  }

  final HttpServer _server;
  final String _secret;
  final Future<PageFile> Function(String path) _fetch;
  final bool _javascript;

  /// Without [javascript] the page's own scripts are blocked; the bridge adapter is injected by the WebView.
  static Future<PageServer> start(Future<PageFile> Function(String path) fetch, {required bool javascript}) async {
    final random = Random.secure();
    final secret = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    return PageServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), secret, fetch, javascript);
  }

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
        await response.addStream(file.bytes);
      }
    } on Object {
      // the WebView went away or the fetch failed mid-file: the response just ends
    } finally {
      await response.close().catchError((Object _) {});
    }
  }
}
