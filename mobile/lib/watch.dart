// Background alerts: while the app is in the background a foreground service holds the process, and with it the
// model's one connection, up; the agents' alerts then become notifications.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ble_transport.dart';
import 'model.dart';

class Watch {
  static final _n = FlutterLocalNotificationsPlugin();
  static AndroidFlutterLocalNotificationsPlugin? get _android => _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  static const _storage = FlutterSecureStorage();
  static const _key = 'watch';
  static bool enabled = true, permitted = false;

  static bool get on => enabled && permitted;

  /// Reads the toggle and routes taps to [onTap]; the session whose notification launched the app, if one did.
  static Future<String?> init(void Function(String sessionId) onTap) async {
    enabled = await _storage.read(key: _key) != 'off';
    await _android?.deleteNotificationChannel(channelId: 'watch'); // the old status channel badged the app icon; a channel's badge can't change
    await _n.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat')),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload?.isNotEmpty == true) onTap(r.payload!);
      },
    );
    await check();
    final l = await _n.getNotificationAppLaunchDetails();
    final id = l?.didNotificationLaunchApp == true ? l!.notificationResponse?.payload : null;
    return id?.isNotEmpty == true ? id : null;
  }

  /// Whether notifications may show; with [ask], asks for them (Android 13+) if watching is on.
  static Future<void> check({bool ask = false}) async {
    final a = _android;
    if (a != null) permitted = (ask && enabled ? await a.requestNotificationsPermission() : await a.areNotificationsEnabled()) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    enabled = v;
    await _storage.write(key: _key, value: v ? 'on' : 'off');
    if (v) await check(ask: true);
  }

  static Future<void> start(String computer) async => _android?.startForegroundService(
        id: 1,
        title: 'Watching $computer',
        body: 'Tells you when an agent needs you',
        notificationDetails: const AndroidNotificationDetails('watching', 'Watching',
            channelDescription: 'Shown while Agterm2 watches your computer in the background',
            importance: Importance.low, priority: Priority.low, ongoing: true, showWhen: false,
            channelShowBadge: false, icon: 'ic_watch'), // the icon's dot means an agent alert, not that the app is watching
        startType: AndroidServiceStartType.startNotSticky, // the plugin's service can't restart without its intent
        foregroundServiceTypes: {
          AndroidServiceForegroundType.foregroundServiceTypeSpecialUse,
          // Android 14+ refuses connectedDevice without BLUETOOTH_CONNECT; TLS alone keeps specialUse
          if (await bluetoothGranted()) AndroidServiceForegroundType.foregroundServiceTypeConnectedDevice,
        },
      );

  /// Back in the foreground: the screen shows what the notifications said.
  static Future<void> stop() async {
    await _android?.stopForegroundService();
    await _n.cancelAll();
  }

  static Future<void> show(Alert a, String workspace) async {
    for (final n in alertNotifications(a, workspace)) {
      await _n.show(id: n.id, title: n.title, body: n.body, payload: n.payload, notificationDetails: NotificationDetails(android: n.details));
    }
  }
}

/// One notification per session, updated in place, plus its workspace's group summary, which Android needs to stack them.
/// The id is also the tap intent's request code, so it must differ per session.
List<({int id, String title, String body, String payload, AndroidNotificationDetails details})> alertNotifications(Alert a, String workspace) {
  final name = workspace.isEmpty ? 'Sessions' : workspace;
  AndroidNotificationDetails details({bool summary = false}) => AndroidNotificationDetails('alerts', 'Agent alerts',
      channelDescription: 'An agent is blocked, has finished, or sent a notification',
      importance: Importance.high, priority: Priority.high, category: AndroidNotificationCategory.message,
      subText: name, groupKey: 'ws:$name', setAsGroupSummary: summary, groupAlertBehavior: GroupAlertBehavior.children);
  return [
    (id: a.sessionId.hashCode & 0x7fffffff, title: a.title, body: a.body, payload: a.sessionId, details: details()),
    (id: 'ws:$name'.hashCode & 0x7fffffff, title: name, body: '', payload: '', details: details(summary: true)),
  ];
}
