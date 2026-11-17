// The Bluetooth link to the Mac: Noise NNpsk0 over u16-length frames, raw DEFLATE inside.
// test/fixtures/ble-vectors.json (copied verbatim from the Mac) is the byte-exact contract.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretKeyData, SimpleKeyPairData, SimplePublicKey, KeyPairType;
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';

/// [wrongKey] and [busy] are also the Mac's one-byte handshake rejections 0x01 and 0x02.
enum BleLinkError implements Exception { wrongKey, busy, badFrame }

Uint8List _hmac(List<int> key, List<int> data) => Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

// RFC 5869 by hand: cryptography's Hkdf has no synchronous form.
List<Uint8List> _hkdf(List<int> salt, List<int> ikm, List<int> info, int outputs) {
  final prk = _hmac(salt, ikm);
  var t = Uint8List(0);
  return [
    for (var i = 1; i <= outputs; i++) t = _hmac(prk, [...t, ...info, i]),
  ];
}

class BleIds {
  static const psmCharacteristic = 'a6e5c0de-0001-4a67-8000-6167746572d1';

  static const epochSeconds = 900;

  /// The UUID the Mac advertises during [epoch] (unix seconds / [epochSeconds]): it rotates so nobody can track the Mac.
  static String serviceUuid(String token, int epoch) {
    final b = _hmac(utf8.encode(token), utf8.encode('hangar-ble-adv:$epoch')).sublist(0, 16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// The UUIDs to scan for at [now]: epochs e-1, e and e+1, for clock skew.
  static List<String> serviceUuids(String token, DateTime now) {
    final e = now.millisecondsSinceEpoch ~/ 1000 ~/ epochSeconds;
    return [for (var i = e - 1; i <= e + 1; i++) serviceUuid(token, i)];
  }

  static Uint8List psk(String token) => _hkdf(const [], utf8.encode(token), utf8.encode('hangar-ble-psk'), 1)[0];
}

const _x25519 = DartX25519();
const _aead = DartChacha20.poly1305Aead();

Uint8List _dh(Uint8List private, List<int> public) => Uint8List.fromList(
  (_x25519.sharedSecretSync(
    keyPairData: SimpleKeyPairData(
      private,
      publicKey: SimplePublicKey(public, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    ),
    remotePublicKey: SimplePublicKey(public, type: KeyPairType.x25519),
  ) as SecretKeyData).bytes,
);

@visibleForTesting
Uint8List x25519Public(Uint8List private) => _dh(private, [9, ...List.filled(31, 0)]);

/// One direction's Noise CipherState: ChaChaPoly with nonce = 4 zero bytes ‖ u64 little-endian counter.
class NoiseCipher {
  NoiseCipher(this._key);
  final Uint8List _key;
  int _counter = 0;

  @visibleForTesting
  Uint8List get key => _key;
  @visibleForTesting
  set counter(int value) => _counter = value;

  // Noise reserves 2^64-1 (an int of -1 here), so a cipher refuses rather than reuse a nonce.
  List<int> get _nonce {
    if (_counter == -1) throw BleLinkError.badFrame;
    return (ByteData(12)..setUint64(4, _counter, Endian.little)).buffer.asUint8List();
  }

  Uint8List encrypt(List<int> plaintext, {List<int> ad = const []}) {
    final box = _aead.encryptSync(plaintext, secretKey: SecretKeyData(_key), nonce: _nonce, aad: ad);
    _counter++;
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  // A failed open leaves the counter alone, so a replayed or forged frame never advances it.
  Uint8List decrypt(Uint8List ciphertext, {List<int> ad = const []}) {
    if (ciphertext.length < 16) throw BleLinkError.badFrame;
    final split = ciphertext.length - 16;
    final List<int> plaintext;
    try {
      plaintext = _aead.decryptSync(
        SecretBox(ciphertext.sublist(0, split), nonce: _nonce, mac: Mac(ciphertext.sublist(split))),
        secretKey: SecretKeyData(_key),
        aad: ad,
      );
    } catch (_) {
      throw BleLinkError.badFrame;
    }
    _counter++;
    return Uint8List.fromList(plaintext);
  }
}

/// The phone's side of `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (`-> psk, e`, `<- e, ee`).
class BleInitiator {
  BleInitiator(Uint8List psk) : this._(psk, Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256))), _prologue);

  @visibleForTesting
  BleInitiator.deterministic(Uint8List psk, Uint8List ephemeral, {Uint8List? prologue}) : this._(psk, ephemeral, prologue ?? _prologue);

  BleInitiator._(Uint8List psk, this._e, Uint8List prologue) {
    _h = Uint8List.fromList(sha256.convert(utf8.encode('Noise_NNpsk0_25519_ChaChaPoly_SHA256')).bytes);
    _ck = _h;
    _mixHash(prologue);
    final out = _hkdf(_ck, psk, const [], 3); // MixKeyAndHash(psk)
    _ck = out[0];
    _mixHash(out[1]);
    _cipher = NoiseCipher(out[2]);
  }

  static final _random = Random.secure();
  static final _prologue = Uint8List.fromList(utf8.encode('hangar-ble-1'));
  final Uint8List _e;
  late Uint8List _ck, _h;
  late NoiseCipher _cipher;

  void _mixHash(List<int> data) => _h = Uint8List.fromList(sha256.convert([..._h, ...data]).bytes);

  void _mixKey(List<int> ikm) {
    final out = _hkdf(_ck, ikm, const [], 2);
    _ck = out[0];
    _cipher = NoiseCipher(out[1]);
  }

  // Single use: 0 before start, 1 after it, 2 once finish has run (whatever it returned).
  int _step = 0;

  void _advance(int from) {
    if (_step != from) throw StateError('BleInitiator is single-use: start once, then finish once');
    _step++;
  }

  Uint8List start() {
    _advance(0);
    return writeMessage1(Uint8List(0));
  }

  // Our handshake carries empty payloads, so a real reply is exactly 48 bytes; a 1-byte reply is the Mac's rejection.
  BleTransportKeys finish(Uint8List reply) {
    _advance(1);
    if (reply.length == 1) {
      throw switch (reply[0]) {
        1 => BleLinkError.wrongKey,
        2 => BleLinkError.busy,
        _ => BleLinkError.badFrame,
      };
    }
    if (reply.length != 48) throw BleLinkError.badFrame;
    return readMessage2(reply).$2;
  }

  @visibleForTesting
  Uint8List writeMessage1(Uint8List payload) {
    final pub = x25519Public(_e);
    _mixHash(pub);
    _mixKey(pub);
    final ciphertext = _cipher.encrypt(payload, ad: _h);
    _mixHash(ciphertext);
    return Uint8List.fromList([...pub, ...ciphertext]);
  }

  @visibleForTesting
  (Uint8List, BleTransportKeys) readMessage2(Uint8List message) {
    if (message.length < 48) throw BleLinkError.badFrame;
    final remote = message.sublist(0, 32);
    _mixHash(remote);
    _mixKey(remote);
    final Uint8List secret;
    try {
      secret = _dh(_e, remote);
    } catch (_) {
      throw BleLinkError.badFrame;
    }
    if (secret.every((b) => b == 0)) throw BleLinkError.badFrame; // a low-order point, as CryptoKit refuses it
    _mixKey(secret);
    final ciphertext = message.sublist(32);
    final Uint8List payload;
    try {
      payload = _cipher.decrypt(ciphertext, ad: _h);
    } on BleLinkError {
      throw BleLinkError.wrongKey;
    }
    _mixHash(ciphertext);
    final keys = _hkdf(_ck, const [], const [], 2); // Split(): the first key carries phone to Mac
    return (payload, BleTransportKeys(send: NoiseCipher(keys[0]), receive: NoiseCipher(keys[1]), handshakeHash: _h));
  }
}

/// Transport after the handshake. Each frame is one independently deflated chunk of 1...[maxChunk] line-stream bytes.
class BleTransportKeys {
  @visibleForTesting
  BleTransportKeys({required this.send, required this.receive, required this.handshakeHash});

  static const maxChunk = 4096;
  @visibleForTesting
  final NoiseCipher send, receive;
  @visibleForTesting
  final Uint8List handshakeHash;

  Uint8List seal(Uint8List chunk) {
    if (chunk.isEmpty || chunk.length > maxChunk) throw BleLinkError.badFrame;
    return send.encrypt(ZLibEncoder(raw: true).convert(chunk));
  }

  Uint8List open(Uint8List frame) => inflate(receive.decrypt(frame));

  // Counts output per filter step, so a bomb is refused before it is ever held in memory.
  // A stream cut before its final block yields partial output: only the key holder can send one, and Apple's inflater is lenient too.
  @visibleForTesting
  static Uint8List inflate(Uint8List deflated) {
    if (deflated.isEmpty) throw BleLinkError.badFrame;
    final out = BytesBuilder(copy: false);
    try {
      final filter = RawZLibFilter.inflateFilter(raw: true)..process(deflated, 0, deflated.length);
      for (List<int>? part; (part = filter.processed(end: true)) != null;) {
        out.add(part!);
        if (out.length > maxChunk) throw BleLinkError.badFrame;
      }
    } catch (_) {
      throw BleLinkError.badFrame;
    }
    if (out.isEmpty) throw BleLinkError.badFrame;
    return out.takeBytes();
  }
}

/// `u16 big-endian length ‖ body` stream framing, used for every message on the L2CAP stream.
class BleFramer {
  final _buffer = BytesBuilder(); // copies: a BLE plugin may reuse the buffer it passed to push

  List<Uint8List> push(Uint8List bytes) {
    _buffer.add(bytes);
    var data = _buffer.takeBytes();
    final bodies = <Uint8List>[];
    var at = 0;
    while (data.length - at >= 2) {
      final length = data[at] << 8 | data[at + 1];
      if (data.length - at < 2 + length) break;
      bodies.add(Uint8List.sublistView(data, at + 2, at + 2 + length));
      at += 2 + length;
    }
    _buffer.add(Uint8List.sublistView(data, at));
    return bodies;
  }

  static Uint8List frame(Uint8List body) {
    if (body.length > 0xffff) throw ArgumentError.value(body.length, 'body.length', 'BLE frame body over 65535 bytes');
    return Uint8List.fromList([body.length >> 8, body.length & 0xff, ...body]);
  }
}
