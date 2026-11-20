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

  Future<void> start({required bool javascript, String? head}) async {
    fetched = [];
    server = await PageServer.start((path) async {
      fetched.add(path);
      if (path.endsWith('missing.css')) throw ElisError('not found');
      if (path.endsWith('broken.js')) return PageFile('text/javascript', brokenFile());
      if (path.endsWith('.css')) return PageFile('text/css', Stream.value(utf8.encode('p{}')));
      if (path.endsWith('bom.html')) return PageFile('text/html', Stream.value([0xEF, 0xBB, 0xBF, ...utf8.encode('<p>é</p>')]));
      if (path.endsWith('doc.html')) {
        return PageFile('text/html; charset=utf-8', Stream.fromIterable([utf8.encode('\uFEFF <!DOCTYPE html>'), utf8.encode('<p>hi</p>')]));
      }
      return PageFile('text/html', Stream.value(utf8.encode('<p>hi</p>')));
    }, javascript: javascript, head: head);
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

  test('aHeadGoesAfterTheDoctypeOfEveryHtmlDocumentOnly', () async {
    await start(javascript: true, head: '<script>H</script>');
    // the decoder drops the byte order mark
    expect((await request(server.urlFor('/w/doc.html'))).$2, ' <!DOCTYPE html><script>H</script><p>hi</p>');
    expect((await request(server.urlFor('/w/index.html'))).$2, '<script>H</script><p>hi</p>');
    expect((await request(server.urlFor('/w/a.css'))).$2, 'p{}');
  });

  test('aHeadGoesAfterTheByteOrderMarkOfAPageWithoutADoctype', () async {
    await start(javascript: true, head: '<script>H</script>');
    final client = HttpClient();
    addTearDown(client.close);
    final bytes = await (await (await client.getUrl(server.urlFor('/w/bom.html'))).close()).expand((c) => c).toList();
    expect(bytes, [0xEF, 0xBB, 0xBF, ...utf8.encode('<script>H</script><p>é</p>')]); // the mark still names UTF-8
  });

  test('eachServerHasItsOwnSecret', () async {
    await start(javascript: true);
    final other = await PageServer.start((_) => throw ElisError('x'), javascript: true);
    expect(other.urlFor('/a').pathSegments.first, isNot(server.urlFor('/a').pathSegments.first));
    expect(server.urlFor('/a').pathSegments.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    await other.close();
  });
}
