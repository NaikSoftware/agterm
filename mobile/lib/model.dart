// One paired computer's live state: the connection, its windows and workspace tree, refreshed from the app's events.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'client.dart';

class Session {
  Session(Map m, this.workspaceId, this.workspaceName)
      : id = m['id'] ?? '',
        name = (m['name'] as String?)?.isNotEmpty == true ? m['name'] : 'New session',
        status = m['status'] ?? 'idle',
        agent = m['agent'] ?? '',
        cwd = m['cwd'] ?? '',
        parent = m['parent'] ?? '',
        context = m['context'] ?? '',
        tint = m['tint'] ?? '',
        unseen = (m['unseen'] as num?)?.toInt() ?? 0,
        flagged = m['flagged'] == true,
        active = m['active'] == true,
        blink = m['blink'] == true,
        hasSplit = m['hasSplit'] == true,
        split = m['split'] == true,
        collapsed = m['collapsed'] == true;

  final String id, name, status, agent, cwd, parent, context, tint, workspaceId, workspaceName;
  final int unseen;
  final bool flagged, active, blink, hasSplit, split, collapsed;

  bool get needsYou => status == 'blocked' || status == 'completed';
  String get shortCwd => cwd.replaceFirst(RegExp(r'^/home/[^/]+'), '~');
}

class Workspace {
  Workspace(Map m)
      : id = m['id'] ?? '',
        name = m['name'] ?? '',
        folder = m['rememberedFolder'] ?? '',
        tint = m['tint'] ?? '',
        active = m['active'] == true,
        sessions = [for (final s in (m['sessions'] as List? ?? const [])) Session(s as Map, m['id'] ?? '', m['name'] ?? '')];

  final String id, name, folder, tint;
  final bool active;
  final List<Session> sessions;
}

class AgWindow {
  AgWindow(Map m)
      : id = m['id'] ?? '',
        name = m['name'] ?? '',
        open = m['open'] == true,
        active = m['active'] == true;
  final String id, name;
  final bool open, active;
}

/// Something worth telling the user about: an agent blocked or finished, or a notification it raised.
class Alert {
  Alert(this.sessionId, this.title, this.body, this.status);
  final String sessionId, title, body, status;
}

/// The pairings live in the platform keystore: each one carries the secret token.
class PairingStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'pairings';

  static Future<List<Pairing>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return [];
    return [for (final j in jsonDecode(raw) as List) Pairing.fromJson((j as Map).cast<String, dynamic>())];
  }

  static Future<void> save(List<Pairing> all) => _storage.write(key: _key, value: jsonEncode([for (final p in all) p.toJson()]));
}

enum LinkState { connecting, connected, offline }

class AgtermModel extends ChangeNotifier {
  AgtermModel(this.pairing) {
    _lifecycle = AppLifecycleListener(onResume: resume, onPause: pause);
  }

  final Pairing pairing;
  late final AppLifecycleListener _lifecycle;
  Connection? _c;
  LinkState state = LinkState.connecting;
  String? error;
  List<AgWindow> windows = [];
  String? windowId; // null = the frontmost window
  List<Workspace> workspaces = [];
  bool loaded = false;
  final _alerts = StreamController<Alert>.broadcast();
  Stream<Alert> get alerts => _alerts.stream;
  bool _running = false, _disposed = false;
  int _generation = 0; // bumps on every (re)connect, so a stale loop stops
  Timer? _refreshSoon;

  Iterable<Session> get sessions => workspaces.expand((w) => w.sessions);
  Session? session(String id) => sessions.where((s) => s.id == id).firstOrNull;
  AgWindow? get window => windows.where((w) => w.id == windowId).firstOrNull ?? windows.where((w) => w.active).firstOrNull;

  void start() {
    if (_running) return;
    _running = true;
    _connectLoop();
  }

  void pause() {
    _running = false;
    _generation++;
    _c?.close();
    _c = null;
  }

  void resume() => start();

  Future<void> _connectLoop() async {
    var backoff = 1;
    while (_running && !_disposed) {
      final gen = ++_generation;
      _set(LinkState.connecting);
      try {
        _c = await Connection.open(pairing);
        if (gen != _generation) return _c?.close();
        error = null;
        backoff = 1;
        _set(LinkState.connected);
        await refresh();
        unawaited(_eventLoop(gen));
        await _c!.closed;
      } on AgtermError catch (e) {
        error = e.message;
      } catch (e) {
        error = 'Cannot reach ${pairing.host}:${pairing.port}. Is `agtermctl mobile serve` running?';
      }
      if (gen != _generation || _disposed) return;
      _set(LinkState.offline);
      await Future.delayed(Duration(seconds: backoff));
      backoff = (backoff * 2).clamp(1, 15);
    }
  }

  void _set(LinkState s) {
    state = s;
    if (!_disposed) notifyListeners();
  }

  /// A control command; window-addressed commands go to the window on screen.
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, bool windowed = true}) {
    final c = _c;
    if (c == null || state != LinkState.connected) return Future.error(AgtermError('Not connected'));
    return c.call(cmd, target: target, args: args, window: windowed ? windowId : null);
  }

  /// Run a command, then refresh the tree; the error text on failure, null on success.
  Future<String?> act(String cmd, {String? target, Map<String, dynamic>? args}) async {
    try {
      await call(cmd, target: target, args: args);
      scheduleRefresh(const Duration(milliseconds: 150));
      return null;
    } on AgtermError catch (e) {
      return e.message;
    } on TimeoutException {
      return 'The computer did not answer';
    }
  }

  Future<void> refresh() async {
    try {
      final w = await call('window.list', windowed: false);
      windows = [for (final m in (w['windows'] as List? ?? const [])) AgWindow(m as Map)];
      if (windowId != null && !windows.any((x) => x.id == windowId && x.open)) windowId = null;
      final t = await call('tree');
      workspaces = [for (final m in ((t['tree'] as Map?)?['workspaces'] as List? ?? const [])) Workspace(m as Map)];
      loaded = true;
      if (!_disposed) notifyListeners();
    } on AgtermError catch (e) {
      error = e.message;
      if (!_disposed) notifyListeners();
    } on TimeoutException {
      // the next event or poll retries
    }
  }

  void scheduleRefresh([Duration delay = const Duration(milliseconds: 250)]) {
    _refreshSoon?.cancel();
    _refreshSoon = Timer(delay, refresh);
  }

  void selectWindow(String? id) {
    windowId = id;
    loaded = false;
    notifyListeners();
    refresh();
  }

  // polls events.read with agtermctl's cursor rules: anchor with no cursor, then {run, after: "<next>"}
  Future<void> _eventLoop(int gen) async {
    String? run;
    var next = '0';
    while (gen == _generation && !_disposed) {
      try {
        final r = await call('events.read', args: run == null ? {} : {'run': run, 'after': next, 'limit': 200}, windowed: false);
        final ev = r['events'] as Map;
        run = ev['run'];
        next = '${ev['next']}';
        final items = ev['items'] as List? ?? const [];
        if (items.isNotEmpty) {
          for (final e in items) {
            _onEvent((e as Map).cast<String, dynamic>());
          }
          scheduleRefresh();
        }
        await Future.delayed(Duration(milliseconds: items.isEmpty ? 1000 : 150));
      } on AgtermError catch (e) {
        if (e.message == 'Disconnected' || e.message == 'Not connected') return;
        run = null; // "event run changed" (the app restarted) or "event cursor expired": start over
        scheduleRefresh(Duration.zero);
        await Future.delayed(const Duration(seconds: 1));
      } on TimeoutException {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final p = (e['payload'] as Map?)?.cast<String, dynamic>() ?? {};
    final sid = e['session'] as String? ?? '';
    switch (e['kind']) {
      case 'status' when p['status'] == 'blocked' || p['status'] == 'completed':
        _alerts.add(Alert(sid, '${p['name'] ?? 'Session'}', p['status'] == 'blocked' ? 'needs your input' : 'finished', p['status']));
      case 'notify':
        _alerts.add(Alert(sid, '${p['title'] ?? p['name'] ?? 'Notification'}', '${p['body'] ?? ''}', 'notify'));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _generation++;
    _refreshSoon?.cancel();
    _lifecycle.dispose();
    _c?.close();
    _alerts.close();
    super.dispose();
  }
}
