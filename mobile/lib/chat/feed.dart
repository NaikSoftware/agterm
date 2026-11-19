import 'dart:async';

import 'package:flutter/foundation.dart';

import 'transcript.dart';

/// Polls the tail of a `session.transcript` and pages back through it (plan A's cursor contract).
class TranscriptFeed extends ChangeNotifier {
  TranscriptFeed({required this.call, required this.canPoll, required bool remote})
      : interval = remote ? const Duration(seconds: 2) : const Duration(milliseconds: 700);

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> args) call;
  final bool Function() canPoll;
  final Duration interval;

  final List<ChatItem> items = [];
  List<PendingCall> pending = const [];
  TranscriptMeta? meta;
  List<SlashCommand> commands = const [];
  String? transcript;
  bool loading = true, loadingEarlier = false, stale = false;
  TranscriptError? error;
  final Set<String> fresh = {};
  int switches = 0;

  int? _start;
  int _next = 0;
  // bumped by every drop; a reply asked for under an older generation is discarded
  int _gen = 0;
  bool _running = false, _inFlight = false, _disposed = false;
  Timer? _timer, _staleTimer;

  bool get atStart => _start == 0;

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(interval, (_) => pollNow());
    unawaited(pollNow());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _staleTimer?.cancel();
    _timer = _staleTimer = null;
  }

  void retry() {
    error = null;
    _drop();
    if (_running) _timer ??= Timer.periodic(interval, (_) => pollNow());
    unawaited(pollNow());
  }

  Future<void> pollNow() async {
    if (_inFlight || !_running || _disposed || !canPoll()) return;
    _inFlight = true;
    final gen = _gen;
    final held = transcript;
    var again = false;
    try {
      final page = TranscriptPage.fromJson(await call({if (held != null) ...{'after': '$_next', 'transcript': held}}));
      if (gen != _gen || _disposed) {
        again = true;
      } else {
        again = _apply(page, held);
      }
    } on TimeoutException {
      // no reply: stale covers it
    } catch (e) {
      if (gen == _gen && !_disposed) _fail(TranscriptError.of('$e'));
    } finally {
      _inFlight = false;
    }
    if (again) unawaited(pollNow());
  }

  Future<void> loadEarlier() async {
    if (loadingEarlier || transcript == null || atStart || _disposed) return;
    loadingEarlier = true;
    _notify();
    final gen = _gen;
    final held = transcript;
    try {
      final page = TranscriptPage.fromJson(await call({'before': '$_start', 'transcript': held}));
      if (gen != _gen || _disposed || page.transcript != held) return;
      final have = {for (final i in items) i.uuid};
      items.insertAll(0, page.items.where((i) => !have.contains(i.uuid)));
      _start = page.start;
    } catch (_) {
      // the "Loading earlier" row goes away; scrolling up asks again
    } finally {
      if (gen == _gen) {
        loadingEarlier = false;
        _notify();
      }
    }
  }

  /// Applies a tail reply; true when the next poll should run at once.
  bool _apply(TranscriptPage page, String? held) {
    if (held != null && (page.reset || page.transcript != held)) {
      _drop();
      return true;
    }
    if (held == null) {
      items
        ..clear()
        ..addAll(page.items);
      _start = page.start;
    } else {
      for (final i in page.items) {
        final at = items.indexWhere((h) => h.uuid == i.uuid);
        if (at >= 0) {
          items[at] = i;
        } else {
          items.add(i);
          fresh.add(i.uuid);
        }
      }
    }
    transcript = page.transcript;
    _next = page.next;
    meta = page.meta;
    pending = page.pending;
    if (page.commands != null) commands = page.commands!;
    error = null;
    _answered();
    _notify();
    return page.next < page.size;
  }

  void _fail(TranscriptError e) {
    error = e;
    if (e == TranscriptError.hostTooOld) {
      _timer?.cancel();
      _timer = null;
    }
    _answered();
    _notify();
  }

  void _answered() {
    loading = stale = false;
    _staleTimer?.cancel();
    _staleTimer = Timer(interval * 2, () {
      stale = true;
      _notify();
    });
  }

  void _drop() {
    _gen++;
    switches++;
    items.clear();
    fresh.clear();
    pending = const [];
    transcript = _start = null;
    _next = 0;
    loading = true;
    loadingEarlier = stale = false;
    _staleTimer?.cancel();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
