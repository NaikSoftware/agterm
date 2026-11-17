import 'dart:typed_data';

import 'frame.dart';

class LinkError implements Exception {
  LinkError(this.code, this.value);

  /// `unknownKind`, `payloadTooLarge` or `badPayload`.
  final String code;
  final int value;

  @override
  String toString() => 'LinkError($code, $value)';
}

/// Reassembles frames from arbitrary byte chunks. After an error it is spent and rethrows it on every feed.
class LinkDecoder {
  Uint8List _buffer = Uint8List(0);
  LinkError? _failure;

  List<LinkFrame> feed(List<int> bytes) {
    if (_failure case final f?) throw f;
    _buffer = Uint8List.fromList([..._buffer, ...bytes]);
    final frames = <LinkFrame>[];
    var offset = 0;
    try {
      for (;;) {
        final frame = _next(offset);
        if (frame == null) break;
        frames.add(frame);
        offset += linkHeaderSize + frame.payload.length;
      }
    } on LinkError catch (e) {
      _failure = e;
      _buffer = Uint8List(0);
      rethrow;
    }
    _buffer = Uint8List.fromList(_buffer.sublist(offset));
    return frames;
  }

  LinkFrame? _next(int start) {
    if (_buffer.length - start < linkHeaderSize) return null;
    final d = ByteData.sublistView(_buffer);
    final code = d.getUint8(start);
    final kind = LinkKind.fromCode(code);
    if (kind == null) throw LinkError('unknownKind', code);
    final length = d.getUint32(start + 5);
    if (length > linkMaxPayload) throw LinkError('payloadTooLarge', length);
    final end = start + linkHeaderSize + length;
    if (_buffer.length < end) return null;
    final fixed = switch (kind) {
      LinkKind.credit || LinkKind.resize || LinkKind.grid => 4,
      LinkKind.resync => 0,
      _ => null,
    };
    if (fixed != null && fixed != length) throw LinkError('badPayload', length);
    return LinkFrame(kind, d.getUint32(start + 1), Uint8List.fromList(_buffer.sublist(start + linkHeaderSize, end)));
  }
}
