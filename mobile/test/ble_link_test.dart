import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agterm_mobile/ble_link.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

Uint8List utf(String s) => Uint8List.fromList(utf8.encode(s));

// The Mac's side of a fresh transport: the phone's keys with directions swapped.
BleTransportKeys mirror(BleTransportKeys k) =>
    BleTransportKeys(send: NoiseCipher(k.receive.key), receive: NoiseCipher(k.send.key), handshakeHash: k.handshakeHash);

void main() {
  final v = jsonDecode(File('test/fixtures/ble-vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final hs = v['handshake'] as Map<String, dynamic>;

  BleTransportKeys vectorPhone() {
    final i = BleInitiator.deterministic(BleIds.psk(v['token']), hex(hs['initiatorEphemeralPrivate']));
    i.start();
    return i.finish(hex(hs['message2']));
  }

  test('ids and psk match the vectors', () {
    for (final r in v['rotatingServiceUUIDs'] as List) {
      expect(BleIds.serviceUuid(v['token'], r['epoch']), (r['serviceUUID'] as String).toLowerCase());
    }
    expect(BleIds.psmCharacteristic, v['psmCharacteristicUUID']);
    expect(BleIds.psk(v['token']), hex(v['psk']));
  });

  test('scans for epochs e-1, e and e+1', () {
    final [a, b] = [for (final r in v['rotatingServiceUUIDs'] as List) (r['epoch'] as int, r['serviceUUID'] as String)];
    // the last second of epoch a: a-1, a, a+1
    expect(BleIds.serviceUuids(v['token'], DateTime.fromMillisecondsSinceEpoch((a.$1 * 900 + 899) * 1000)).sublist(1), [a.$2, b.$2]);
    // the first second of epoch b: a, b, b+1
    expect(BleIds.serviceUuids(v['token'], DateTime.fromMillisecondsSinceEpoch(b.$1 * 900 * 1000)).sublist(0, 2), [a.$2, b.$2]);
  });

  test('handshake reproduces the vectors', () {
    expect(x25519Public(hex(hs['initiatorEphemeralPrivate'])), hex(hs['initiatorEphemeralPublic']));
    expect(x25519Public(hex(hs['responderEphemeralPrivate'])), hex(hs['responderEphemeralPublic']));
    final i = BleInitiator.deterministic(BleIds.psk(v['token']), hex(hs['initiatorEphemeralPrivate']));
    final m1 = i.start();
    expect(m1, hex(hs['message1']));
    expect(BleFramer.frame(m1), hex(hs['message1Wire']));
    expect(i.finish(hex(hs['message2'])).handshakeHash, hex(hs['handshakeHash']));
  });

  test('transport frames reproduce the vectors', () {
    final phone = vectorPhone();
    final mac = mirror(phone);
    for (final f in v['frames'] as List) {
      final toMac = f['direction'] == 'phone-to-mac';
      final (sender, receiver) = toMac ? (phone, mac) : (mac, phone);
      expect(sender.send.encrypt(hex(f['deflated'])), hex(f['frame']));
      expect(receiver.open(hex(f['frame'])), utf(f['plaintext']));
      expect(BleTransportKeys.inflate(hex(f['deflated'])), utf(f['plaintext']));
    }
  });

  test('cacophony Noise_NNpsk0_25519_ChaChaPoly_SHA256 vector', () {
    final c = v['noiseConformance'] as Map<String, dynamic>;
    expect(c['protocolName'], 'Noise_NNpsk0_25519_ChaChaPoly_SHA256');
    final m = c['messages'] as List;
    final i = BleInitiator.deterministic(hex(c['psk']), hex(c['initiatorEphemeralPrivate']), prologue: hex(c['prologue']));
    expect(i.writeMessage1(hex(m[0]['payload'])), hex(m[0]['ciphertext']));
    final (payload, phone) = i.readMessage2(hex(m[1]['ciphertext']));
    expect(payload, hex(m[1]['payload']));
    expect(phone.handshakeHash, hex(c['handshakeHash']));
    var (sender, receiver) = (phone, mirror(phone));
    for (final msg in m.skip(2)) {
      expect(sender.send.encrypt(hex(msg['payload'])), hex(msg['ciphertext']));
      expect(receiver.receive.decrypt(hex(msg['ciphertext'])), hex(msg['payload']));
      (sender, receiver) = (receiver, sender);
    }
  });

  test('handshake reply: rejects, wrong key, short', () {
    BleInitiator started() => BleInitiator(BleIds.psk('t'))..start();
    expect(() => started().finish(Uint8List.fromList([1])), throwsA(BleLinkError.wrongKey));
    expect(() => started().finish(Uint8List.fromList([2])), throwsA(BleLinkError.busy));
    expect(() => started().finish(Uint8List.fromList([3])), throwsA(BleLinkError.badFrame));
    for (final n in [0, 47, 49]) {
      expect(() => started().finish(Uint8List(n)), throwsA(BleLinkError.badFrame));
    }
    final i = BleInitiator.deterministic(BleIds.psk('other'), hex(hs['initiatorEphemeralPrivate']));
    expect(i.start().length, 48);
    expect(() => i.finish(hex(hs['message2'])), throwsA(BleLinkError.wrongKey));
  });

  test('tampered and replayed frames throw and do not advance the counter', () {
    final phone = vectorPhone();
    final frames = (v['frames'] as List).where((f) => f['direction'] == 'mac-to-phone').toList();
    final good = hex(frames[0]['frame']);
    final bad = Uint8List.fromList(good)..[3] ^= 1;
    expect(() => phone.open(bad), throwsA(BleLinkError.badFrame));
    expect(phone.open(good), utf(frames[0]['plaintext']));
    expect(() => phone.open(good), throwsA(BleLinkError.badFrame));
    expect(phone.open(hex(frames[1]['frame'])), utf(frames[1]['plaintext']));
    expect(() => phone.open(Uint8List(15)), throwsA(BleLinkError.badFrame));
  });

  test('a 10 KB line splits into chunks and round-trips through byte-wise framing', () {
    final phone = vectorPhone();
    final mac = mirror(phone);
    final line = Uint8List.fromList([for (var i = 0; i < 10000; i++) 0x61 + i % 26, 0x0a]);
    final wire = BytesBuilder();
    var chunks = 0;
    for (var o = 0; o < line.length; o += BleTransportKeys.maxChunk, chunks++) {
      final end = o + BleTransportKeys.maxChunk < line.length ? o + BleTransportKeys.maxChunk : line.length;
      wire.add(BleFramer.frame(phone.seal(line.sublist(o, end))));
    }
    expect(chunks, greaterThanOrEqualTo(3));
    final framer = BleFramer();
    final received = BytesBuilder();
    for (final b in wire.takeBytes()) {
      for (final body in framer.push(Uint8List.fromList([b]))) {
        received.add(mac.open(body));
      }
    }
    expect(received.takeBytes(), line);
  });

  test('each sealed chunk is one finished raw DEFLATE stream', () {
    final phone = vectorPhone();
    final mac = mirror(phone);
    final chunk = utf('{"cmd":"session.text","target":"active","args":{"lines":40},"id":2}\n' * 40);
    final deflated = mac.receive.decrypt(phone.seal(chunk));
    expect(ZLibCodec(raw: true).decode(deflated), chunk);
    expect(deflated[0] & 1, 1); // BFINAL on the only block: Apple's inflate refuses an unfinished (sync-flushed) stream
    expect(deflated.sublist(deflated.length - 4), isNot([0, 0, 0xff, 0xff]));
  });

  test('a cipher at the reserved counter 2^64-1 refuses to encrypt or decrypt', () {
    final phone = vectorPhone();
    phone.send.counter = -1;
    phone.receive.counter = -1;
    expect(() => phone.seal(utf('x\n')), throwsA(BleLinkError.badFrame));
    expect(() => phone.receive.decrypt(Uint8List(32)), throwsA(BleLinkError.badFrame));
  });

  test('deflate shrinks terminal text', () {
    const row = '\x1b[32m~/dev/agterm\x1b[0m \$ ls -la Sources/agtermctlKit | grep Swift\n';
    final text = utf(row * (4096 ~/ row.length + 1)).sublist(0, 4096);
    expect(vectorPhone().seal(text).length, lessThan(text.length ~/ 4));
  });

  test('seal refuses empty and oversized chunks; open refuses bombs and garbage', () {
    final phone = vectorPhone();
    final mac = mirror(phone);
    expect(() => phone.seal(Uint8List(0)), throwsA(BleLinkError.badFrame));
    expect(() => phone.seal(Uint8List(BleTransportKeys.maxChunk + 1)), throwsA(BleLinkError.badFrame));
    expect(() => mac.open(phone.send.encrypt(zlibRaw(Uint8List(5000)))), throwsA(BleLinkError.badFrame));
    expect(() => mac.open(phone.send.encrypt(zlibRaw(Uint8List(10 << 20)))), throwsA(BleLinkError.badFrame));
    expect(() => mac.open(phone.send.encrypt(Uint8List.fromList([0xff, 0xff, 0xff]))), throwsA(BleLinkError.badFrame));
    expect(() => mac.open(phone.send.encrypt(Uint8List(0))), throwsA(BleLinkError.badFrame));
    expect(mac.open(phone.seal(utf('ok\n'))), utf('ok\n'));
  });

  test('initiator is single-use', () {
    final i = BleInitiator(BleIds.psk('t'));
    expect(() => i.finish(Uint8List(48)), throwsStateError);
    i.start();
    expect(i.start, throwsStateError);
    expect(() => i.finish(Uint8List.fromList([2])), throwsA(BleLinkError.busy));
    expect(() => i.finish(Uint8List(48)), throwsStateError);
  });

  test('framer keeps a partial frame when the caller reuses its buffer', () {
    final f = BleFramer();
    final buffer = Uint8List.fromList([0x00, 0x03, 0xaa, 0xbb]);
    expect(f.push(buffer), isEmpty);
    buffer.fillRange(0, 4, 0xee);
    expect(f.push(Uint8List.fromList([0xcc])), [
      [0xaa, 0xbb, 0xcc],
    ]);
  });

  test('framer handles partial, zero-length and batched frames', () {
    final f = BleFramer();
    expect(f.push(Uint8List.fromList([0x00])), isEmpty);
    expect(f.push(Uint8List.fromList([0x02, 0xaa])), isEmpty);
    expect(f.push(Uint8List.fromList([0xbb, 0x00, 0x00, 0x00, 0x01, 0xcc])), [
      [0xaa, 0xbb],
      <int>[],
      [0xcc],
    ]);
    expect(BleFramer.frame(Uint8List(300)).sublist(0, 2), [0x01, 0x2c]);
    expect(() => BleFramer.frame(Uint8List(65536)), throwsArgumentError);
  });
}

Uint8List zlibRaw(Uint8List data) => Uint8List.fromList(ZLibEncoder(raw: true).convert(data));
