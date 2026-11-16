import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agterm_mobile/ble_link.dart';
import 'package:agterm_mobile/ble_transport.dart';
import 'package:agterm_mobile/client.dart';
import 'package:agterm_mobile/model.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

const fp = 'd6804234939ad32471883bb5743cf3e435d24d0e1a02085f0adf7a51634cb443';
const token = 'B9nEPMC4LDwT26URUTdmlho5YnA9mIq2gvBL86UnvVo';

/// The relay's line protocol over an in-memory plaintext link: auth, then `{cmd}` answered with [results].
Link fakeRelay(String via, {Map<String, Object?> results = const {}}) {
  final input = StreamController<Uint8List>(); // as a SecureSocket: a Stream<Uint8List>
  final lines = StreamController<List<int>>();
  lines.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final r = jsonDecode(line) as Map;
    input.add(utf8.encode('${jsonEncode({'id': r['id'], 'ok': true, 'result': results[r['cmd']] ?? {}})}\n'));
  });
  return Link(input.stream, lines.add, () => input.close(), via: via);
}

/// A raw byte channel whose far end is [respond], fed the reassembled frame bodies; its output arrives in 5-byte pieces.
Link fakeRaw(void Function(Uint8List body, void Function(Uint8List body) reply) respond) {
  final input = StreamController<List<int>>();
  final framer = BleFramer();
  void reply(Uint8List body) {
    final wire = BleFramer.frame(body);
    for (var at = 0; at < wire.length; at += 5) {
      input.add(wire.sublist(at, at + 5 > wire.length ? wire.length : at + 5));
    }
  }

  return Link(input.stream, (bytes) {
    for (final body in framer.push(Uint8List.fromList(bytes))) {
      respond(body, reply);
    }
  }, () => input.close(), via: 'BT');
}

void main() {
  final v = jsonDecode(File('test/fixtures/ble-vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final hs = v['handshake'] as Map<String, dynamic>;
  BleInitiator vectorInitiator() => BleInitiator.deterministic(BleIds.psk(v['token']), hex(hs['initiatorEphemeralPrivate']));

  group('pairing link', () {
    test('h and p with b=1', () {
      final p = Pairing.parse('agterm://pair?h=10.0.0.2&p=8765&t=$token&f=$fp&n=mac&b=1')!;
      expect((p.host, p.port, p.bluetooth, p.key), ('10.0.0.2', 8765, true, fp));
    });

    test('b=1 without h or p', () {
      final p = Pairing.parse('agterm://pair?t=$token&f=$fp&n=mac&b=1')!;
      expect((p.host, p.port, p.bluetooth, p.name, p.address), (null, null, true, 'mac', 'Bluetooth'));
    });

    test('h without b is TLS only', () {
      expect(Pairing.parse('agterm://pair?h=h&p=2&t=$token&f=$fp')!.bluetooth, isFalse);
    });

    test('refuses no h without b, and a bad port with h', () {
      expect(Pairing.parse('agterm://pair?t=$token&f=$fp&n=mac'), isNull);
      expect(Pairing.parse('agterm://pair?h=h&t=$token&f=$fp&b=1'), isNull);
    });

    test('a Bluetooth-only pairing round-trips through JSON', () {
      final p = Pairing.parse('agterm://pair?t=$token&f=$fp&n=mac&b=1')!;
      expect(Pairing.fromJson(p.toJson()).toJson(), p.toJson());
    });

    test('stored pairings from before Bluetooth load, keyed by fingerprint, one per certificate', () {
      final old = jsonEncode([
        {'name': 'a', 'host': '10.0.0.2', 'port': 8765, 'token': token, 'fingerprint': fp},
        {'name': 'b', 'host': '10.0.0.3', 'port': 8765, 'token': token, 'fingerprint': fp},
        {'name': 'c', 'host': '10.0.0.4', 'port': 1, 'token': token, 'fingerprint': '0' * 64},
      ]);
      final all = PairingStore.decode(old);
      expect([for (final p in all) (p.name, p.key, p.bluetooth, p.address)],
          [('a', fp, false, '10.0.0.2:8765'), ('c', '0' * 64, false, '10.0.0.4:1')]);
    });
  });

  group('transport order', () {
    final both = Pairing.parse('agterm://pair?h=h&p=2&t=$token&f=$fp&b=1')!;

    // each fake records its call, then connects or fails as [up] says
    Future<String> order({required bool tlsUp, required bool bleUp, bool prefer = false}) async {
      final calls = <String>[];
      final c = await Connection.open(both, preferBluetooth: prefer, tls: (p, t) async {
        calls.add('tls $t');
        return tlsUp ? fakeRelay('Wi-Fi') : throw const SocketException('down');
      }, ble: (p) async {
        calls.add('ble');
        return bleUp ? fakeRelay('BT') : throw BleNotFound();
      });
      c.close();
      return '${calls.join(', ')} → ${c.via}';
    }

    const tls3 = 'tls 0:00:03.000000';

    test('TLS first with 3 s, then Bluetooth', () async {
      expect(await order(tlsUp: false, bleUp: true), '$tls3, ble → BT');
      expect(await order(tlsUp: true, bleUp: true), '$tls3 → Wi-Fi');
    });

    test('Prefer Bluetooth reverses it', () async {
      expect(await order(tlsUp: true, bleUp: true, prefer: true), 'ble → BT');
      expect(await order(tlsUp: true, bleUp: false, prefer: true), 'ble, $tls3 → Wi-Fi');
    });

    test('TLS-only pairings keep the 8 s timeout and never scan', () async {
      final tlsOnly = Pairing.parse('agterm://pair?h=h&p=2&t=$token&f=$fp')!;
      Duration? timeout;
      final c = await Connection.open(tlsOnly, tls: (p, t) async {
        timeout = t;
        return fakeRelay('Wi-Fi');
      }, ble: (p) => fail('scanned'));
      expect(timeout, const Duration(seconds: 8));
      c.close();
    });

    test('a definite error beats not found, which beats cannot reach', () async {
      await expectLater(
          Connection.open(both, tls: (p, t) async => throw SocketException('x'), ble: (p) async => throw BleNotFound()), throwsA(isA<BleNotFound>()));
      await expectLater(Connection.open(both, tls: (p, t) async => throw AgtermError('cert'), ble: (p) async => throw BleNotFound()),
          throwsA(isA<AgtermError>().having((e) => e.message, 'message', 'cert')));
    });
  });

  group('messages', () {
    final ble = Pairing.parse('agterm://pair?t=$token&f=$fp&n=studio&b=1')!;

    Future<Object> rejected(int code) async {
      try {
        await BleTransport.open(fakeRaw((body, reply) => reply(Uint8List.fromList([code]))), token);
      } catch (e) {
        return e;
      }
      throw 'not rejected';
    }

    test('reject 0x01 says revoked, 0x02 says busy', () async {
      expect('${await rejected(1)}', 'The pairing was revoked. Pair this computer again.');
      expect('${await rejected(2)}', 'The computer is busy with another phone.');
      expect(await rejected(3), BleLinkError.badFrame);
    });

    test("not found for 2 minutes says can't find", () {
      expect(connectError(BleNotFound(), ble, const Duration(seconds: 119)), 'Cannot reach studio over Bluetooth. Is phone access on?');
      expect(connectError(BleNotFound(), ble, const Duration(minutes: 2)), "Can't find studio: out of range, Bluetooth off, or the pairing was reset.");
      expect(connectError(AgtermError('x'), ble, const Duration(minutes: 5)), 'x');
    });
  });

  test('end to end: Bluetooth handshake from the vectors, auth, and a command whose answer spans frames', () async {
    final phone = vectorInitiator()..start();
    final keys = phone.finish(hex(hs['message2']));
    final mac = BleTransportKeys(send: NoiseCipher(keys.receive.key), receive: NoiseCipher(keys.send.key), handshakeHash: keys.handshakeHash);
    final big = 'x' * 10000; // a 2000-line scrollback answer: three frames
    final seen = <Map>[];
    var shook = false;
    final lines = StringBuffer();

    final raw = fakeRaw((body, reply) {
      if (!shook) {
        shook = true;
        expect(BleFramer.frame(body), hex(hs['message1Wire']));
        return reply(hex(hs['message2']));
      }
      lines.write(utf8.decode(mac.open(body)));
      while (lines.toString().contains('\n')) {
        final s = lines.toString();
        final r = jsonDecode(s.substring(0, s.indexOf('\n'))) as Map;
        lines
          ..clear()
          ..write(s.substring(s.indexOf('\n') + 1));
        seen.add(r);
        final out = utf8.encode('${jsonEncode({'id': r['id'], 'ok': true, 'result': {'text': big}})}\n');
        for (var at = 0; at < out.length; at += BleTransportKeys.maxChunk) {
          reply(mac.seal(Uint8List.fromList(out.sublist(at, at + BleTransportKeys.maxChunk > out.length ? out.length : at + BleTransportKeys.maxChunk))));
        }
      }
    });

    final p = Pairing(name: 'mac', token: v['token'], fingerprint: fp, bluetooth: true); // the vector token is too short for a link
    final c = await Connection.open(p, ble: (p) => BleTransport.open(raw, p.token, initiator: vectorInitiator()));
    expect(c.via, 'BT');
    final r = await c.call('session.text', target: 's1');
    expect(r['text'], big);
    expect(seen.map((m) => m['auth'] ?? m['cmd']).toList(), [v['token'], 'session.text']);
    c.close();
  });
}
