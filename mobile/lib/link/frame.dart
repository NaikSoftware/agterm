import 'dart:convert';
import 'dart:typed_data';

enum LinkKind {
  open(1),
  opened(2),
  data(3),
  credit(4),
  resize(5),
  grid(6),
  resync(7),
  lead(8),
  close(9);

  const LinkKind(this.code);
  final int code;

  static LinkKind? fromCode(int code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

const linkMaxPayload = 65536;
const linkHeaderSize = 9;

/// One mux frame: kind (1) | channel (4, big-endian) | payload length (4, big-endian) | payload.
class LinkFrame {
  LinkFrame(this.kind, this.channel, this.payload);

  final LinkKind kind;
  final int channel;
  final Uint8List payload;

  /// Does not validate; the decoder does.
  Uint8List encode() {
    final out = Uint8List(linkHeaderSize + payload.length);
    ByteData.sublistView(out)
      ..setUint8(0, kind.code)
      ..setUint32(1, channel)
      ..setUint32(5, payload.length);
    out.setRange(linkHeaderSize, out.length, payload);
    return out;
  }

  factory LinkFrame.data(int channel, List<int> bytes) => LinkFrame(LinkKind.data, channel, Uint8List.fromList(bytes));

  factory LinkFrame.credit(int channel, int bytes) {
    final p = Uint8List(4);
    ByteData.sublistView(p).setUint32(0, bytes);
    return LinkFrame(LinkKind.credit, channel, p);
  }

  factory LinkFrame.resize(int channel, int cols, int rows) {
    final p = Uint8List(4);
    ByteData.sublistView(p)
      ..setUint16(0, cols)
      ..setUint16(2, rows);
    return LinkFrame(LinkKind.resize, channel, p);
  }

  /// Sorted keys keep the bytes identical to the Swift encoder's.
  factory LinkFrame.json(LinkKind kind, int channel, Map<String, Object> object) =>
      LinkFrame(kind, channel, Uint8List.fromList(utf8.encode(jsonEncode(_sorted(object)))));
}

Object _sorted(Object v) => switch (v) {
      Map() => {for (final k in (v.keys.cast<String>().toList()..sort())) k: _sorted(v[k] as Object)},
      List() => [for (final e in v) _sorted(e as Object)],
      _ => v,
    };
