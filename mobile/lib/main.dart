import 'package:flutter/material.dart';

import 'client.dart';
import 'model.dart';
import 'screens/home.dart';
import 'screens/pair.dart';
import 'screens/session.dart';
import 'theme.dart';
import 'watch.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HangarApp());
}

/// The paired computers and the one on screen.
class Computers extends ChangeNotifier {
  List<Pairing> all = [];
  HangarModel? current;
  bool loaded = false;

  Future<void> load() async {
    try {
      all = await PairingStore.load();
    } catch (_) {
      all = []; // an unreadable keystore entry (e.g. after a backup restore): pair again
    }
    loaded = true;
    if (all.isNotEmpty) open(all.first);
    notifyListeners();
  }

  void open(Pairing p) {
    current?.dispose();
    current = HangarModel(p)..start();
    Watch.check(ask: true);
    notifyListeners();
  }

  Future<void> add(Pairing p) async {
    all = [p, ...all.where((x) => x.key != p.key && (x.host == null || x.address != p.address))];
    await PairingStore.save(all);
    open(p);
  }

  Future<void> forget(Pairing p) async {
    all = all.where((x) => x.key != p.key).toList();
    await PairingStore.save(all);
    if (current?.pairing.key == p.key) {
      current?.dispose();
      current = null;
      if (all.isNotEmpty) open(all.first);
    }
    notifyListeners();
  }
}

class HangarApp extends StatefulWidget {
  const HangarApp({super.key});

  @override
  State<HangarApp> createState() => _HangarAppState();
}

class _HangarAppState extends State<HangarApp> {
  final computers = Computers();
  final nav = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    String? launched;
    try {
      launched = await Watch.init(openSession);
    } catch (_) {
      // no notifications: the app works without background alerts
    }
    await BluetoothPref.load().catchError((_) {});
    await computers.load();
    if (launched != null) openSession(launched);
  }

  // a notification's tap: that session on the computer on screen, over the home screen
  void openSession(String id) {
    final m = computers.current;
    if (m == null) return;
    nav.currentState
      ?..popUntil((r) => r.isFirst)
      ..push(MaterialPageRoute(builder: (_) => SessionScreen(model: m, sessionId: id)));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: nav,
        title: 'Hangar',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: ListenableBuilder(
          listenable: computers,
          builder: (context, _) {
            if (!computers.loaded) return const Scaffold();
            final m = computers.current;
            if (m == null) return PairScreen(onPaired: computers.add);
            return HomeScreen(key: ValueKey(m.pairing.key), model: m, computers: computers);
          },
        ),
      );
}
