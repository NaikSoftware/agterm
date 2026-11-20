import '../terminal/vt.dart';
import 'grid.dart';

final _solid = RegExp(r'^─+( .* ─+)?$');
final _dashed = RegExp(r'^╌+$');
final _numbered = RegExp(r'^(\s*(?:❯\s*)?)(\d+)\.\s+(\[([ ✔])\]\s+)?');
final _unnumbered = RegExp(r'^(\s*(?:❯\s*)?)(\[([ ✔])\]\s+)?');
final _tabBar = RegExp(r'^(←\s+)?[☐☒✔]\s');

class DialogOption {
  DialogOption._(this.number, this.label, this.checked, this.cursor, this.belowRule, this.row, this.lastRow);

  final int? number; // from the "N. " prefix; null for Submit, Next and an unnumbered "Chat about this"
  final String label; // joined across wraps, without the preview box and the "[ ]" mark
  final bool? checked; // "[ ]" false, "[✔]" true, null without a box
  final bool cursor; // "❯" on this row
  final bool belowRule; // under the list's closing rule ("Chat about this")
  final int row, lastRow; // grid rows this option and its description span
}

/// The prompt dialog at the bottom of a Claude Code grid, split into regions; every rule compares width-agnostically.
class PromptDialog {
  PromptDialog._(
    this.top,
    this.header,
    this.body,
    this.boxed,
    this.question,
    this.options,
    this.footer,
    this.review,
    this.answers,
    this.reviewQuestions,
    this.preview,
  );

  final int top; // first grid row of the dialog: the rule above the tab bar or title
  final String header, body, boxed, question, footer;
  final List<DialogOption> options;
  final bool review, preview;
  final List<String> answers, reviewQuestions;

  DialogOption? get cursorOption => options.where((o) => o.cursor).firstOrNull;

  DialogOption? numbered(String label) => options.where((o) => o.number != null && norm(o.label) == norm(label)).firstOrNull;

  /// Null when the grid ends in no title rule or has no numbered option row below the conversation.
  static PromptDialog? read(Grid g) {
    String t(int r) => g.text(r);
    String trimmed(int r) => t(r).trim();
    bool blank(int r) => trimmed(r).isEmpty;
    bool solid(int r) => _solid.hasMatch(trimmed(r));
    bool dashed(int r) => _dashed.hasMatch(trimmed(r));
    int indent(int r) => t(r).length - t(r).trimLeft().length;
    // the text column, past a cursor: `❯    Submit` starts at 5
    int lead(int r) => _unnumbered.firstMatch(t(r))!.group(1)!.length;
    // column-0 conversation rows; a user prompt `❯ text` is only looked for above the options, where no cursor row is
    bool conversation(int r, {bool prompt = true}) => RegExp(prompt ? r'^(⏺|▔|❯ [^\s\d])' : r'^(⏺|▔)').hasMatch(t(r));
    String join(Iterable<int> rows) => [for (final r in rows) trimmed(r)].where((s) => s.isNotEmpty).join(' ');

    // scanned upward from the bottom, so the conversation above the dialog never reaches a region
    var b = g.rows.length - 1;
    while (b >= 0 && blank(b)) {
      b--;
    }
    if (b < 0 || !solid(b)) return null;
    // a `N. ` deeper than a numbered row above it in the same block is wrapped text, not the last option
    bool deeper(int r) {
      final col = _numbered.firstMatch(t(r))!.group(1)!.length;
      for (var u = r - 1; u >= 0 && !blank(u) && !solid(u); u--) {
        if ((_numbered.firstMatch(t(u))?.group(1)!.length ?? col) < col) return true;
      }
      return false;
    }

    var last = b - 1;
    for (; last >= 0 && !(_numbered.hasMatch(t(last)) && !deeper(last)); last--) {
      if (conversation(last, prompt: false)) return null;
    }
    if (last < 0) return null;

    final lastMatch = _numbered.firstMatch(t(last))!;
    final digitCol = lastMatch.group(1)!.length;
    // a `N. ` away from the list's digit column is text: a description or a pasted Other line
    RegExpMatch? numbered(int r) {
      final m = _numbered.firstMatch(t(r));
      return m?.group(1)!.length == digitCol ? m : null;
    }

    var first = last;
    for (var r = last - 1; r >= 0; r--) {
      if (numbered(r) != null) {
        first = r;
      } else if (blank(r) || conversation(r) || (!solid(r) && lead(r) < lastMatch.end)) {
        break;
      }
    }

    var q1 = first - 1;
    while (q1 > 0 && blank(q1)) {
      q1--;
    }
    var q0 = q1 + 1;
    while (q0 > 0 && !blank(q0 - 1) && !solid(q0 - 1) && !dashed(q0 - 1) && !_tabBar.hasMatch(trimmed(q0 - 1))) {
      q0--;
    }

    // a solid rule right above the question closes a scrolled body (the plan); the dialog's own rule is higher
    var top = q0 - 1;
    for (; top >= 0 && !(solid(top) && top != q0 - 1); top--) {
      if (conversation(top)) return null;
    }
    if (top < 0) return null;

    final between = [for (var r = top + 1; r < first; r++) r];
    final tabBar = between.where((r) => _tabBar.hasMatch(trimmed(r))).firstOrNull;
    final dash = between.where(dashed).firstOrNull;
    final String header, body, question;
    var boxed = '';
    if (tabBar != null) {
      header = join([for (var r = top + 1; r <= tabBar; r++) r]);
      body = '';
      question = join([for (var r = tabBar + 1; r < first; r++) r]);
    } else {
      final bodyStart = dash ?? q0;
      header = join([for (var r = top + 1; r < bodyStart; r++) r]);
      body = join([
        for (var r = bodyStart; r < q0; r++)
          if (!solid(r) && !dashed(r)) r,
      ]);
      question = join([for (var r = q0; r < first; r++) r]);
      if (dash != null) {
        final box = <String>[];
        for (var r = dash + 1; r < q0 && !solid(r) && !dashed(r); r++) {
          box.add(trimmed(r).replaceFirst(RegExp(r'^│ ?'), '').trim());
        }
        boxed = box.join();
      }
    }

    final dim = g.colours ? _cells(g.rows[first])[digitCol].fg : null;
    final options = <_Option>[];
    _Option? current;
    var inList = true, belowRule = false;
    for (var r = first; r < b; r++) {
      final cells = _cells(g.rows[r]);
      if (solid(r)) {
        (current, inList, belowRule) = (null, true, true);
      } else if (blank(r)) {
        (current, inList) = (null, false);
      } else if (numbered(r) case final m?) {
        current = _Option(int.parse(m.group(2)!), m.group(4), t(r).trimLeft().startsWith('❯'), belowRule, r, m.end)
          ..take(cells, dim, g.colours);
        options.add(current);
        inList = true;
      } else if (current != null && lead(r) >= current.textCol) {
        current.lastRow = r;
        if (current.open) current.take(cells, dim, g.colours, start: lead(r));
      } else if (inList && lead(r) >= digitCol) {
        final m = _unnumbered.firstMatch(t(r))!;
        current = _Option(null, m.group(3), t(r).trimLeft().startsWith('❯'), belowRule, r, m.end)..take(cells, dim, g.colours);
        options.add(current);
      } else {
        (current, inList) = (null, false);
      }
    }

    // review "● question" and "→ answer" lines, each joined with its deeper-indented wrap rows
    final marked = {'●': <String>[], '→': <String>[]};
    List<String>? into;
    var markCol = 0;
    for (final r in between) {
      final s = trimmed(r);
      final mark = s.isEmpty ? null : marked.keys.where(s.startsWith).firstOrNull;
      if (mark != null) {
        (into, markCol) = (marked[mark], indent(r));
        into!.add(s.substring(1).trim());
      } else if (into != null && s.isNotEmpty && indent(r) > markCol) {
        into.last += ' $s';
      } else {
        into = null;
      }
    }

    final lastRow = options.last.lastRow;
    return PromptDialog._(
      top,
      header,
      body,
      boxed,
      question,
      [for (final o in options) DialogOption._(o.number, o.label.toString().trim(), o.checked, o.cursor, o.belowRule, o.row, o.lastRow)],
      join([for (var r = lastRow + 1; r < b; r++) r]),
      between.any((r) => norm(t(r)) == 'Reviewyouranswers'),
      marked['→']!,
      marked['●']!,
      [for (var r = first; r <= lastRow; r++) t(r)].any((s) => s.contains('┌')),
    );
  }

  static List<VtCell> _cells(VtRow row) => [
    for (final c in row.cells)
      if (!c.spacer) c,
  ];
}

class _Option {
  _Option(this.number, String? mark, this.cursor, this.belowRule, this.row, this.textCol)
    : checked = mark == null ? null : mark == '✔',
      lastRow = row;

  final int? number;
  final bool? checked;
  final bool cursor, belowRule;
  final int row, textCol;
  int lastRow;
  final label = StringBuffer();

  /// Whether the next indented row still belongs to the label rather than its description.
  bool open = true;

  /// Appends the row's label cells from [start]. A label drawn in the dim colour of the `N.` prefix ("Type something.") is whole;
  /// otherwise the first dim cell ends it: the description, a preview box, or " · auto mode handles…".
  void take(List<VtCell> cells, int? dim, bool colours, {int? start}) {
    final from = start ?? textCol;
    if (from >= cells.length) return;
    final wholeDim = colours && cells[from].fg == dim;
    if (start != null && wholeDim) {
      open = false;
      return;
    }
    final s = StringBuffer();
    for (var i = from; i < cells.length; i++) {
      final c = cells[i];
      if (colours && !wholeDim && c.fg == dim && c.text.trim().isNotEmpty) {
        open = false;
        break;
      }
      s.write(c.text.isEmpty ? ' ' : c.text);
    }
    if (wholeDim) open = false;
    final text = s.toString().replaceAll(' ', ' ').trim();
    if (text.isEmpty) return;
    if (label.isNotEmpty) label.write(' ');
    label.write(text);
  }
}
