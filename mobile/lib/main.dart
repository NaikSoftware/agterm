import 'package:flutter/material.dart';

import 'client.dart';
import 'model.dart';
import 'screens/home.dart';
import 'screens/pair.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AgtermApp());
}

/// The paired computers and the one on screen.
class Computers extends ChangeNotifier {
  List<Pairing> all = [];
  AgtermModel? current;
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
    current = AgtermModel(p)..start();
    notifyListeners();
  }

  Future<void> add(Pairing p) async {
    all = [p, ...all.where((x) => x.key != p.key && x.fingerprint != p.fingerprint)];
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

class AgtermApp extends StatefulWidget {
  const AgtermApp({super.key});

  @override
  State<AgtermApp> createState() => _AgtermAppState();
}

class _AgtermAppState extends State<AgtermApp> {
  final computers = Computers()..load();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'agterm',
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
