import 'dart:convert';

const linkUpgradeRequest = '{"mux":1}\n';

bool isLinkUpgradeAnswer(String line) {
  try {
    final o = jsonDecode(line);
    return o is Map && isLinkUpgradeReply(o);
  } on FormatException {
    return false;
  }
}

/// The upgrade answer, already decoded.
bool isLinkUpgradeReply(Map o) => o['ok'] == true && o['mux'] == 1;

/// Newline-terminated lines out of a byte stream, in time linear in the bytes: each read is scanned once and the
/// buffer is trimmed once per read.
class LineBuffer {
  final _buffer = <int>[];
  var _start = 0; // the first byte of the line in progress
  var _scanned = 0; // bytes before this hold no newline after _start

  void add(List<int> bytes) => _buffer.addAll(bytes);

  /// The next complete line, or null until more bytes arrive.
  String? next() {
    final nl = _buffer.indexOf(10, _scanned);
    if (nl < 0) {
      if (_start > 0) _buffer.removeRange(0, _start); // removeRange(0, 0) still moves every byte
      _start = 0;
      _scanned = _buffer.length;
      return null;
    }
    final line = utf8.decode(_buffer.sublist(_start, nl), allowMalformed: true);
    _start = _scanned = nl + 1;
    return line;
  }

  /// The bytes after the last line taken; the buffer is empty afterwards.
  List<int> takeRest() {
    final rest = _buffer.sublist(_start);
    _buffer.clear();
    _start = _scanned = 0;
    return rest;
  }
}
