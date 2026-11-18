import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../theme.dart';
import 'vt.dart';

/// The cell box of the terminal font at one size.
class CellMetrics {
  CellMetrics._(this.fontSize, this.w, this.h);
  final double fontSize, w, h;

  static final _fits = <(double, int), CellMetrics>{};

  /// The largest size (in quarter points) whose [cols] cells fit in [width].
  static CellMetrics fit(double width, int cols) => _fits.putIfAbsent((width, cols), () {
        final probe = _measure(10);
        return _measure((10 * width / cols / probe.w * 4).floorToDouble() / 4);
      });

  static CellMetrics _measure(double size) {
    final tp = TextPainter(
      text: TextSpan(text: 'M' * 20, style: TextStyle(fontFamily: mono, fontSize: size, height: 1.2)),
      textDirection: TextDirection.ltr,
    )..layout();
    final m = CellMetrics._(size, tp.width / 20, tp.height);
    tp.dispose();
    return m;
  }
}

/// One `ui.Picture` per distinct row content, drawn at the row's own origin, so unchanged and scrolled rows
/// (and every blank row) reuse it. Call [endFrame] after each paint: it frees the pictures that frame did not use.
class RowCache {
  final _pics = <VtRow, ui.Picture>{};
  final _used = <VtRow>{};
  CellMetrics? _m;

  /// Pictures recorded so far (for tests and frame-time notes).
  int built = 0;

  int get live => _pics.length;

  /// [y] is not part of the key: a picture is drawn at its row's origin and the caller translates it.
  ui.Picture rowPicture(int y, VtRow row, CellMetrics m) {
    if (!identical(m, _m)) {
      dispose();
      _m = m;
    }
    _used.add(row);
    return _pics[row] ??= _record(row, m);
  }

  void endFrame() {
    _pics.removeWhere((row, pic) {
      if (_used.contains(row)) return false;
      pic.dispose();
      return true;
    });
    _used.clear();
  }

  void dispose() {
    for (final p in _pics.values) {
      p.dispose();
    }
    _pics.clear();
    _used.clear();
  }

  ui.Picture _record(VtRow row, CellMetrics m) {
    built++;
    final rec = ui.PictureRecorder();
    paintRow(Canvas(rec), row, m);
    return rec.endRecording();
  }
}

// VS16, ZWJ, an SMP pictograph or a BMP Emoji_Presentation code point: the colour emoji font must win over a
// text-style fallback glyph
bool _isEmoji(String t) => t.runes.any((r) => r == 0xFE0F || r == 0x200D || r >= 0x1F000 || _bmpEmoji(r));

// Emoji_Presentation=Yes below U+1F000 (Unicode 15), as inclusive ranges
const _bmpEmojiRanges = [
  0x231A, 0x231B, 0x23E9, 0x23EC, 0x23F0, 0x23F0, 0x23F3, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615, //
  0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, //
  0x26C4, 0x26C5, 0x26CE, 0x26CE, 0x26D4, 0x26D4, 0x26EA, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26F5, //
  0x26FA, 0x26FA, 0x26FD, 0x26FD, 0x2705, 0x2705, 0x270A, 0x270B, 0x2728, 0x2728, 0x274C, 0x274C, //
  0x274E, 0x274E, 0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797, 0x27B0, 0x27B0, 0x27BF, 0x27BF, //
  0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55,
];

bool _bmpEmoji(int r) {
  if (r < 0x231A || r > 0x2B55) return false;
  for (var i = 0; i < _bmpEmojiRanges.length; i += 2) {
    if (r >= _bmpEmojiRanges[i] && r <= _bmpEmojiRanges[i + 1]) return true;
  }
  return false;
}

// the platform's emoji font on Android; nothing is bundled
const _emoji = 'Noto Color Emoji';

/// Draws one row at the origin: background runs, then text. Printable ASCII of one style is batched into a run;
/// every other cell (wide, cluster, combining, symbols) is drawn alone at its column so it cannot drift the grid.
void paintRow(Canvas canvas, VtRow row, CellMetrics m) {
  final cells = row.cells;
  final defFg = C.termText.toARGB32(), defBg = C.term.toARGB32();
  int fgOf(VtCell c) => c.inverse ? (c.bg ?? defBg) : (c.fg ?? defFg);
  int bgOf(VtCell c) => c.inverse ? (c.fg ?? defFg) : (c.bg ?? defBg);

  final bgPaint = Paint();
  var runStart = 0, runBg = defBg;
  void flushBg(int end) {
    if (runBg != defBg) canvas.drawRect(Rect.fromLTWH(runStart * m.w, 0, (end - runStart) * m.w, m.h), bgPaint..color = Color(runBg));
  }

  for (var x = 0; x < cells.length; x++) {
    final bg = bgOf(cells[x]);
    if (bg != runBg) {
      flushBg(x);
      runStart = x;
      runBg = bg;
    }
  }
  flushBg(cells.length);

  final run = StringBuffer();
  var runX = 0, runFg = 0, runStyle = 0;
  void flushText() {
    if (run.isNotEmpty) canvas.drawParagraph(_para(run.toString(), runFg, runStyle, m), Offset(runX * m.w, 0));
    run.clear();
  }

  for (var x = 0; x < cells.length; x++) {
    final c = cells[x];
    final t = c.text;
    // a space is skipped unless it carries an underline or strike-through
    if (c.spacer || t.isEmpty || (t == ' ' && c.flags & (4 | 32) == 0) || c.invisible) {
      flushText();
      continue;
    }
    final fg = fgOf(c), style = c.flags & 0xFF; // the upper bits hold the cluster length
    if (t.length == 1 && t.codeUnitAt(0) < 128) {
      if (run.isNotEmpty && (fg != runFg || style != runStyle)) flushText();
      if (run.isEmpty) (runX, runFg, runStyle) = (x, fg, style);
      run.write(t == ' ' ? '\u00A0' : t); // a decorated space: the paragraph skips decorations on trailing spaces
    } else {
      flushText();
      canvas.drawParagraph(_para(t, fg, style, m, emoji: _isEmoji(t)), Offset(x * m.w, 0));
    }
  }
  flushText();
}

ui.Paragraph _para(String text, int argb, int style, CellMetrics m, {bool emoji = false}) {
  final fg = Color(argb);
  final pb = ui.ParagraphBuilder(ui.ParagraphStyle(maxLines: 1))
    ..pushStyle(ui.TextStyle(
      color: style & 16 != 0 ? fg.withValues(alpha: 0.5) : fg,
      fontFamily: emoji ? _emoji : mono,
      fontFamilyFallback: emoji ? const <String>[] : monoFallback,
      fontSize: m.fontSize,
      height: 1.2,
      fontWeight: style & 1 != 0 ? FontWeight.w700 : FontWeight.w400,
      fontStyle: style & 2 != 0 ? FontStyle.italic : FontStyle.normal,
      decoration: ui.TextDecoration.combine([
        if (style & 4 != 0) ui.TextDecoration.underline,
        if (style & 32 != 0) ui.TextDecoration.lineThrough,
      ]),
      decorationColor: fg,
    ))
    ..addText(text);
  return pb.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
}
