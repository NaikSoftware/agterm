import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/pages/page_link.dart';
import 'package:elis_mobile/pages/page_server.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(HttpClientResponse, String)> request(Uri uri, {String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final response = await (await client.openUrl(method, uri)).close();
    return (response, await utf8.decodeStream(response));
  } finally {
    client.close();
  }
}

Stream<List<int>> brokenFile() async* {
  yield utf8.encode('let a');
  throw ElisError('lost');
}

void main() {
  late List<String> fetched;
  late PageServer server;

  Future<void> start({required bool javascript}) async {
    fetched = [];
    server = await PageServer.start((path) async {
      fetched.add(path);
      if (path.endsWith('missing.css')) throw ElisError('not found');
      if (path.endsWith('broken.js')) return PageFile('text/javascript', brokenFile());
      return PageFile('text/html', Stream.value(utf8.encode('<p>hi</p>')));
    }, javascript: javascript);
  }

  tearDown(() => server.close());

  test('getWithTheSecretServesTheFetchedFile', () async {
    await start(javascript: true);
    final url = server.urlFor('/w/my page.html');
    expect(url.host, '127.0.0.1');
    final (response, body) = await request(url);
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'text/html');
    expect(response.headers.value('content-security-policy'), isNull);
    expect(body, '<p>hi</p>');
    expect(fetched, ['/w/my page.html']);
  });

  test('aWrongSecretIsRefusedWithoutAFetch', () async {
    await start(javascript: true);
    final url = server.urlFor('/w/index.html');
    final (response, _) = await request(url.replace(path: '/${'0' * 32}/w/index.html'));
    expect(response.statusCode, 404);
    final (bare, _) = await request(url.replace(path: '/w/index.html'));
    expect(bare.statusCode, 404);
    expect(fetched, isEmpty);
  });

  test('postIsRefused', () async {
    await start(javascript: true);
    final (response, _) = await request(server.urlFor('/w/index.html'), method: 'POST');
    expect(response.statusCode, 405);
    expect(fetched, isEmpty);
  });

  test('aFailedFetchIs404WithItsError', () async {
    await start(javascript: true);
    final (response, body) = await request(server.urlFor('/w/missing.css'));
    expect(response.statusCode, 404);
    expect(body, 'not found');
  });

  test('aFetchFailingMidFileAbortsTheConnection', () async {
    await start(javascript: true);
    await expectLater(request(server.urlFor('/w/broken.js')), throwsA(isA<HttpException>()));
  });

  test('withoutJavaScriptThePagesScriptsAreBlocked', () async {
    await start(javascript: false);
    final (response, _) = await request(server.urlFor('/w/index.html'));
    expect(response.headers.value('content-security-policy'), "script-src 'none'");
  });

  test('eachServerHasItsOwnSecret', () async {
    await start(javascript: true);
    final other = await PageServer.start((_) => throw ElisError('x'), javascript: true);
    expect(other.urlFor('/a').pathSegments.first, isNot(server.urlFor('/a').pathSegments.first));
    expect(server.urlFor('/a').pathSegments.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    await other.close();
  });
}
