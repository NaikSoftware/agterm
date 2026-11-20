// A session's pages on the phone (`PhoneLinkPages.swift` owns the wire).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../client.dart';
import '../link/mux.dart';

/// Reserved fetch paths for a content page's HTML and renderer script; no origin path lacks the leading `/`.
const contentPath = 'elis:content', scriptPath = 'elis:script';

class PhonePage {
  PhonePage._(Map<String, dynamic> o)
      : id = '${o['id']}',
        kind = '${o['kind']}',
        title = '${o['title'] ?? ''}',
        path = o['path'] as String?,
        url = o['url'] as String?,
        adapter = o['adapter'] as String?,
        helper = o['helper'] as String?,
        javascript = o['javascript'] == true,
        chromeless = o['chromeless'] == true,
        browse = o['browse'] == true,
        hidden = o['hidden'] == true,
        sizePercent = o['sizePercent'] as int?;

  final String id, kind, title;
  final String? path, url, adapter, helper;
  final bool javascript, chromeless, browse;
  bool hidden;
  int? sizePercent;

  /// The newest command's seq, reported back so the origin knows which commands the sheet has applied.
  int appliedSeq = 0;
}

class PageCommand {
  PageCommand(this.id, this.seq, this.action, this.sizePercent);
  final String id, action;
  final int seq;
  final int? sizePercent;
}

class PageFile {
  PageFile(this.mime, this.bytes);
  final String mime;
  final Stream<List<int>> bytes;
}

class _Fetch {
  _Fetch(this.page);
  final String page;
  final file = Completer<PageFile>();
  final bytes = StreamController<List<int>>();
}

const _maxBridge = 256 << 10; // PageServeCodec.maxFrameBytes, the origin frame that carries the line

/// 128 random bits as hex, for a sheet's server secret and its nonce.
String randomHex128() {
  final random = Random.secure();
  return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

class PageLink extends ChangeNotifier {
  PageLink(Mux mux, String target) : _channel = mux.present(target) {
    _lines = _channel.lines.listen(_line, onDone: _ended);
    // every failure also ends the channel, which `_ended` handles; only an older relay changes `supported`
    _channel.opened.catchError((Object e) {
      if (e is ElisError && e.message == 'unsupported channel type') {
        supported = false;
        if (!_disposed) notifyListeners();
      }
    });
  }

  final PresentChannel _channel;
  late final StreamSubscription<Map<String, dynamic>> _lines;
  final _pages = <String, PhonePage>{}; // oldest first
  final _commands = StreamController<PageCommand>.broadcast();
  final _fetches = <int, _Fetch>{};
  final _bridges = <int, ({String page, Completer<String> reply})>{};
  var _seq = 0;
  var _disposed = false;

  /// False once an older relay refused the channel; the session runs without pages.
  bool supported = true;

  PhonePage? get page => _pages.isEmpty ? null : _pages.values.last;

  /// Why the channel ended, once it has.
  String? get ended => _channel.ended;

  Stream<PageCommand> get commands => _commands.stream;

  /// Completes on the first `res` line; the rest of the file follows on [PageFile.bytes].
  Future<PageFile> fetch(String id, String path) {
    final seq = ++_seq;
    final f = _fetches[seq] = _Fetch(id);
    _send({'t': 'fetch', 'id': id, 'seq': seq, 'path': path});
    return f.file.future;
  }

  /// The origin's raw JSON reply to a page's bridge [line].
  Future<String> bridge(String id, String line) {
    final seq = ++_seq;
    final out = {'t': 'bridge', 'id': id, 'seq': seq, 'line': line};
    if (utf8.encode(jsonEncode(out)).length >= _maxBridge) return Future.error(ElisError('the request is too large'));
    final c = Completer<String>();
    _bridges[seq] = (page: id, reply: c);
    _send(out);
    return c.future;
  }

  void report(String id, {required String load, String? title, String? current, bool canGoBack = false, String? error}) {
    final p = _pages[id];
    if (p == null) return;
    _send({
      't': 'state', 'id': id, 'load': load, 'title': ?title, 'current': ?current, 'canGoBack': canGoBack,
      'appliedSeq': p.appliedSeq, 'hidden': p.hidden, 'error': ?error,
    });
  }

  /// A swipe or the chip; the sheet reports the change.
  void setHidden(PhonePage page, bool hidden) {
    page.hidden = hidden;
    notifyListeners();
  }

  void closed(String id, {required bool dismissed}) {
    _send({'t': 'closed', 'id': id, 'dismissed': dismissed});
    _drop(id);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_lines.cancel()); // lines the channel still holds would reach a disposed notifier
    unawaited(_channel.close());
    _ended();
    unawaited(_commands.close());
    super.dispose();
  }

  void _send(Map<String, dynamic> line) {
    if (_channel.ended == null) return _channel.send(line);
    if (line['t'] == 'fetch') _fail(line['seq'] as int, _channel.ended!);
    if (line['t'] == 'bridge') _bridges.remove(line['seq'])?.reply.completeError(ElisError(_channel.ended!));
  }

  void _line(Map<String, dynamic> o) {
    try {
      _apply(o);
    } on Object {
      // a line with a wrong JSON type is dropped
    }
  }

  void _apply(Map<String, dynamic> o) {
    switch (o['t']) {
      case 'page':
        final p = PhonePage._(o);
        _failRequests('page sent again', page: p.id); // the relay forgot them with the old page
        _pages.remove(p.id); // a page sent again is the newest
        _pages[p.id] = p;
        notifyListeners();
      case 'command':
        final (id, seq, action, size) = ('${o['id']}', o['seq'] as int? ?? 0, '${o['action']}', o['sizePercent'] as int?);
        final p = _pages[id];
        if (p == null) return;
        if (action == 'close') return _drop(id);
        if (seq > p.appliedSeq) p.appliedSeq = seq;
        if (action == 'hide' || action == 'show') p.hidden = action == 'hide';
        if (action == 'resize') p.sizePercent = size;
        if (action == 'hide' || action == 'show' || action == 'resize') notifyListeners();
        _commands.add(PageCommand(id, seq, action, size));
      case 'res':
        _res(o);
      case 'reply':
        final c = _bridges.remove(o['seq'])?.reply;
        if (o['error'] case final error?) return c?.completeError(ElisError('$error'));
        c?.complete('${o['response'] ?? ''}');
    }
  }

  void _res(Map<String, dynamic> o) {
    final seq = o['seq'] as int?;
    final f = _fetches[seq];
    if (f == null) return;
    if (o['error'] case final error?) return _fail(seq!, '$error');
    if (!f.file.isCompleted) f.file.complete(PageFile('${o['mime'] ?? 'application/octet-stream'}', f.bytes.stream));
    if (o['data'] case final String data) {
      try {
        f.bytes.add(base64Decode(data));
      } on FormatException {
        return _fail(seq!, 'bad res');
      }
    }
    if (o['end'] == true) {
      _fetches.remove(seq);
      unawaited(f.bytes.close());
    }
  }

  void _fail(int seq, String error) {
    final f = _fetches.remove(seq);
    if (f == null) return;
    if (!f.file.isCompleted) return f.file.completeError(ElisError(error));
    f.bytes.addError(ElisError(error));
    unawaited(f.bytes.close());
  }

  /// The relay forgets a closed page's requests without answering them.
  void _drop(String id) {
    _failRequests('page closed', page: id);
    if (_pages.remove(id) != null) notifyListeners();
  }

  /// Fails the requests of [page], or of every page.
  void _failRequests(String reason, {String? page}) {
    for (final MapEntry(key: seq, value: f) in _fetches.entries.toList()) {
      if (page == null || f.page == page) _fail(seq, reason);
    }
    for (final MapEntry(key: seq, value: b) in _bridges.entries.toList()) {
      if (page == null || b.page == page) _bridges.remove(seq)!.reply.completeError(ElisError(reason));
    }
  }

  /// The channel ended: every page leaves the phone and every request fails.
  void _ended() {
    _failRequests(_channel.ended ?? 'closed');
    _pages.clear();
    if (!_disposed) notifyListeners(); // the screen opens the channel again
  }
}
