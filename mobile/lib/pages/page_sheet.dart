// A page over the session: its web view, identity strip and chip (`PageLink` owns the wire).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../client.dart';
import '../theme.dart';
import 'page_link.dart';
import 'page_server.dart';
import 'page_tunnel.dart';

/// What a sheet asks of its web view; widget tests drive the sheet without a platform view.
abstract interface class PageWeb {
  Future<void> loadUrl(Uri url);
  Future<void> loadHtml(String html);
  Future<void> run(String script);
  Future<void> reload();
  Future<void> goBack();
  Future<void> goForward();
  Future<bool> canGoBack();
  Future<String?> title();

  /// Whether the document has no element in its head or body, as one the web view dropped.
  Future<bool> isEmpty();
}

/// A sheet's side of its web view: the web view calls these, and the builder sets [web].
class PageSheetController {
  PageSheetController._(this._sheet);
  final _PageSheetState _sheet;
  late PageWeb web;

  bool get javascript => _sheet._javascript;

  /// A message on the page's `ElisChannel`, which every frame of every page can reach.
  void message(String text) => _sheet._message(text);

  /// The main frame started showing [url].
  void started(String url) => _sheet._started(url);

  /// The main frame finished loading [url].
  void finished(String url) => unawaited(_sheet._finished(url));

  void failed(String error) => _sheet._failed(error);

  /// A response with an error status; only the main frame's fails the page.
  void httpError(String url, int? status) => _sheet._httpError(url, status);

  /// Whether the main frame may go to [url]; a web link outside the page's bounds is offered to the browser.
  bool allows(String url) => _sheet._allows(url);
}

class PageSheet extends StatefulWidget {
  const PageSheet({super.key, required this.link, required this.page, required this.onSwipeDown, this.webView});
  final PageLink link;
  final PhonePage page;
  final VoidCallback onSwipeDown;
  final Widget Function(PageSheetController)? webView;

  @override
  State<PageSheet> createState() => _PageSheetState();
}

class _PageSheetState extends State<PageSheet> {
  late final _controller = PageSheetController._(this);
  late final Widget _view;
  late final StreamSubscription<PageCommand> _commands;
  final _nonce = randomHex128();
  PageServer? _server;
  PageTunnel? _tunnel; // a forward page's, and the only owner of its cookie
  String? _prefix; // a file page's server root, secret included
  String? _script; // a content page's renderer
  String _load = 'loading';
  String? _title, _current, _error;
  String? _main; // the main frame's address, as the web view names it
  String? _failedAt; // the main frame the page failed on: its own finish is no load
  bool _canGoBack = false, _closed = false, _offering = false, _loading = true;
  bool _touched = false, _silenced = false; // as the Mac's user activation and promptsSilenced
  Timer? _touch;
  late bool _reportedHidden;
  double _drag = 0;

  PhonePage get page => widget.page;
  PageWeb get _web => _controller.web;
  bool get _urlLike => page.kind == 'url' || page.kind == 'forward';
  bool get _javascript => !_urlLike || page.javascript;
  String? get _tunnelOrigin => _tunnel == null ? null : 'http://127.0.0.1:${_tunnel!.port}';

  @override
  void initState() {
    super.initState();
    _reportedHidden = page.hidden;
    _view = (widget.webView ?? _nativeWebView)(_controller);
    _commands = widget.link.commands.where((c) => c.id == page.id).listen((c) => unawaited(_command(c)));
    unawaited(_start());
  }

  @override
  void didUpdateWidget(PageSheet old) {
    super.didUpdateWidget(old);
    if (page.hidden != _reportedHidden) _report(); // a swipe or the chip
  }

  @override
  void dispose() {
    unawaited(_commands.cancel());
    _touch?.cancel();
    unawaited(_server?.close());
    if (_tunnel case final t?) {
      unawaited(_setCookie('${t.cookie.split('=').first}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict').catchError((Object _) => false));
      unawaited(t.close());
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      switch (page.kind) {
        case 'file':
          final server = await PageServer.start((path) => widget.link.fetch(page.id, path),
              javascript: page.javascript, head: page.javascript ? headTag(_nonce, page.helper ?? '') : null);
          if (!mounted) return unawaited(server.close());
          _server = server;
          _prefix = '${server.urlFor('/')}';
          _main = '${server.urlFor(page.path!)}';
          await _web.loadUrl(server.urlFor(page.path!));
        case 'url':
          _main = page.url;
          await _web.loadUrl(Uri.parse(page.url!));
        case 'forward':
          final original = Uri.parse(page.url!);
          final tunnel = await PageTunnel.start(() => widget.link.forward(page.id), preferredPort: original.port);
          if (!mounted) return unawaited(tunnel.close());
          _tunnel = tunnel;
          if (await _setCookie('${tunnel.cookie}; Path=/; HttpOnly; SameSite=Strict') != true) throw ElisError('could not set the page cookie');
          if (!mounted) return; // dispose cleared it
          final url = tunnel.urlFor(original);
          _main = '$url';
          await _web.loadUrl(url);
        case 'content':
          final [html, script] = await Future.wait([_text(contentPath), _text(scriptPath)]);
          if (!mounted) return;
          _script = script;
          await _web.loadHtml(html);
      }
    } on Object catch (e) {
      _failed(e is ElisError ? e.message : '$e');
    }
  }

  // webview_flutter's cookies carry no HttpOnly or SameSite, so MainActivity sets them through CookieManager
  Future<bool?> _setCookie(String cookie) =>
      const MethodChannel('elis/cookie').invokeMethod<bool>('set', {'url': _tunnelOrigin, 'cookie': cookie});

  Future<String> _text(String path) async => utf8.decoder.bind((await widget.link.fetch(page.id, path)).bytes).join();

  void _started(String url) {
    if (url != _failedAt) _failedAt = null;
    _main = url;
    if (mounted && !_closed && !_loading) setState(() => _loading = true);
  }

  void _httpError(String url, int? status) {
    if (url == _main) _failed('the page answered ${status ?? 'an error'}');
  }

  Future<void> _finished(String url) async {
    if (!mounted || _closed || _failedAt != null) return;
    // a content page always finishes on about:blank, so only its document tells that the web view dropped it
    if (page.kind == 'content' && await _web.isEmpty().catchError((Object _) => false)) {
      return _failed('the page is too large for the phone');
    }
    if (!mounted || _closed) return;
    _current = _address(url);
    _load = 'loaded';
    _loading = false;
    _error = null;
    final script = switch (page.kind) {
      'file' => bridgeScript(_nonce, helper: page.helper, adapter: page.adapter ?? ''),
      'url' || 'forward' when page.javascript => bridgeScript(_nonce),
      'content' => _script,
      _ => null,
    };
    try {
      if (script != null && script.isNotEmpty) await _web.run(script);
      _canGoBack = await _web.canGoBack();
      final title = await _web.title();
      _title = title == null || _isAddress(title, url) ? null : title;
    } on Object {
      // a page that navigated away meanwhile reports its own finish
    }
    if (!mounted) return;
    _report();
    setState(() {});
  }

  // Android names an untitled page by its address, with or without the scheme; a file page's carries the sheet's secret
  bool _isAddress(String title, String url) {
    if (title == url || title == url.replaceFirst(RegExp('^[a-z]+://'), '')) return true;
    if (_prefix == null) return false;
    final server = Uri.parse(_prefix!);
    return title.contains(server.authority) || title.contains(server.pathSegments.first);
  }

  /// The Mac's current page: a file page's origin path, never the sheet's server; the relay names a content page's.
  String? _address(String url) => switch (page.kind) {
    'file' when _prefix != null && url.startsWith(_prefix!) => '/${Uri.parse(url).pathSegments.skip(1).join('/')}',
    'url' => url,
    // the tunnel's port is the phone's own; the Mac knows the page by its own address
    'forward' when _tunnelOrigin != null && Uri.parse(url).origin == _tunnelOrigin => () {
      final (u, o) = (Uri.parse(url), Uri.parse(page.url!));
      return '${u.replace(scheme: o.scheme, host: o.host, port: o.port)}';
    }(),
    'forward' => url,
    _ => null,
  };

  void _failed(String error) {
    if (!mounted || _closed) return;
    _failedAt = _main ?? '';
    _load = 'failed';
    _loading = false;
    _error = error;
    _report();
    setState(() {});
  }

  void _message(String text) {
    final Object? o;
    try {
      o = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (!mounted || _closed || o is! Map<String, dynamic> || o['n'] != _nonce) return;
    if (o['close'] == true) return _close();
    final (id, body) = (o['id'], o['body']);
    if (page.kind != 'file' || id is! int || body is! Map) return;
    widget.link.bridge(page.id, jsonEncode(body)).then((raw) {
      // as HtmlOverlayBridge.reply(raw:) on the Mac
      final Object? envelope;
      try {
        envelope = jsonDecode(raw);
      } on FormatException {
        return _reply(id, false, 'invalid reply');
      }
      if (envelope is! Map) return _reply(id, false, 'invalid reply');
      if (envelope['ok'] != true) return _reply(id, false, '${envelope['error'] ?? 'request failed'}');
      _reply(id, true, envelope['result'] ?? const <String, Object>{});
    }, onError: (Object e) => _reply(id, false, e is ElisError ? e.message : '$e'));
  }

  void _reply(int id, bool ok, Object? value) {
    if (!mounted || _closed) return;
    unawaited(_web.run("window.__elisReply('$_nonce', $id, $ok, ${jsonEncode(value)})").catchError((Object _) {}));
  }

  bool _allows(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    if (u.isScheme('about')) return true;
    final ok = switch (page.kind) {
      'url' => _origin(u) != null && (page.browse || _origin(u) == _origin(Uri.parse(page.url!))),
      'forward' => _origin(u) != null && (page.browse || _origin(u) == _tunnelOrigin),
      'file' => _prefix != null && url.startsWith(_prefix!),
      _ => false,
    };
    if (ok) {
      _main = url;
      _failedAt = null;
      return true;
    }
    final server = _prefix == null ? null : Uri.parse(_prefix!).origin;
    if (server != null && _origin(u) == server) {
      // a root-absolute link names the origin's root, as file:///x does on the Mac; the origin judges the path
      unawaited(_web.loadUrl(Uri.parse('$_prefix${url.substring(server.length).replaceFirst(RegExp('^/'), '')}')).catchError((Object _) {}));
    } else if (page.kind == 'forward' && _tunnel != null && _origin(u) == _origin(Uri.parse(page.url!))) {
      // the dev server's own address, which the phone reaches only through the tunnel
      unawaited(_web.loadUrl(_tunnel!.urlFor(u)).catchError((Object _) {}));
    } else if (_origin(u) != null && _touched && !_silenced && !page.hidden) {
      unawaited(_offerBrowser(url)); // a click, during the first load too, as on the Mac
    } else if (_load == 'loading') {
      _failed('navigation blocked: $url'); // a redirect off the page's bounds
    }
    return false;
  }

  // Android tells no user gesture: a touch in the last second stands in for one
  void _touchedNow() {
    _silenced = false;
    _touched = true;
    _touch?.cancel();
    _touch = Timer(const Duration(seconds: 1), () => _touched = false);
  }

  static String? _origin(Uri u) => (u.isScheme('http') || u.isScheme('https')) && u.host.isNotEmpty ? u.origin : null;

  Future<void> _offerBrowser(String url) async {
    if (_offering || !mounted) return;
    _offering = true;
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open in the browser?'),
        content: Text(url, style: const TextStyle(fontFamily: mono, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open')),
        ],
      ),
    );
    _offering = false;
    _silenced = open != true;
    if (open == true) await const MethodChannel('elis/open').invokeMethod<bool>('view', url).catchError((Object _) => false);
  }

  Future<void> _command(PageCommand c) async {
    if (const {'reload', 'back', 'forward'}.contains(c.action)) _failedAt = null;
    try {
      switch (c.action) {
        case 'reload':
          await _web.reload();
        case 'back':
          await _web.goBack();
        case 'forward':
          await _web.goForward();
      }
    } on Object {
      // the next finish reports where the page is
    }
    _report(); // hide, show and resize the link applied already
  }

  void _reloadFailed() {
    _failedAt = null;
    _load = 'loading';
    _loading = true;
    _error = null;
    _report();
    setState(() {});
    if (_main != null) return unawaited(_web.reload().catchError((Object _) {}));
    unawaited(_tunnel?.close()); // nothing loaded: the page starts again
    _tunnel = null;
    unawaited(_start());
  }

  void _report() {
    if (!mounted || _closed) return;
    _reportedHidden = page.hidden;
    widget.link.report(page.id, load: _load, title: _title, current: _current, canGoBack: _canGoBack, error: _error);
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    widget.link.closed(page.id, dismissed: true);
  }

  @override
  Widget build(BuildContext context) {
    final size = page.sizePercent;
    return PopScope(
      canPop: page.hidden,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Offstage(
        offstage: page.hidden,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: size == null || size >= 100 ? 1 : max(size, 1) / 100,
            child: Material(
              key: const Key('pageSheet'),
              color: C.bg,
              child: Column(
                children: [
                  if (!page.chromeless) ...[_strip(), const Divider(height: 1)],
                  // the dev server's bytes cross the link, which over Bluetooth is slow
                  if (page.kind == 'forward' && _loading) const LinearProgressIndicator(key: Key('pageLoading'), minHeight: 2),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                        child: Listener(onPointerDown: (_) => _touchedNow(), child: ExcludeFocus(excluding: page.hidden, child: _view)),
                      ),
                        if (_load == 'failed')
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_error ?? 'The page did not load.', textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
                                  if (page.kind == 'forward')
                                    TextButton(key: const Key('pageReload'), onPressed: _reloadFailed, child: const Text('Reload')),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // the Mac's strip: the page's identity, its own title dimmed, and close; a swipe down hides the sheet
  Widget _strip() => GestureDetector(
    key: const Key('pageStrip'),
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: (_) => _drag = 0,
    onVerticalDragUpdate: (d) => _drag += d.delta.dy,
    onVerticalDragEnd: (d) {
      if (_drag > 48 || d.velocity.pixelsPerSecond.dy > 300) widget.onSwipeDown();
    },
    child: SizedBox(
      height: 36,
      child: Row(
        children: [
          if (_urlLike && _canGoBack)
            IconButton(
              key: const Key('pageBack'),
              tooltip: 'Back',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_back, size: 18, color: C.muted),
              onPressed: () => unawaited(_web.goBack()),
            )
          else
            const SizedBox(width: 12),
          // the identity first: the page's own title, dimmed, gives up its width first
          Expanded(
            child: Text.rich(
              TextSpan(
                text: page.title,
                children: [
                  if (_title case final t? when t.isNotEmpty && t != page.title)
                    TextSpan(
                      text: ' · $t',
                      style: const TextStyle(color: C.dim, fontWeight: FontWeight.normal),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (page.kind == 'forward' && widget.link.via.isNotEmpty)
            Container(
              key: const Key('pageVia'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(6)),
              child: Text(widget.link.via, style: const TextStyle(fontSize: 11, color: C.muted, fontWeight: FontWeight.w600)),
            ),
          IconButton(
            key: const Key('pageClose'),
            tooltip: 'Close page',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: C.muted),
            onPressed: _close,
          ),
        ],
      ),
    ),
  );
}

/// A hidden page's only entry point, in the session's top bar; it takes the lead tag's look.
class PageChip extends StatelessWidget {
  const PageChip({required this.title, required this.onTap}) : super(key: const Key('pageChip'));
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Show page $title',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 120),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: C.line),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset, size: 12, color: C.muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: C.muted, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _nativeWebView(PageSheetController c) {
  final w = WebViewController();
  unawaited(w.setJavaScriptMode(c.javascript ? JavaScriptMode.unrestricted : JavaScriptMode.disabled));
  unawaited(
    w.setNavigationDelegate(
      NavigationDelegate(
        // a frame's own navigation stays inside the page, as on the Mac; the nonce bounds what it can post
    onNavigationRequest: (r) => !r.isMainFrame || c.allows(r.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
        onPageStarted: c.started,
        onPageFinished: c.finished,
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? false) c.failed(e.description);
        },
        onHttpError: (e) {
          if (e.request?.uri case final uri?) c.httpError('$uri', e.response?.statusCode);
        },
      ),
    ),
  );
  unawaited(w.addJavaScriptChannel('ElisChannel', onMessageReceived: (m) => c.message(m.message)));
  if (w.platform case final AndroidWebViewController a) {
    unawaited(a.setAllowFileAccess(false));
    unawaited(a.setAllowContentAccess(false));
  }
  c.web = _NativeWeb(w);
  return WebViewWidget(controller: w);
}

class _NativeWeb implements PageWeb {
  _NativeWeb(this.w);
  final WebViewController w;

  @override
  Future<void> loadUrl(Uri url) => w.loadRequest(url);
  @override
  Future<void> loadHtml(String html) => w.loadHtmlString(html);
  @override
  Future<void> run(String script) => w.runJavaScript(script);
  @override
  Future<void> reload() => w.reload();
  @override
  Future<void> goBack() => w.goBack();
  @override
  Future<void> goForward() => w.goForward();
  @override
  Future<bool> canGoBack() => w.canGoBack();
  @override
  Future<String?> title() => w.getTitle();
  @override
  Future<bool> isEmpty() async =>
      '${await w.runJavaScriptReturningResult('!(document.head?.firstElementChild || document.body?.firstElementChild)')}' == 'true';
}

/// A sheet's bridge under [nonce]; each part installs once per document, so the finish run skips what a head installed.
/// The nonce stays in the closure: a script without it can neither post nor resolve a reply.
String bridgeScript(String nonce, {String? helper, String? adapter}) =>
    '''
(() => {
  if (!Object.getOwnPropertyDescriptor(window, '__elisReply')) {
    const n = '$nonce';
    const post = ElisChannel.postMessage.bind(ElisChannel);
    const pending = new Map();
    let next = 0;
    Object.defineProperty(window, '__elisReply', {value: (nonce, id, ok, value) => {
      if (nonce !== n) return;
      const waiting = pending.get(id);
      if (!waiting) return;
      pending.delete(id);
      if (ok) waiting.resolve(value); else waiting.reject(new Error(String(value)));
    }});
    Object.defineProperty(window, '__elis', {value: Object.freeze({
      postMessage(body) {
        const id = ++next;
        post(JSON.stringify({n, id, body}));
        return new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
      },
    })});
    window.close = () => post(JSON.stringify({n, close: true}));
  }
  ${helper == null ? '' : "if (!Object.getOwnPropertyDescriptor(window, 'elis')) $helper"}
  ${adapter == null ? '' : "if (!Object.getOwnPropertyDescriptor(window, '__elisAdapter')) { Object.defineProperty(window, '__elisAdapter', {value: true}); $adapter }"}
})();
''';

/// A --js file page's bridge and `elis.request` ahead of its own scripts, in the main frame only, as on the Mac;
/// the element removes itself so the nonce does not stay in the document.
String headTag(String nonce, String helper) {
  final script = bridgeScript(nonce, helper: helper).replaceAllMapped(RegExp('</(script)', caseSensitive: false), (m) => '<\\/${m[1]}');
  return '<script>document.currentScript.remove(); if (window.top === window) $script</script>';
}
