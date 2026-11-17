import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../ble_transport.dart';
import '../client.dart';
import '../model.dart';
import '../theme.dart';

class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.onPaired, this.canGoBack = false});
  final Future<void> Function(Pairing) onPaired;
  final bool canGoBack;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final link = TextEditingController();
  String? error;
  bool busy = false;

  Future<void> connect([String? text]) async {
    final p = Pairing.parse(text ?? link.text);
    if (p == null) return setState(() => error = 'That is not a pairing link. It starts with agterm://pair?');
    setState(() => (busy = true, error = null));
    try {
      if (p.bluetooth) await requestBluetooth(); // the one foreground moment to ask; background connects only check
      (await Connection.open(p,preferBluetooth: BluetoothPref.prefer)).close(); // prove the token and certificate before saving them
      await widget.onPaired(p);
      if (mounted && widget.canGoBack) Navigator.of(context).pop();
    } on AgtermError catch (e) {
      setState(() => error = e.message);
    } catch (_) {
      final where = [if (p.host != null) 'on the same network', if (p.bluetooth) 'near the computer with Bluetooth on'].join(' or ');
      setState(() => error = 'Cannot reach ${p.name}. Check that phone access is on (Settings ▸ Connect a Phone…) and the phone is $where.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code == null) return;
    link.text = code;
    connect(code);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.canGoBack ? AppBar() : null,
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: C.surface2,
                  border: Border.all(color: C.line),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  '>_',
                  style: TextStyle(fontFamily: mono, fontWeight: FontWeight.w700, fontSize: 20, color: C.accent),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Pair with Agterm2', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(height: 14),
            const Text(
              'On your computer, open Settings ▸ Connect a Phone… in Agterm2 and switch it on, or run the command below in any terminal. Either shows a pairing code.',
              style: TextStyle(fontSize: 15, height: 1.5, color: C.muted),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onLongPress: () => Clipboard.setData(const ClipboardData(text: 'agtermctl mobile serve')),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: C.term,
                  border: Border.all(color: C.surface2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: r'$ ',
                        style: TextStyle(color: C.muted),
                      ),
                      TextSpan(text: 'agtermctl mobile serve'),
                    ],
                  ),
                  style: TextStyle(fontFamily: mono, fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: busy ? null : scan,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan pairing code', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(height: 24),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or paste the link', style: TextStyle(color: C.muted, fontSize: 13)),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 24),
            const Text('PAIRING LINK', style: sectionLabel),
            const SizedBox(height: 8),
            TextField(
              key: const Key('pairLink'),
              controller: link,
              style: const TextStyle(fontFamily: mono, fontSize: 13),
              decoration: const InputDecoration(hintText: 'agterm://pair?h=…&t=…', fillColor: C.surface),
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => connect(),
            ),
            const SizedBox(height: 8),
            const Text(
              "The link carries the computer's address, a secret token and its certificate fingerprint. Traffic is encrypted and only that computer is trusted.",
              style: TextStyle(fontSize: 12, height: 1.5, color: C.muted),
            ),
            if (error != null) ...[
              const SizedBox(height: 16),
              Text(
                error!,
                key: const Key('pairError'),
                style: const TextStyle(color: C.danger, height: 1.4),
              ),
            ],
            const SizedBox(height: 32),
            OutlinedButton(
              key: const Key('connect'),
              onPressed: busy ? null : connect,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Connect', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
          ],
        ),
      ),
    ),
  );
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan pairing code')),
    body: Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().where((v) => v.startsWith('agterm://pair')).firstOrNull;
            if (value == null || done) return;
            done = true;
            Navigator.of(context).pop(value);
          },
          errorBuilder: (context, e) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('The camera is unavailable (${e.errorCode.name}). Paste the link instead.', textAlign: TextAlign.center),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: C.accent, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    ),
  );
}
