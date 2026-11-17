import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../ble_transport.dart';
import '../client.dart';
import '../model.dart';
import '../notice.dart';
import '../theme.dart';

const macAppUrl = 'https://github.com/NaikSoftware/hangar/releases/latest';
const linuxAppUrl = 'https://github.com/NaikSoftware/hangar#build-and-install';

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
    if (p == null) return setState(() => error = 'That is not a pairing link. It starts with hangar://pair?');
    setState(() => (busy = true, error = null));
    try {
      if (p.bluetooth) await requestBluetooth(); // the one foreground moment to ask; background connects only check
      (await Connection.open(p,preferBluetooth: BluetoothPref.prefer)).close(); // prove the token and certificate before saving them
      await widget.onPaired(p);
      if (mounted && widget.canGoBack) Navigator.of(context).pop();
    } on HangarError catch (e) {
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

  // the computer app's download page: open it here to send on, or long-press to copy the link
  Widget _appButton(String label, IconData icon, String url) {
    void copy() {
      Clipboard.setData(ClipboardData(text: url));
      showNotice(context, 'Link copied');
    }

    return GestureDetector(
      onLongPress: copy,
      child: OutlinedButton.icon(
        key: Key('app-$label'),
        onPressed: () async {
          final opened = await const MethodChannel('hangar/open').invokeMethod<bool>('view', url).catchError((_) => false);
          if (opened != true && mounted) copy();
        },
        style: _quiet,
        icon: Icon(icon, size: 18, color: C.muted),
        label: Text(label),
      ),
    );
  }

  // the home screen's quiet controls (chips, ⋮ menu): a faint fill on a hairline, no accent colour
  static final _quiet = OutlinedButton.styleFrom(
    minimumSize: const Size.fromHeight(48),
    backgroundColor: C.hover,
    foregroundColor: C.text,
    side: const BorderSide(color: C.line),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w500),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.canGoBack ? AppBar() : null,
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 40, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(alignment: Alignment.centerLeft, child: AppMark(size: 56)),
            const SizedBox(height: 14),
            const Text('Pair with Hangar', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(height: 14),
            const Text(
              'On your computer, open Settings ▸ Connect a Phone… in Hangar and switch it on, or run the command below in any terminal. Either shows a pairing code.',
              style: TextStyle(fontSize: 14, height: 1.5, color: C.muted),
            ),
            const SizedBox(height: 16),
            Row(spacing: 8, children: [
              Expanded(child: _appButton('macOS app', Icons.laptop_mac, macAppUrl)),
              Expanded(child: _appButton('Linux app', Icons.computer, linuxAppUrl)),
            ]),
            const SizedBox(height: 24),
            GestureDetector(
              onLongPress: () => Clipboard.setData(const ClipboardData(text: 'hangarctl mobile serve')),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: C.term,
                  border: Border.all(color: C.line),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: r'$ ',
                        style: TextStyle(color: C.muted),
                      ),
                      TextSpan(text: 'hangarctl mobile serve'),
                    ],
                  ),
                  style: TextStyle(fontFamily: mono, fontSize: 13, color: C.termText),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // the primary action looks like the home screen's New session button
            FilledButton.icon(
              onPressed: busy ? null : scan,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: C.text,
                foregroundColor: C.bg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan pairing code', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 24),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR PASTE THE LINK', style: sectionLabel),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('pairLink'),
              controller: link,
              style: const TextStyle(fontFamily: mono, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'hangar://pair?h=…&t=…',
                fillColor: C.hover,
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide(color: C.muted)),
              ),
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
            const SizedBox(height: 20),
            OutlinedButton(
              key: const Key('connect'),
              onPressed: busy ? null : connect,
              style: _quiet,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Connect', style: TextStyle(fontWeight: FontWeight.w600)),
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
            final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().where((v) => v.startsWith('hangar://pair')).firstOrNull;
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
              border: Border.all(color: C.text, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    ),
  );
}
