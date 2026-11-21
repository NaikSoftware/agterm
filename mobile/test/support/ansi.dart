import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/terminal/vt.dart';

const _bold = 1, _faint = 16;

/// Replays a `tmux capture-pane -p -e` capture into a [Grid], one cell per rune.
/// Keeps bold, faint and the foreground; fg values are opaque keys, compared for equality only.
Grid gridFromAnsi(String capture) {
  final lines = capture.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  int? fg;
  var flags = 0;
  final rows = <VtRow>[];
  // tmux carries SGR state across lines, so it is never reset at a newline
  for (final line in lines) {
    final cells = <VtCell>[];
    final runes = line.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final ch = runes[i];
      if (ch == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        // CSI: parameters up to the final byte 0x40..0x7e
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        if (j < runes.length && runes[j] == 0x6d) {
          (fg, flags) = _sgr(String.fromCharCodes(runes, i + 2, j), fg, flags);
        }
        i = j + 1;
      } else if (ch == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5d) {
        // OSC (an OSC 8 link): up to BEL or ESC \
        var j = i + 2;
        while (j < runes.length && runes[j] != 7 && !(runes[j] == 0x1b && j + 1 < runes.length && runes[j + 1] == 0x5c)) {
          j++;
        }
        i = j < runes.length && runes[j] == 7 ? j + 1 : j + 2;
      } else if (ch == 0x1b) {
        i += 2;
      } else if (ch < 0x20) {
        i++;
      } else {
        cells.add(VtCell(String.fromCharCode(ch), fg: fg, flags: flags));
        i++;
      }
    }
    rows.add(VtRow(cells));
  }
  return Grid(rows);
}

(int?, int) _sgr(String params, int? fg, int flags) {
  final p = params.isEmpty ? [0] : [for (final s in params.split(';')) int.tryParse(s.split(':').first) ?? -1];
  for (var k = 0; k < p.length; k++) {
    final v = p[k];
    switch (v) {
      case 0:
        fg = null;
        flags = 0;
      case 1:
        flags |= _bold;
      case 2:
        flags |= _faint;
      case 22:
        flags &= ~(_bold | _faint);
      case 39:
        fg = null;
      case >= 30 && <= 37:
        fg = v - 30;
      case >= 90 && <= 97:
        fg = v - 90 + 8;
      case 38 || 48 || 58:
        final mode = k + 1 < p.length ? p[k + 1] : -1;
        final n = mode == 5 ? 1 : (mode == 2 ? 3 : 0);
        if (v == 38 && n == 1 && k + 2 < p.length) fg = p[k + 2];
        if (v == 38 && n == 3 && k + 4 < p.length) fg = 0xff000000 | p[k + 2] << 16 | p[k + 3] << 8 | p[k + 4];
        k += 1 + n;
    }
  }
  return (fg, flags);
}
