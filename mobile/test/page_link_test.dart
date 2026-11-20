import 'dart:async';
import 'dart:convert';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/pages/page_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show FakeRelay, dataOn, flush, frame, json, upgraded;

const filePage = {
  't': 'page', 'id': 'p1', 'kind': 'file', 'path': '/w/index.html', 'adapter': 'A', 'javascript': false,
  'chromeless': false, 'browse': false, 'hidden': false, 'title': 'index.html', 'sizePercent': 60,
};

/// A [PageLink] whose present channel the relay accepted.
Future<(PageLink, FakeRelay, int)> opened() async {
  final (m, r, _) = await upgraded();
  final link = PageLink(m, 'w');
  await flush();
  final id = r.frames.last.channel;
  r.send(json(LinkKind.opened, id, {}));
  await flush();
  return (link, r, id);
}

void down(FakeRelay r, int ch, Map<String, Object?> line) => r.send(frame(LinkKind.data, ch, utf8.encode('${jsonEncode(line)}\n')));

List<Map> sent(FakeRelay r, int ch) => [
  for (final l in const LineSplitter().convert(utf8.decode([for (final f in dataOn(r, ch)) ...f.payload]))) jsonDecode(l) as Map,
];

void main() {
  test('aPageLineSetsThePage', () async {
    final (link, r, ch) = await opened();
    var notified = 0;
    link.addListener(() => notified++);
    down(r, ch, filePage);
    await flush();
    final page = link.page!;
    expect((page.id, page.kind, page.path, page.adapter, page.title, page.sizePercent), ('p1', 'file', '/w/index.html', 'A', 'index.html', 60));
    expect((page.javascript, page.chromeless, page.browse, page.hidden, page.appliedSeq), (false, false, false, false, 0));
    expect(notified, 1);
  });

  test('aCloseCommandClearsThePage', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    down(r, ch, {'t': 'command', 'id': 'p1', 'seq': 0, 'action': 'close'});
    await flush();
    expect(link.page, isNull);
  });

  test('theChannelsCloseClearsThePage', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    final fetch = expectLater(link.fetch('p1', '/w/a.css'), throwsA(isA<ElisError>()));
    r.send(json(LinkKind.close, ch, {'reason': 'presentation ended'}));
    await flush();
    expect(link.page, isNull);
    await fetch;
  });

  test('aClosedPageFailsItsRequests', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    final fetch = expectLater(link.fetch('p1', '/w/a.css'), throwsA(isA<ElisError>()));
    final bridge = expectLater(link.bridge('p1', '{}'), throwsA(isA<ElisError>()));
    down(r, ch, {'t': 'command', 'id': 'p1', 'seq': 0, 'action': 'close'});
    await fetch;
    await bridge;
    down(r, ch, filePage);
    await flush();
    final again = expectLater(link.fetch('p1', '/w/a.css'), throwsA(isA<ElisError>()));
    link.closed('p1', dismissed: false);
    await again;
  });

  test('anOversizedBridgeLineIsRefusedOnThePhone', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    await expectLater(link.bridge('p1', 'x' * (1 << 20)), throwsA(isA<ElisError>()));
    expect(dataOn(r, ch), isEmpty);
  });

  test('closedSendsDismissed', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    link.closed('p1', dismissed: true);
    expect(sent(r, ch).single, {'t': 'closed', 'id': 'p1', 'dismissed': true});
    expect(link.page, isNull);
  });

  test('fetchSendsAFreshSeqAndCompletesFromRes', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    final first = link.fetch('p1', '/w/a.css');
    final second = link.fetch('p1', '/w/b.css');
    final out = sent(r, ch);
    expect(out[0], {'t': 'fetch', 'id': 'p1', 'seq': out[0]['seq'], 'path': '/w/a.css'});
    expect(out[1]['seq'], isNot(out[0]['seq']));
    down(r, ch, {'t': 'res', 'id': 'p1', 'seq': out[0]['seq'], 'mime': 'text/css', 'end': false});
    final file = await first;
    expect(file.mime, 'text/css');
    final bytes = file.bytes.fold<List<int>>([], (a, b) => a + b);
    down(r, ch, {'t': 'res', 'id': 'p1', 'seq': out[0]['seq'], 'data': base64Encode(utf8.encode('a{}')), 'end': false});
    down(r, ch, {'t': 'res', 'id': 'p1', 'seq': out[0]['seq'], 'end': true});
    expect(utf8.decode(await bytes), 'a{}');
    down(r, ch, {'t': 'res', 'id': 'p1', 'seq': out[1]['seq'], 'end': true, 'error': 'not found'});
    await expectLater(second, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'not found')));
  });

  test('bridgeCompletesFromReply', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    final ok = link.bridge('p1', '{"cmd":"tree"}');
    final bad = link.bridge('p1', '{"cmd":"x"}');
    final out = sent(r, ch);
    expect(out[0], {'t': 'bridge', 'id': 'p1', 'seq': out[0]['seq'], 'line': '{"cmd":"tree"}'});
    down(r, ch, {'t': 'reply', 'id': 'p1', 'seq': out[0]['seq'], 'response': '{"ok":true}'});
    down(r, ch, {'t': 'reply', 'id': 'p1', 'seq': out[1]['seq'], 'error': 'busy'});
    expect(await ok, '{"ok":true}');
    await expectLater(bad, throwsA(isA<ElisError>().having((e) => e.message, 'message', 'busy')));
  });

  test('reportCarriesTheAppliedSeqAndHidden', () async {
    final (link, r, ch) = await opened();
    final commands = <String>[];
    link.commands.listen((c) => commands.add('${c.id} ${c.seq} ${c.action} ${c.sizePercent}'));
    down(r, ch, filePage);
    down(r, ch, {'t': 'command', 'id': 'p1', 'seq': 7, 'action': 'hide'});
    await flush();
    expect(commands, ['p1 7 hide null']);
    link.report('p1', load: 'loaded', title: 'T');
    expect(sent(r, ch).single, {
      't': 'state', 'id': 'p1', 'load': 'loaded', 'title': 'T', 'canGoBack': false, 'appliedSeq': 7, 'hidden': true,
    });
  });

  test('linesQueuedAtDisposeAreDropped', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    link.addListener(() => scheduleMicrotask(link.dispose)); // between two queued lines
    final lines = [{...filePage, 'id': 'p2'}, {'t': 'command', 'id': 'p1', 'seq': 3, 'action': 'hide'}, {...filePage, 'id': 'p3'}];
    r.send(frame(LinkKind.data, ch, utf8.encode(lines.map((l) => '${jsonEncode(l)}\n').join())));
    await flush();
    await flush();
  });

  test('aMalformedLineIsDropped', () async {
    final (link, r, ch) = await opened();
    down(r, ch, {...filePage, 'sizePercent': 'big'});
    down(r, ch, {'t': 'command', 'id': 'p1', 'seq': 'x', 'action': 'hide'});
    down(r, ch, filePage);
    await flush();
    expect(link.page?.id, 'p1');
    final fetch = link.fetch('p1', '/w/a.css');
    final seq = sent(r, ch).last['seq'];
    down(r, ch, {'t': 'res', 'id': 'p1', 'seq': seq, 'mime': 'text/css', 'end': false});
    final file = await fetch;
    final bytes = expectLater(file.bytes.drain<void>(), throwsA(isA<ElisError>()));
    down(r, ch, {'t': 'res', 'id': 'p1', 'seq': seq, 'data': '***', 'end': false});
    await bytes;
  });

  test('disposeClosesTheChannelAndDropsEveryPage', () async {
    final (link, r, ch) = await opened();
    down(r, ch, filePage);
    await flush();
    link.dispose();
    expect(r.frames.last.kind, LinkKind.close);
    expect(r.frames.last.channel, ch);
    expect(link.page, isNull);
  });
}
