// The Bluetooth transport: the Kotlin side (BleChannel.kt) finds the Mac and moves raw L2CAP bytes; the handshake,
// framing and encryption (ble_link.dart) stay here.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_link.dart';
import 'client.dart';

/// No advertisement with the pairing's service UUID: out of range, Bluetooth off, or the pairing was reset.
class BleNotFound implements Exception {}

const busyMessage = 'The computer is busy with another phone.';

class BleTransport {
  /// Runs the handshake over [raw]; the plaintext line stream after it.
  static Future<Link> open(Link raw, String token, {@visibleForTesting BleInitiator? initiator}) async {
    final init = initiator ?? BleInitiator(BleIds.psk(token));
    final framer = BleFramer(); // one for the whole link: bytes behind the handshake reply belong to the next frame
    final plain = StreamController<List<int>>();
    final ready = Completer<void>();
    BleTransportKeys? keys;

    void fail(Object e) {
      raw.close();
      if (!ready.isCompleted) return ready.completeError(e);
      plain.close();
    }

    final sub = raw.input.listen((bytes) {
      try {
        for (final body in framer.push(Uint8List.fromList(bytes))) {
          if (keys == null) {
            keys = init.finish(body);
            ready.complete();
          } else {
            plain.add(keys!.open(body));
          }
        }
      } catch (e) {
        fail(e);
      }
    }, onError: fail, onDone: () => fail(StateError('closed during the handshake')));

    void close() {
      sub.cancel();
      raw.close();
      plain.close();
    }

    raw.add(BleFramer.frame(init.start()));
    try {
      await ready.future.timeout(const Duration(seconds: 8));
    } catch (e) {
      close();
      throw switch (e) {
        BleLinkError.wrongKey => Revoked(),
        BleLinkError.busy => ElisError(busyMessage),
        _ => e,
      };
    }
    // seal and send in one synchronous pass, so the nonce order is the wire order
    void add(List<int> bytes) {
      for (var at = 0; at < bytes.length; at += BleTransportKeys.maxChunk) {
        final chunk = Uint8List.fromList(bytes.sublist(at, min(at + BleTransportKeys.maxChunk, bytes.length)));
        raw.add(BleFramer.frame(keys!.seal(chunk)));
      }
    }

    return Link(plain.stream, add, close, via: 'BT');
  }
}

const _method = MethodChannel('elis/ble');
final _inputs = <int, StreamController<List<int>>>{};
StreamSubscription? _events;
int _nextId = 0;

/// Whether Android lets this app use Bluetooth (BLUETOOTH_SCAN and BLUETOOTH_CONNECT).
Future<bool> bluetoothGranted() async => await _method.invokeMethod<bool>('granted') ?? false;

/// Asks for the Bluetooth permissions; only from a foreground UI action (pairing, the Prefer Bluetooth switch).
/// A request that gets no answer in [timeout] (a stopped or recreated activity) counts as denied.
Future<bool> requestBluetooth({Duration timeout = const Duration(seconds: 60)}) async =>
    await _method.invokeMethod<bool>('permit').timeout(timeout, onTimeout: () => false) ?? false;

const notAllowedMessage = 'Bluetooth needs the Nearby devices permission. Allow it in Android settings, or pair again.';

/// Scans for the pairing's service UUID, opens its L2CAP channel and runs the handshake. Never asks for permissions:
/// it may run in the background.
Future<Link> openBle(Pairing p) async {
  if (!await bluetoothGranted()) throw ElisError(notAllowedMessage);
  // one subscription for all links, alive before any connect, so no early bytes are dropped
  _events ??= const EventChannel('elis/ble/data').receiveBroadcastStream().listen((e) {
    final m = e as Map;
    final input = _inputs[m['id']];
    if (m['data'] case final Uint8List data) return input?.add(data);
    _inputs.remove(m['id'])?.close();
  });
  final id = ++_nextId;
  final input = _inputs[id] = StreamController<List<int>>();
  void close() {
    _inputs.remove(id)?.close();
    _method.invokeMethod('close', {'id': id}).ignore();
  }

  try {
    await _method.invokeMethod('connect', {'id': id, 'services': BleIds.serviceUuids(p.token, DateTime.now()), 'timeoutMs': 10000});
  } on PlatformException catch (e) {
    close();
    throw switch (e.code) {
      'notFound' => BleNotFound(),
      'off' => ElisError('Bluetooth is off.'),
      'scanFailed' => ElisError('Bluetooth scanning failed (${e.message}). Try again in a minute.'),
      _ => ElisError('Bluetooth connection failed: ${e.message ?? e.code}'),
    };
  }
  final raw = Link(input.stream, (b) => _method.invokeMethod('write', {'id': id, 'data': Uint8List.fromList(b)}).catchError((_) => close()), close,
      via: 'BT');
  return BleTransport.open(raw, p.token);
}
