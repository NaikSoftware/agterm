// One paired computer's live state: the connection, its windows and workspace tree, refreshed from the app's events.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ble_transport.dart';
import 'client.dart';
import 'link/mux.dart';
import 'watch.dart';

// the computer's home folder: /home/<name> on Linux, /Users/<name> on macOS
final homePrefix = RegExp(r'^/(home|Users)/[^/]+');
String shortHome(String path) => path.replaceFirst(homePrefix, '~');
String expandHome(String path, String home) => path.replaceFirst(RegExp(r'^~(?=/|$)'), home);

// The macOS tree reports no `agent`, only the pane's foreground argv: name the agent the way its
// SessionLauncher.agent(argv:) does, including a script install run as `node /path/claude`.
String agentOf(List<String> argv) {
  const commands = {'claude': 'claude', 'codex': 'codex', 'opencode': 'opencode', 'agy': 'antigravity'};
  String base(String a) => a.split('/').last;
  if (argv.isEmpty) return '';
  if (commands[base(argv.first)] case final a?) return a;
  if (!const {'node', 'bun', 'deno'}.contains(base(argv.first))) return '';
  final script = argv.skip(1).where((a) => !a.startsWith('-')).firstOrNull;
  return script == null ? '' : commands[base(script)] ?? '';
}

class Session {
  Session(Map m, this.workspaceId, this.workspaceName)
      : id = m['id'] ?? '',
        name = (m['name'] as String?)?.isNotEmpty == true ? m['name'] : 'New session',
        status = m['status'] ?? 'idle',
        agent = (m['agent'] as String?)?.isNotEmpty == true ? m['agent'] : agentOf((m['foreground'] as List?)?.cast<String>() ?? const []),
        liveAgent = m['agent'] ?? '',
        agentSessionId = m['agentSessionId'] ?? '',
        agentPane = m['agentPane'] ?? 'left',
        remoteHost = m['remoteHost'] ?? '',
        remote = (m['remoteHost'] as String?)?.isNotEmpty == true,
        cwd = m['cwd'] ?? '',
        parent = m['parent'] ?? '',
        context = m['context'] ?? '',
        tint = m['tint'] ?? '',
        unseen = (m['unseen'] as num?)?.toInt() ?? 0,
        flagged = m['flagged'] == true,
        active = m['active'] == true,
        blink = (m['blink'] ?? m['statusBlink']) == true,
        hasSplit = m['hasSplit'] == true,
        livePanes = {
          for (final f in (m['surfaces'] as List? ?? const []))
            // a remote terminal row runs on its origin's zmx, which the Mac's own backedByZmx never reports
            if (f is Map && (f['backedByZmx'] == true || (m['remoteHost'] as String?)?.isNotEmpty == true && m['content'] != 'page'))
              '${f['kind']}',
        },
        split = m['split'] == true,
        collapsed = m['collapsed'] == true;

  final String liveAgent; // the tree's own `agent`; `agent` above also guesses from the foreground
  final String agentSessionId, agentPane, remoteHost;
  final bool remote;
  final String id, name, status, agent, cwd, parent, context, tint, workspaceId, workspaceName;
  final int unseen;
  final bool flagged, active, blink, hasSplit, split, collapsed;
  final Set<String> livePanes; // the panes (`left`, `right`) a zmx daemon backs: the phone can watch them as a terminal

  bool get needsYou => status == 'blocked' || status == 'completed';
  String get shortCwd => shortHome(cwd);
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

/// Fit to phone while a session screen is in front: the grid follows the phone only while someone looks at it there,
/// and goes back to the computer's view when the screen closes or the app leaves the foreground.
class AutoFit {
  bool wanted = true; // off once the phone's button or the computer gives the grid back, so neither side fights the other

  /// The grid change to make now: true to fit, false to give the grid back, null for none.
  bool? next({required bool fitted, required bool visible}) => switch ((wanted && visible, fitted)) {
        (true, false) => true,
        (false, true) => false,
        _ => null,
      };
}

/// Something worth telling the user about: an agent blocked or finished, or a notification it raised.
class Alert {
  Alert(this.sessionId, this.title, this.body, this.status);
  final String sessionId, title, body, status;

  /// The alert an app event raises, if any.
  static Alert? of(Map<String, dynamic> e) {
    final p = (e['payload'] as Map?)?.cast<String, dynamic>() ?? {};
    final sid = e['session'] as String? ?? '';
    return switch (e['kind']) {
      'status' when p['status'] == 'blocked' || p['status'] == 'completed' =>
        Alert(sid, '${p['name'] ?? 'Session'}', p['status'] == 'blocked' ? 'needs your input' : 'finished', p['status']),
      // the session names the alert, as the status alerts do; a terminal title ("Claude Code") is only a fallback body
      'notify' => Alert(sid, '${p['name'] ?? p['title'] ?? 'Notification'}',
          '${(p['body'] as String?)?.isNotEmpty == true ? p['body'] : p['name'] != null && p['title'] != p['name'] ? p['title'] ?? '' : ''}', 'notify'),
      _ => null,
    };
  }
}

/// The pairings live in the platform keystore: each one carries the secret token.
class PairingStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'pairings';

  static Future<List<Pairing>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return [];
    return decode(raw);
  }

  // pairings were keyed by host:port before Bluetooth; two of them for one certificate keep the first (the newest)
  @visibleForTesting
  static List<Pairing> decode(String raw) {
    final seen = <String>{};
    return [
      for (final j in jsonDecode(raw) as List)
        if (Pairing.fromJson((j as Map).cast<String, dynamic>()) case final p when seen.add(p.key)) p,
    ];
  }

  static Future<void> save(List<Pairing> all) => _storage.write(key: _key, value: jsonEncode([for (final p in all) p.toJson()]));
}

/// "Prefer Bluetooth": try it before TLS.
class BluetoothPref {
  static const _storage = FlutterSecureStorage();
  static const _key = 'preferBluetooth';
  static bool prefer = false;

  static Future<void> load() async => prefer = await _storage.read(key: _key) == 'on';

  static Future<void> set(bool v) async {
    prefer = v;
    await _storage.write(key: _key, value: v ? 'on' : 'off');
  }
}

/// "Show composer": the session screen's text field under the key row.
class ComposerPref {
  static const _storage = FlutterSecureStorage();
  static const _key = 'showComposer';
  static bool shown = false;

  static Future<void> load() async => shown = await _storage.read(key: _key) == 'on';

  static Future<void> set(bool v) async {
    shown = v;
    await _storage.write(key: _key, value: v ? 'on' : 'off');
  }
}

/// What the screen says when no transport connected; [unseen] is how long no Bluetooth scan has matched.
String connectError(Object e, Pairing p, Duration unseen) => switch (e) {
      ElisError() => e.message,
      BleNotFound() when unseen >= const Duration(minutes: 2) =>
        "Can't find ${p.name}: out of range, Bluetooth off, or the pairing was reset.",
      BleNotFound() => 'Looking for ${p.name} over Bluetooth…',
      _ when p.host == null => 'Cannot reach ${p.name} over Bluetooth. Is phone access on?',
      _ => 'Cannot reach ${p.host}:${p.port}. Is `elisctl mobile serve` running?',
    };

enum LinkState { connecting, connected, offline }

class ElisModel extends ChangeNotifier {
  ElisModel(this.pairing, {@visibleForTesting this.open = Connection.open}) {
    _lifecycle = AppLifecycleListener(onResume: resume, onPause: _background);
  }

  final Pairing pairing;
  final Future<Connection> Function(Pairing p, {bool preferBluetooth}) open;
  late final AppLifecycleListener _lifecycle;
  Connection? _c;
  Mux? mux; // null on a relay before the mux (M4a): screens keep the text view
  bool muxing = false; // the link has a mux that [mux] is not set to yet
  LinkState state = LinkState.connecting;
  String via = ''; // the live transport's badge: 'Wi-Fi' or 'BT'
  @visibleForTesting
  DateTime seen = DateTime.now(); // the last Bluetooth scan match, connect or resume: "Can't find" needs 2 real minutes
  String? error;
  List<AgWindow> windows = [];
  String? windowId; // null = the frontmost window
  List<Workspace> workspaces = [];
  bool loaded = false;
  final _alerts = StreamController<Alert>.broadcast();
  Stream<Alert> get alerts => _alerts.stream;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream; // every event read, alerting or not
  bool _running = false, _disposed = false;
  final fitted = <String, (int, int)>{}; // "session/pane" whose grid is set to this phone's → its columns and rows
  bool background = false; // in the background with the connection kept up for alerts: screens stop polling
  int _generation = 0; // bumps on every (re)connect, so a stale loop stops
  String? _run; // the events cursor outlives a reconnect, so what happened while offline still alerts
  String _next = '0';
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
    fitted.clear(); // the computer gives back every grid this phone set when the link closes
    _run = null; // not watching: back in the foreground, only new events matter
    _generation++;
    _c?.close();
    _c = null;
    mux = null;
    muxing = false;
  }

  void resume() {
    if (background) Watch.stop();
    background = false;
    seen = DateTime.now();
    Watch.check();
    start();
  }

  void _background() {
    if (!Watch.on) return pause();
    background = true;
    Watch.start(pairing.name).onError((_, _) => pause()); // not allowed to start from the background here: plain pause
  }

  Future<void> _connectLoop() async {
    var backoff = 1;
    while (_running && !_disposed) {
      final gen = ++_generation;
      _set(LinkState.connecting);
      try {
        final c = await open(pairing, preferBluetooth: BluetoothPref.prefer);
        if (gen != _generation) return c.close();
        // first, before any other call: a large answer in flight could push the upgrade answer past its timeout
        final mx = await Mux.upgrade(c);
        if (gen != _generation) return c.close();
        // rows can be lost (`{"dropped":N}`, `{"gap":true}`), tree rows among them: re-read the tree
        mx?.events.where(rereadsTree).listen((_) => scheduleRefresh(Duration.zero));
        _c = c;
        via = c.via;
        error = null;
        backoff = 1;
        seen = DateTime.now();
        muxing = mx != null;
        _set(LinkState.connected);
        await refresh();
        // only now: a screen that saw the mux earlier would open panes from the tree of the link before
        mux = mx;
        if (!_disposed) notifyListeners();
        unawaited(_eventLoop(gen));
        await _c!.closed;
      } catch (e) {
        if (e is! BleNotFound) seen = DateTime.now();
        error = connectError(e, pairing, DateTime.now().difference(seen));
        if (e is Revoked) _running = false; // no transport can succeed: wait for a new pairing or a resume
      }
      if (gen != _generation || _disposed) return;
      _c?.close(); // a failure after connecting (e.g. in refresh) must not leak the connection
      _c = null;
      mux = null;
      muxing = false;
      fitted.clear();
      _set(LinkState.offline);
      await Future.delayed(Duration(seconds: backoff));
      if (gen != _generation || _disposed) return; // paused and resumed meanwhile: the new loop runs
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
    if (c == null || state != LinkState.connected) return Future.error(ElisError('Not connected'));
    return c.call(cmd, target: target, args: args, window: windowed ? windowId : null);
  }

  /// Run a command, then refresh the tree; the error text on failure, null on success.
  Future<String?> act(String cmd, {String? target, Map<String, dynamic>? args}) async {
    try {
      await call(cmd, target: target, args: args);
      scheduleRefresh(const Duration(milliseconds: 150));
      return null;
    } on ElisError catch (e) {
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
      if (background) Watch.clear(Watch.posted.read(sessions));
      if (!_disposed) notifyListeners();
    } on ElisError catch (e) {
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

  // polls events.read with elisctl's cursor rules: anchor with no cursor, then {run, after: "<next>"}
  Future<void> _eventLoop(int gen) async {
    while (gen == _generation && !_disposed) {
      try {
        final r = await call('events.read', args: _run == null ? {} : {'run': _run, 'after': _next, 'limit': 200}, windowed: false);
        final ev = r['events'] as Map;
        _run = ev['run'];
        _next = '${ev['next']}';
        final items = ev['items'] as List? ?? const [];
        if (items.isNotEmpty) {
          for (final e in items) {
            _onEvent((e as Map).cast<String, dynamic>());
          }
          scheduleRefresh();
        }
        await Future.delayed(Duration(milliseconds: items.isEmpty ? 1000 : 150));
      } on ElisError catch (e) {
        if (e.message == 'Disconnected' || e.message == 'Not connected') return;
        _run = null; // "event run changed" (the app restarted) or "event cursor expired": start over
        scheduleRefresh(Duration.zero);
        await Future.delayed(const Duration(seconds: 1));
      } on TimeoutException {
        await Future.delayed(const Duration(seconds: 1));
      } catch (_) {
        _run = null; // a malformed reply: start over rather than stop watching
        scheduleRefresh(Duration.zero);
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    _events.add(e);
    if (background && e['kind'] == 'session.closed') Watch.clear(Watch.posted.closed(e['session'] as String? ?? ''));
    final a = Alert.of(e);
    if (a == null) return;
    background ? Watch.show(a, session(a.sessionId)?.workspaceName ?? '') : _alerts.add(a);
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
    _events.close();
    super.dispose();
  }
}
