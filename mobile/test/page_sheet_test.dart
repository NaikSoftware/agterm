import 'dart:convert';

import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/pages/page_sheet.dart';
import 'package:elis_mobile/terminal/term_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mux_test.dart' show json;
import 'session_term_test.dart' show FakeWeb, Harness, pageDown, pageUp, presentCh, treeOf, urlPage;

const _sheet = Key('pageSheet'), _chip = Key('pageChip');

Future<Harness> _shown(WidgetTester t, Map<String, Object?> page) async {
  final h = Harness(t, treeOf());
  await h.start(pages: true);
  await h.opened();
  await pageDown(h, [page], open: true);
  return h;
}

Map<String, Object?> _filePage({bool javascript = false}) => {
      't': 'page', 'id': 'f1', 'kind': 'file', 'path': '/w/index.html', 'adapter': 'ADAPTER();', 'javascript': javascript,
      'chromeless': false, 'browse': false, 'hidden': false, 'title': 'index.html',
    };

Map<String, Object?> _command(String action, int seq, {String id = 'p1'}) => {'t': 'command', 'id': id, 'seq': seq, 'action': action};

Future<void> _swipeDown(WidgetTester t) async {
  await t.fling(find.byKey(const Key('pageStrip')), const Offset(0, 300), 1500);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('a page line shows the sheet', (t) async {
    final h = await _shown(t, urlPage());
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('pageStrip')), matching: find.text('example.com')), findsOneWidget);
    expect(find.byKey(const Key('pageClose')), findsOneWidget);
    expect(find.byKey(_chip), findsNothing);
    expect(h.webs.single.urls, [Uri.parse('https://example.com/a')]);
    h.webs.single.c.finished('https://example.com/a');
    await t.pump();
    expect(pageUp(h).last, containsPair('load', 'loaded'));
    await h.stop();
  });

  testWidgets('close sends closed and removes the sheet', (t) async {
    final h = await _shown(t, urlPage());
    await t.tap(find.byKey(const Key('pageClose')));
    await t.pump();
    expect(pageUp(h).last, {'t': 'closed', 'id': 'p1', 'dismissed': true});
    expect(find.byKey(_sheet), findsNothing);
    expect(find.byKey(_chip), findsNothing);

    await pageDown(h, [urlPage(id: 'p2')]);
    await t.binding.handlePopRoute(); // Android back closes the sheet, not the session
    await t.pump();
    expect(pageUp(h).last, {'t': 'closed', 'id': 'p2', 'dismissed': true});
    expect(find.byKey(_sheet), findsNothing);
    expect(find.byKey(const Key('sessionMenu')), findsOneWidget);
    await h.stop();
  });

  testWidgets('window.close closes the sheet', (t) async {
    final h = await _shown(t, urlPage(javascript: true));
    final web = h.webs.single;
    web.c.finished('https://example.com/a');
    await t.pump();
    web.c.message(jsonEncode({'n': web.nonce, 'close': true}));
    await t.pump();
    expect(pageUp(h).last, {'t': 'closed', 'id': 'p1', 'dismissed': true});
    expect(find.byKey(_sheet), findsNothing);
    await h.stop();
  });

  testWidgets('swipe down leaves the chip and one tap brings the sheet back', (t) async {
    final h = await _shown(t, urlPage());
    await _swipeDown(t);
    expect(find.byKey(_sheet), findsNothing);
    expect(find.descendant(of: find.byKey(_chip), matching: find.text('example.com')), findsOneWidget);
    expect(pageUp(h).last, containsPair('hidden', true));
    expect(find.byKey(const Key('fakeWeb'), skipOffstage: false), findsOneWidget); // still live
    await t.tap(find.byKey(_chip));
    await t.pump();
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.byKey(_chip), findsNothing);
    expect(pageUp(h).last, containsPair('hidden', false));
    expect(h.webs, hasLength(1)); // the same page, not reloaded
    expect(h.webs.single.urls, hasLength(1));
    await h.stop();
  });

  testWidgets('the chip goes when the page leaves', (t) async {
    final h = await _shown(t, urlPage());
    await _swipeDown(t);
    await pageDown(h, [_command('close', 1)]);
    expect(find.byKey(_chip), findsNothing);
    expect(find.byKey(_sheet, skipOffstage: false), findsNothing);

    await pageDown(h, [urlPage(hidden: true)]);
    expect(find.byKey(_chip), findsOneWidget);
    h.r.send(json(LinkKind.close, presentCh, {'reason': 'presentation ended'}));
    await t.pump();
    await t.pump();
    expect(find.byKey(_chip), findsNothing);
    expect(find.byKey(_sheet, skipOffstage: false), findsNothing);
    await h.stop();
  });

  testWidgets('sizePercent 50 takes half the body', (t) async {
    final h = await _shown(t, urlPage(sizePercent: 50));
    final body = t.getRect(find.ancestor(of: find.byKey(_sheet), matching: find.byType(Stack)).first);
    final sheet = t.getRect(find.byKey(_sheet));
    expect(sheet.height, moreOrLessEquals(body.height / 2));
    expect(sheet.bottom, body.bottom);
    await pageDown(h, [
      {..._command('resize', 1), 'sizePercent': 100},
    ]);
    expect(t.getRect(find.byKey(_sheet)), body);
    expect(pageUp(h).last, containsPair('appliedSeq', 1));
    await h.stop();
  });

  testWidgets('a hidden page shows only the chip', (t) async {
    final h = await _shown(t, urlPage(hidden: true));
    expect(find.byKey(_sheet), findsNothing);
    expect(find.byKey(_chip), findsOneWidget);
    await pageDown(h, [_command('show', 1)]);
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.byKey(_chip), findsNothing);
    await pageDown(h, [_command('hide', 2)]);
    expect(find.byKey(_sheet), findsNothing);
    expect(pageUp(h).last, allOf(containsPair('hidden', true), containsPair('appliedSeq', 2)));
    await h.stop();
  });

  testWidgets('reload, back and forward act on the web view', (t) async {
    final h = await _shown(t, urlPage());
    await pageDown(h, [_command('reload', 1), _command('back', 2), _command('forward', 3)]);
    final web = h.webs.single;
    expect((web.reloads, web.backs, web.forwards), (1, 1, 1));
    expect(pageUp(h).last, containsPair('appliedSeq', 3));
    await h.stop();
  });

  testWidgets('a channel message without the nonce is dropped', (t) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    await h.opened();
    await pageDown(h, [_filePage()], open: true);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100))); // the loopback server binds
    await t.pump();
    final web = h.webs.single;
    final url = web.urls.single;
    expect(url.host, '127.0.0.1');
    expect(url.pathSegments, [hasLength(32), 'w', 'index.html']); // under the sheet's secret
    web.c.finished('$url');
    await t.pump();
    expect(web.scripts.single, contains('ADAPTER();'));
    final body = {'cmd': 'notify'};
    web.c.message(jsonEncode({'id': 1, 'body': body}));
    web.c.message(jsonEncode({'n': 'f' * 32, 'id': 2, 'body': body}));
    web.c.message('not json');
    await t.pump();
    expect(pageUp(h).where((l) => l['t'] == 'bridge'), isEmpty);
    web.c.message(jsonEncode({'n': web.nonce, 'id': 3, 'body': body}));
    await t.pump();
    final bridge = pageUp(h).singleWhere((l) => l['t'] == 'bridge');
    expect(jsonDecode(bridge['line'] as String), body);
    await pageDown(h, [
      {'t': 'reply', 'id': 'f1', 'seq': bridge['seq'], 'response': '{"ok":true,"result":{"text":"done"}}'},
    ]);
    expect(web.scripts.last, "window.__elisReply('${web.nonce}', 3, true, {\"text\":\"done\"})");
    await pageDown(h, [
      {'t': 'command', 'id': 'f1', 'seq': 1, 'action': 'close'},
    ]);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // the server closes
    await h.stop();
  });

  testWidgets('a bridge body on a url page is dropped', (t) async {
    final h = await _shown(t, urlPage(javascript: true));
    final web = h.webs.single;
    web.c.finished('https://example.com/a');
    await t.pump();
    expect(web.scripts.single, isNot(contains('data-elis'))); // the prelude only, no adapter
    web.c.message(jsonEncode({'n': web.nonce, 'id': 1, 'body': {'cmd': 'notify'}}));
    await t.pump();
    expect(pageUp(h).where((l) => l['t'] == 'bridge'), isEmpty);
    await h.stop();
  });

  testWidgets('a url page stays on its origin', (t) async {
    final h = await _shown(t, urlPage());
    final c = h.webs.single.c;
    c.finished('https://example.com/a');
    await t.pump();
    final opened = <Object?>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('elis/open'), (call) async => opened.add(call.arguments));
    expect(c.allows('https://example.com/b'), isTrue);
    await t.tap(find.byKey(const Key('fakeWeb')));
    expect(c.allows('intent://x#Intent;end'), isFalse);
    await t.pump();
    expect(find.byType(AlertDialog), findsNothing); // only web links leave for the browser
    expect(c.allows('https://other.example/'), isFalse);
    await t.pump();
    expect(c.allows('http://example.com/a'), isFalse); // one offer at a time
    await t.pump();
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    expect(opened, ['https://other.example/']);
    expect(find.byType(AlertDialog), findsNothing);
    await h.stop();
  });

  testWidgets('a refused link asks only after a touch and not again after cancel', (t) async {
    final h = await _shown(t, urlPage());
    final c = h.webs.single.c;
    c.finished('https://example.com/a');
    await t.pump();
    expect(c.allows('https://other.example/'), isFalse); // a script's navigation: no touch
    await t.pump();
    expect(find.byType(AlertDialog), findsNothing);
    await t.tap(find.byKey(const Key('fakeWeb')));
    c.allows('https://other.example/');
    await t.pump();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    c.allows('https://other.example/');
    await t.pump();
    expect(find.byType(AlertDialog), findsNothing); // silenced until the next touch
    await t.tap(find.byKey(const Key('fakeWeb')));
    c.allows('https://other.example/');
    await t.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await h.stop();
  });

  testWidgets('a hidden page offers no link', (t) async {
    final h = await _shown(t, urlPage());
    final c = h.webs.single.c;
    c.finished('https://example.com/a');
    await t.pump();
    await t.tap(find.byKey(const Key('fakeWeb')));
    await pageDown(h, [_command('hide', 1)]);
    expect(c.allows('https://other.example/'), isFalse);
    await t.pump();
    expect(find.byType(AlertDialog), findsNothing);
    await h.stop();
  });

  testWidgets('a refused navigation during the first load fails the page', (t) async {
    final h = await _shown(t, urlPage());
    expect(h.webs.single.c.allows('https://other.example/'), isFalse); // a redirect
    await t.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(pageUp(h).last, allOf(containsPair('load', 'failed'), containsPair('error', 'navigation blocked: https://other.example/')));
    await h.stop();
  });

  testWidgets('a shown sheet takes the keyboard from the terminal', (t) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    await h.opened();
    final keyboard = t.widget<TermKeyboard>(find.byType(TermKeyboard)).focus..requestFocus();
    await t.pump();
    expect(keyboard.hasFocus, isTrue);
    await pageDown(h, [urlPage()], open: true);
    expect(keyboard.hasFocus, isFalse);
    keyboard.requestFocus(); // under a full sheet nothing takes it back
    await t.pump();
    expect(keyboard.hasFocus, isFalse);

    await _swipeDown(t);
    keyboard.requestFocus();
    await t.pump();
    expect(keyboard.hasFocus, isTrue);
    await t.tap(find.byKey(_chip));
    await t.pump();
    expect(keyboard.hasFocus, isFalse);
    await h.stop();
  });

  testWidgets('a hidden page loses the keyboard', (t) async {
    final h = await _shown(t, urlPage());
    final web = h.webs.single;
    web.focus.requestFocus();
    await t.pump();
    expect(web.focus.hasFocus, isTrue);
    await _swipeDown(t);
    expect(web.focus.hasFocus, isFalse);
    await h.stop();
  });

  Future<(Harness, FakeWeb, Uri)> fileShown(WidgetTester t, {bool javascript = false}) async {
    final h = Harness(t, treeOf());
    await h.start(pages: true);
    await h.opened();
    await pageDown(h, [
      {..._filePage(javascript: javascript), 'helper': 'HELPER();'},
    ], open: true);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100))); // the loopback server binds
    await t.pump();
    return (h, h.webs.single, h.webs.single.urls.single);
  }

  Future<void> closeFile(Harness h) async {
    await pageDown(h, [_command('close', 1, id: 'f1')]);
    await h.t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // the server closes
    await h.stop();
  }

  testWidgets('a file page reports its origin path and never the sheet secret', (t) async {
    final (h, web, url) = await fileShown(t);
    web.titleText = '$url'; // Android's title for an untitled page
    web.c.finished('$url#top');
    await t.pump();
    final state = pageUp(h).lastWhere((l) => l['t'] == 'state');
    expect(state['current'], '/w/index.html');
    expect(state.containsKey('title'), isFalse);
    expect(pageUp(h).where((l) => l['t'] == 'state').map(jsonEncode), everyElement(isNot(contains(url.pathSegments.first))));
    await closeFile(h);
  });

  testWidgets('a --js file page runs its helper at finish only where the head did not', (t) async {
    final (h, web, url) = await fileShown(t, javascript: true);
    web.c.finished('$url');
    await t.pump();
    final script = web.scripts.single;
    expect(script, contains("if (!Object.getOwnPropertyDescriptor(window, 'elis')) HELPER();"));
    expect(script, contains('ADAPTER();'));
    final head = headTag(web.nonce, 'HELPER();');
    expect(head, startsWith('<script>document.currentScript.remove(); if (window.top === window) '));
    expect(head, contains("const n = '${web.nonce}'"));
    expect(head, isNot(contains('ADAPTER();')));
    expect(headTag('n', "x = '</SCRIPT>';"), contains(r"x = '<\/SCRIPT>';"));
    await closeFile(h);
  });

  testWidgets('a failed main frame stays failed through its own finish', (t) async {
    final (h, web, url) = await fileShown(t);
    web.c.httpError('${url.replace(path: '/favicon.ico')}', 404); // a subresource
    web.c.httpError('$url', 404);
    web.c.started('$url');
    web.c.finished('$url');
    await t.pump();
    expect(pageUp(h).last, allOf(containsPair('load', 'failed'), containsPair('error', 'the page answered 404')));
    await pageDown(h, [_command('reload', 1, id: 'f1')]);
    web.c.finished('$url');
    await t.pump();
    expect(pageUp(h).last, containsPair('load', 'loaded'));
    await closeFile(h);
  });

  testWidgets('a root-absolute link stays inside the page', (t) async {
    final (h, web, url) = await fileShown(t);
    web.c.finished('$url');
    await t.pump();
    await t.tap(find.byKey(const Key('fakeWeb')));
    expect(web.c.allows('http://127.0.0.1:${url.port}/w/b.html?q=1'), isFalse);
    await t.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(web.urls.last, url.replace(path: '/${url.pathSegments.first}/w/b.html', query: 'q=1'));
    expect(web.c.allows('http://127.0.0.1:${url.port}'), isFalse); // the bare origin
    expect(web.urls.last, url.replace(path: '/${url.pathSegments.first}/'));
    await closeFile(h);
  });

  testWidgets('a link tapped during the first load is offered to the browser', (t) async {
    final h = await _shown(t, urlPage());
    await t.tap(find.byKey(const Key('fakeWeb')));
    expect(h.webs.single.c.allows('https://other.example/'), isFalse);
    await t.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(pageUp(h).where((l) => l['load'] == 'failed'), isEmpty);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await h.stop();
  });

  testWidgets('a content page loads the fetched html and script', (t) async {
    final h = await _shown(t, {
      't': 'page', 'id': 'c1', 'kind': 'content', 'javascript': false, 'chromeless': false, 'browse': false, 'hidden': false,
      'title': 'notes.md',
    });
    final fetches = pageUp(h).where((l) => l['t'] == 'fetch').toList();
    expect([for (final f in fetches) f['path']], ['elis:content', 'elis:script']);
    String b64(String s) => base64Encode(utf8.encode(s));
    await pageDown(h, [
      {'t': 'res', 'id': 'c1', 'seq': fetches[0]['seq'], 'mime': 'text/html', 'data': b64('<p>hi</p>'), 'end': true},
      {'t': 'res', 'id': 'c1', 'seq': fetches[1]['seq'], 'mime': 'text/javascript', 'data': b64('render();'), 'end': true},
    ]);
    final web = h.webs.single;
    expect(web.htmls, ['<p>hi</p>']);
    web.c.finished('about:blank');
    await t.pump();
    expect(web.scripts, contains('render();'));
    expect(web.c.allows('https://example.com/'), isFalse);
    await h.stop();
  });
}
