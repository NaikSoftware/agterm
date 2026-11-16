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

  static String serviceUuid(String token) {
    final b = _hmac(utf8.encode(token), utf8.encode('agterm-ble-adv')).sublist(0, 16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static Uint8List psk(String token) => _hkdf(const [], utf8.encode(token), utf8.encode('agterm-ble-psk'), 1)[0];
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
  NoiseCipher(this.key);
  final Uint8List key;
  int counter = 0;

  // Noise reserves 2^64-1 (an int of -1 here), so a cipher refuses rather than reuse a nonce.
  List<int> get _nonce {
    if (counter == -1) throw BleLinkError.badFrame;
    return (ByteData(12)..setUint64(4, counter, Endian.little)).buffer.asUint8List();
  }

  Uint8List encrypt(List<int> plaintext, {List<int> ad = const []}) {
    final box = _aead.encryptSync(plaintext, secretKey: SecretKeyData(key), nonce: _nonce, aad: ad);
    counter++;
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
        secretKey: SecretKeyData(key),
        aad: ad,
      );
    } catch (_) {
      throw BleLinkError.badFrame;
    }
    counter++;
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
  static final _prologue = Uint8List.fromList(utf8.encode('agterm-ble-1'));
  final Uint8List _e;
  late Uint8List _ck, _h;
  late NoiseCipher _cipher;

  void _mixHash(List<int> data) => _h = Uint8List.fromList(sha256.convert([..._h, ...data]).bytes);

  void _mixKey(List<int> ikm) {
    final out = _hkdf(_ck, ikm, const [], 2);
    _ck = out[0];
    _cipher = NoiseCipher(out[1]);
  }

  Uint8List start() => writeMessage1(Uint8List(0));

  // Our handshake carries empty payloads, so a real reply is exactly 48 bytes; a 1-byte reply is the Mac's rejection.
  BleTransportKeys finish(Uint8List reply) {
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

  @visibleForTesting
  static Uint8List inflate(Uint8List deflated) {
    try {
      return _Inflate(deflated).run();
    } catch (_) {
      throw BleLinkError.badFrame;
    }
  }
}

class _Huffman {
  // Canonical code as in zlib's puff.c; returns 0 if complete, > 0 if incomplete, < 0 if over-subscribed.
  _Huffman(List<int> lengths, this.status) : symbol = List.filled(lengths.length, 0) {
    for (final l in lengths) {
      count[l]++;
    }
    if (count[0] == lengths.length) return;
    var left = 1;
    for (var len = 1; len < 16; len++) {
      left = (left << 1) - count[len];
      if (left < 0) {
        status = left;
        return;
      }
    }
    status = left;
    final offs = List.filled(16, 0);
    for (var len = 1; len < 15; len++) {
      offs[len + 1] = offs[len] + count[len];
    }
    for (var s = 0; s < lengths.length; s++) {
      if (lengths[s] != 0) symbol[offs[lengths[s]]++] = s;
    }
  }

  final count = List.filled(16, 0);
  final List<int> symbol;
  int status;
}

// Raw DEFLATE (RFC 1951) after zlib's puff.c. dart:io's inflater returns a cut stream's partial output without an error,
// so this one refuses input that ends before the final block, and output past maxChunk at the byte that crosses it.
class _Inflate {
  _Inflate(this._in);

  static const _lens = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  static const _lext = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  static const _dists = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
    6145, 8193, 12289, 16385, 24577];
  static const _dext = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  static const _order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
  static final _fixedLen = _Huffman([for (var s = 0; s < 288; s++) s < 144 ? 8 : s < 256 ? 9 : s < 280 ? 7 : 8], 0);
  static final _fixedDist = _Huffman(List.filled(30, 5), 0);

  final Uint8List _in;
  final _out = Uint8List(BleTransportKeys.maxChunk);
  var _pos = 0, _outLen = 0, _bitBuf = 0, _bitCnt = 0;

  Never _fail() => throw BleLinkError.badFrame;

  int _bits(int need) {
    var val = _bitBuf;
    while (_bitCnt < need) {
      if (_pos == _in.length) _fail(); // the input ran out before the final block ended
      val |= _in[_pos++] << _bitCnt;
      _bitCnt += 8;
    }
    _bitBuf = val >> need;
    _bitCnt -= need;
    return val & ((1 << need) - 1);
  }

  void _put(int byte) {
    if (_outLen == _out.length) _fail();
    _out[_outLen++] = byte;
  }

  int _decode(_Huffman h) {
    var code = 0, first = 0, index = 0;
    for (var len = 1; len < 16; len++) {
      code |= _bits(1);
      final count = h.count[len];
      if (code - count < first) return h.symbol[index + code - first];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    _fail();
  }

  void _stored() {
    _bitBuf = _bitCnt = 0;
    if (_pos + 4 > _in.length) _fail();
    final len = _in[_pos] | _in[_pos + 1] << 8;
    if (_in[_pos + 2] != ~_in[_pos] & 0xff || _in[_pos + 3] != ~_in[_pos + 1] & 0xff) _fail();
    _pos += 4;
    if (_pos + len > _in.length) _fail();
    for (var i = 0; i < len; i++) {
      _put(_in[_pos++]);
    }
  }

  void _codes(_Huffman lengths, _Huffman distances) {
    for (var symbol = _decode(lengths); symbol != 256; symbol = _decode(lengths)) {
      if (symbol < 256) {
        _put(symbol);
        continue;
      }
      symbol -= 257;
      if (symbol >= 29) _fail();
      final len = _lens[symbol] + _bits(_lext[symbol]);
      symbol = _decode(distances);
      if (symbol >= 30) _fail();
      final dist = _dists[symbol] + _bits(_dext[symbol]);
      if (dist > _outLen) _fail();
      for (var i = 0; i < len; i++) {
        _put(_out[_outLen - dist]);
      }
    }
  }

  void _dynamic() {
    final nlen = _bits(5) + 257, ndist = _bits(5) + 1, ncode = _bits(4) + 4;
    if (nlen > 286 || ndist > 30) _fail();
    final lengths = List.filled(nlen + ndist, 0), codeLengths = List.filled(19, 0);
    for (var i = 0; i < ncode; i++) {
      codeLengths[_order[i]] = _bits(3);
    }
    final lencode = _Huffman(codeLengths, 0);
    if (lencode.status != 0) _fail();
    for (var index = 0; index < nlen + ndist;) {
      final symbol = _decode(lencode);
      if (symbol < 16) {
        lengths[index++] = symbol;
        continue;
      }
      var len = 0, repeat = 0;
      if (symbol == 16) {
        if (index == 0) _fail();
        len = lengths[index - 1];
        repeat = 3 + _bits(2);
      } else {
        repeat = symbol == 17 ? 3 + _bits(3) : 11 + _bits(7);
      }
      if (index + repeat > nlen + ndist) _fail();
      lengths.fillRange(index, index += repeat, len);
    }
    if (lengths[256] == 0) _fail();
    // An incomplete code is allowed only when it holds a single symbol, as in zlib.
    _Huffman checked(List<int> l) {
      final h = _Huffman(l, 0);
      if (h.status < 0 || (h.status > 0 && l.length - h.count[0] != 1)) _fail();
      return h;
    }

    _codes(checked(lengths.sublist(0, nlen)), checked(lengths.sublist(nlen)));
  }

  Uint8List run() {
    for (var last = 0; last == 0;) {
      last = _bits(1);
      switch (_bits(2)) {
        case 0:
          _stored();
        case 1:
          _codes(_fixedLen, _fixedDist);
        case 2:
          _dynamic();
        default:
          _fail();
      }
    }
    if (_outLen == 0) _fail();
    return Uint8List.sublistView(_out, 0, _outLen);
  }
}

/// `u16 big-endian length ‖ body` stream framing, used for every message on the L2CAP stream.
class BleFramer {
  final _buffer = BytesBuilder(copy: false);

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
