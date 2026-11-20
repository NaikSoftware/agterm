// On an agent-owned emulator only: flutter test uninstalls the app from the device when it ends.
// The renderer comes from the Mac app's folder, served from the host:
//   (cd ../macos/Elis/Resources/markdown && python3 -m http.server 8791 --bind 127.0.0.1) &
//   adb -s <device> reverse tcp:8791 tcp:8791
//   flutter test integration_test/page_webview_test.dart -d <device> --no-pub --dart-define=ELIS_MARKDOWN=http://127.0.0.1:8791
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:elis_mobile/pages/page_link.dart';
import 'package:elis_mobile/pages/page_server.dart';
import 'package:elis_mobile/pages/page_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _markdownHost = String.fromEnvironment('ELIS_MARKDOWN');
const _button = '<button type="button" data-elis="notify" data-elis-title="x">b</button>';
const _blocked = "<script>document.title='ran'</script>$_button";

class _Sheet {
  _Sheet() {
    final random = Random.secure();
    nonce = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setOnConsoleMessage((m) => console.add('${m.level.name}: ${m.message}'))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!_loaded.isCompleted) _loaded.complete();
          },
        ),
      )
      ..addJavaScriptChannel('ElisChannel', onMessageReceived: (m) => _message(m.message));
  }

  final controller = WebViewController();
  late final String nonce;
  final raw = <String>[], accepted = <Map<String, dynamic>>[], console = <String>[];
  var _loaded = Completer<void>();
  var real = false; // replies as the sheet's own bridgeScript takes them

  String get prelude =>
      '''
(() => {
  const n = '$nonce';
  const post = ElisChannel.postMessage.bind(ElisChannel);
  const pending = new Map();
  let next = 0;
  window.__elisReply = (id, ok, value) => {
    const waiting = pending.get(id);
    if (!waiting) return;
    pending.delete(id);
    if (ok) waiting.resolve(value); else waiting.reject(new Error(String(value)));
  };
  window.__elis = {
    postMessage(body) {
      const id = ++next;
      post(JSON.stringify({n, id, body}));
      return new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
    },
  };
})();
''';

  void _message(String message) {
    raw.add(message);
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic> || decoded['n'] != nonce || decoded['body'] is! Map<String, dynamic>) return;
    accepted.add(decoded['body'] as Map<String, dynamic>);
    final nonceArg = real ? "'$nonce', " : '';
    unawaited(controller.runJavaScript('window.__elisReply($nonceArg${jsonEncode(decoded['id'])}, true, {})'));
  }

  Future<void> mount(WidgetTester t) => t.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: WebViewWidget(controller: controller),
    ),
  );

  Future<void> load({Uri? url, String? html}) async {
    _loaded = Completer<void>();
    if (url != null) await controller.loadRequest(url);
    if (html != null) await controller.loadHtmlString(html);
    await _loaded.future.timeout(const Duration(seconds: 20));
  }

  Future<String> js(String expression) async => '${await controller.runJavaScriptReturningResult(expression)}';

  Future<void> until(String what, FutureOr<bool> Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!await done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what; raw $raw; console $console');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<PageServer> _serve(String html, {required bool javascript}) => PageServer.start(
  (path) async => PageFile('text/html; charset=utf-8', Stream.value(utf8.encode(html))),
  javascript: javascript,
);

Future<String> _renderer(String name) async {
  if (_markdownHost.isEmpty) fail('pass --dart-define=ELIS_MARKDOWN=<url of macos/Elis/Resources/markdown>');
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse('$_markdownHost/$name'))).close();
    if (response.statusCode != 200) fail('$name: HTTP ${response.statusCode}');
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

// MarkdownAssets.script, as the relay sends it
Future<String> _rendererScript() async =>
    (await Future.wait(['markdown-it-14.1.0.min.js', 'highlight-11.11.1.min.js', 'render.js'].map(_renderer)))
        .join(';\n');

String _escaped(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

// MarkdownPage.html(markdown:images:style:) with no pictures and no links
String _markdownPage(String markdown, String style) =>
    '<!doctype html><html><head><meta charset="utf-8">'
    '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'">'
    '<style>$style</style></head><body>'
    '<div id="elis-markdown" hidden data-images="${_escaped('{"references":{},"uris":[]}')}">${_escaped(markdown)}</div>'
    '<main id="elis-page"></main></body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<_Sheet> sheet(WidgetTester t) async {
    final s = _Sheet();
    await s.mount(t);
    addTearDown(() => debugPrint('WebView console: ${s.console}'));
    return s;
  }

  testWidgets('1: without --js the page script is blocked and the adapter still posts', (t) async {
    final s = await sheet(t);
    final server = await _serve(_blocked, javascript: false);
    addTearDown(server.close);
    await s.load(url: server.urlFor('/page.html'));
    expect(await s.js("document.title === 'ran'"), 'false');
    await s.controller.runJavaScript(s.prelude);
    await s.controller.runJavaScript(_adapter);
    await s.controller.runJavaScript("document.querySelector('button').click()");
    await s.until('the tap', () => s.accepted.isNotEmpty);
    expect(s.accepted.single['cmd'], 'notify');
  });

  testWidgets('2: with --js the page script runs and elis.request posts and gets its reply', (t) async {
    final s = await sheet(t);
    final server = await _serve(_blocked, javascript: true);
    addTearDown(server.close);
    await s.load(url: server.urlFor('/page.html'));
    expect(await s.js("document.title === 'ran'"), 'true');
    await s.controller.runJavaScript(s.prelude);
    await s.controller.runJavaScript('$_adapter\n$_helper');
    await s.controller.runJavaScript("elis.request('notify').then(() => { document.title = 'replied'; })");
    await s.until('the request', () => s.accepted.isNotEmpty);
    expect(s.accepted.single['cmd'], 'notify');
    await s.until('the reply', () async => await s.js("document.title === 'replied'") == 'true');
  });

  testWidgets('3: a content page renders markdown under its default-src none policy', (t) async {
    final s = await sheet(t);
    await s.load(
      html: _markdownPage('# Title\n\nSome *text*.\n\n```swift\nlet x = 1\n```\n', await _renderer('page.css')),
    );
    await s.controller.runJavaScript(await _rendererScript());
    expect(int.parse(await s.js("document.getElementById('elis-page').children.length")), greaterThan(0));
    expect(await s.js("document.getElementById('elis-markdown') === null"), 'true');
  });

  testWidgets('4: the unlink script leaves link texts and no a element', (t) async {
    final s = await sheet(t);
    await s.load(html: _markdownPage('[web](https://example.com) and [doc](other.md)\n', await _renderer('page.css')));
    await s.controller.runJavaScript(await _rendererScript() + _unlink);
    expect(await s.js("document.getElementById('elis-page').querySelectorAll('a').length"), '0');
    final text = "document.getElementById('elis-page').textContent";
    expect(await s.js("$text.includes('web') && $text.includes('doc')"), 'true');
  });

  for (final javascript in [false, true]) {
    testWidgets('5: a message without the nonce is dropped, from an iframe or the main frame (js $javascript)', (
      t,
    ) async {
      final s = await sheet(t);
      const iframe =
          '<iframe srcdoc="<script>ElisChannel.postMessage(JSON.stringify({cmd:\'notify\'}))</script>"></iframe>';
      final server = await _serve('$_blocked$iframe', javascript: javascript);
      addTearDown(server.close);
      await s.load(url: server.urlFor('/page.html'));
      await s.controller.runJavaScript(s.prelude);
      await s.controller.runJavaScript(_adapter);
      await s.controller.runJavaScript('ElisChannel.postMessage(\'{"cmd":"notify"}\')');
      await s.controller.runJavaScript("document.querySelector('button').click()");
      await s.until('the tap', () => s.accepted.isNotEmpty);
      debugPrint('case 5 raw messages: ${s.raw}');
      expect(s.accepted.single['cmd'], 'notify');
      // with --js the iframe's script runs too, so its message arrives and is dropped
      expect(s.raw.length, greaterThanOrEqualTo(javascript ? 3 : 2));
    });
  }

  testWidgets('6: an inline script of a --js page calls elis.request while the page loads', (t) async {
    final s = await sheet(t)
      ..real = true;
    const page = "<!doctype html><script>elis.request('notify').then(() => { document.title = 'replied'; })</script>";
    final server = await PageServer.start(
      (path) async => PageFile('text/html; charset=utf-8', Stream.value(utf8.encode(page))),
      javascript: true,
      head: headTag(s.nonce, _helper),
    );
    addTearDown(server.close);
    await s.load(url: server.urlFor('/page.html'));
    await s.until('the request', () => s.accepted.isNotEmpty);
    expect(s.accepted.single['cmd'], 'notify');
    await s.until('the reply', () async => await s.js("document.title === 'replied'") == 'true');
    expect(await s.js('document.compatMode'), contains('CSS1Compat')); // the head went after the doctype
    expect(await s.js('document.scripts.length'), '1'); // the head removed itself with its nonce
  });
}

// PhoneLinkPresenter.unlinkScript, verbatim
const _unlink = r'''
;(() => {
  const page = document.getElementById('elis-page');
  if (!page) return;
  for (const link of Array.from(page.querySelectorAll('a'))) link.replaceWith(...link.childNodes);
})();''';

// copied from HtmlBridgeAdapter.script(handler:) and helperScript(handler:) with the handler window.__elis
const _adapter = r'''
(() => {
  const handler = window.__elis;
  const show = (el, text) => {
    const selector = el.getAttribute('data-elis-into');
    const into = selector ? document.querySelector(selector) : null;
    if (into) into.textContent = text;
  };
  const shown = (result) => {
    if (result && typeof result.text === 'string') return result.text;
    return JSON.stringify(result ?? {});
  };
  const formArgs = (form, args, submitter) => {
    const seen = new Set();
    for (const control of form.elements) {
      const name = control.name;
      if (!name || control.matches(':disabled')) continue;
      const type = (control.type || '').toLowerCase();
      if (['submit', 'button', 'reset', 'image'].includes(type) && control !== submitter) continue;
      if (type === 'file') throw new Error(`file inputs are not supported: ${name}`);
      if (type === 'radio' && !control.checked) continue;
      let value;
      if (type === 'checkbox') {
        value = control.checked;
      } else if (type === 'number') {
        if (control.value === '') continue;
        value = control.valueAsNumber;
        if (!Number.isFinite(value)) throw new Error(`not a number: ${name}`);
      } else if (control instanceof HTMLSelectElement && control.multiple) {
        const picked = Array.from(control.selectedOptions);
        if (picked.length > 1) throw new Error(`more than one value for ${name}`);
        if (picked.length === 0) continue;
        value = picked[0].value;
      } else {
        value = control.value;
      }
      if (seen.has(name)) throw new Error(`more than one value for ${name}`);
      seen.add(name);
      args[name] = value;
    }
    return args;
  };
  const send = (el, form, submitter) => {
    const body = {cmd: el.getAttribute('data-elis')};
    const target = el.getAttribute('data-elis-target');
    if (target !== null) body.target = target;
    try {
      const base = el.getAttribute('data-elis-args');
      let args = base === null ? undefined : JSON.parse(base);
      if (form) args = formArgs(form, args ?? {}, submitter);
      if (args !== undefined) body.args = args;
    } catch (error) {
      show(el, error.message);
      return;
    }
    handler.postMessage(body).then((result) => show(el, shown(result)), (error) => show(el, error.message));
  };
  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || !form.hasAttribute('data-elis')) return;
    event.preventDefault();
    send(form, form, event.submitter);
  }, true);
  document.addEventListener('click', (event) => {
    const el = event.target instanceof Element ? event.target.closest('[data-elis]') : null;
    if (!el || el instanceof HTMLFormElement || el.closest('form[data-elis]')) return;
    if (el instanceof HTMLButtonElement && el.type !== 'button') return;
    event.preventDefault();
    send(el, null, null);
  }, true);
})();
''';

const _helper = r'''
(() => {
  const handler = window.__elis;
  const request = (cmd, {target, args} = {}) => {
    const body = {cmd};
    if (target !== undefined) body.target = target;
    if (args !== undefined) body.args = args;
    return handler.postMessage(body);
  };
  Object.defineProperty(window, 'elis', {value: Object.freeze({request}), enumerable: false});
})();
''';
