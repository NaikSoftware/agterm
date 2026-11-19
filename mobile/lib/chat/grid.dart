import '../terminal/vt.dart';

/// [s] with all whitespace removed: the comparison form of every anchor, so wrapping never matters.
String norm(String s) => s.replaceAll(RegExp(r'\s'), '');

/// The screen Chat reads Claude's live state from: vt rows, or plain `session.text` lines without styles.
class Grid {
  Grid(this.rows, {this.colours = true});

  Grid.of(VtSnapshot s) : this(s.lines);

  /// `session.text` carries no SGR, so [bright] cannot tell a dim placeholder from a draft.
  Grid.text(String screen)
      : this([
          for (final line in screen.split('\n')) VtRow([for (final r in line.runes) VtCell(String.fromCharCode(r))]),
        ], colours: false);

  final List<VtRow> rows;
  final bool colours;

  /// Row [r] as text, spacers skipped and trailing blanks trimmed.
  // Claude writes U+00A0 after its `❯`; anchors compare plain spaces
  String text(int r) => rows[r].text.replaceAll('\u00a0', ' ');

  /// Row [r] with faint cells as spaces, trailing blanks trimmed.
  String bright(int r) {
    final b = StringBuffer();
    for (final c in rows[r].cells) {
      if (!c.spacer) b.write(c.text.isEmpty || c.faint ? ' ' : c.text);
    }
    return b.toString().replaceAll('\u00a0', ' ').trimRight();
  }

  bool get blank => rows.every((r) => r.text.isEmpty);
}
