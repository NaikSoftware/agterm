import 'grid.dart';

enum ClaudeMode { manual, acceptEdits, plan, auto, bypass }

final _rule = RegExp(r'^─+( .* ─+)?$');
final _spinner = RegExp(r'^[✶✻✽✢·] \S+…( \(|$)');
final _toolCall = RegExp(r'^⏺ [\w.:-]+\(');
final _paste = RegExp(r'^\[Pasted text #\d+( \+\d+ lines)?\]$');
final _shells = RegExp(r'·\s*(\d+)\s*shells?');
const _modes = {
  'manual': ClaudeMode.manual,
  'acceptedits': ClaudeMode.acceptEdits,
  'planmode': ClaudeMode.plan,
  'automode': ClaudeMode.auto,
  'bypass': ClaudeMode.bypass,
};

/// Claude Code's live state read from one grid frame; every rule compares width-agnostically.
class ClaudeScreen {
  ClaudeScreen._(this._blank);

  final bool _blank;
  bool bottomStack = false;
  String? input;
  (int, int)? inputRows; // the input block's first row and its closing rule
  String draft = '';
  bool pastePlaceholder = false;
  String? working;

  /// The spinner row or `esc to interrupt` on the footer: 2.1.329 drops the spinner row while reply text streams.
  bool busy = false;
  String? limit;
  List<String> queued = [];
  List<int> statusRows = [];
  (int, int)? streaming;
  int? interrupted;
  ClaudeMode? mode;
  String? modeText;
  int shells = 0;

  /// A single-frame reading; callers act on it only as plan B Task 18 says.
  bool get dialog => !_blank && !bottomStack;
  bool get idle => bottomStack && !busy;

  static ClaudeScreen read(Grid g) {
    final s = ClaudeScreen._(g.blank);
    final n = g.rows.length;
    bool rule(int r) => _rule.hasMatch(g.text(r).trim());

    // the last rule directly followed by a `❯` (or bash-mode `!`) row at column 0, then a closing rule
    var top = -1, bottom = -1;
    for (var r = n - 2; r >= 0 && top < 0; r--) {
      final next = g.text(r + 1);
      if (!rule(r) || !(next.startsWith('❯') || next.startsWith('!'))) continue;
      for (var b = r + 2; b < n; b++) {
        if (rule(b)) {
          (top, bottom) = (r, b);
          break;
        }
      }
    }
    final above = top < 0 ? n : top;

    if (top >= 0) {
      s.bottomStack = true;
      s.inputRows = (top + 1, bottom);
      String strip(String t, int i) => (i == 0 ? t.substring(1) : t).trim();
      final rows = [for (var r = top + 1; r < bottom; r++) r];
      s.input = [for (final (i, r) in rows.indexed) strip(g.text(r), i)].join('\n').trim();
      s.draft = [for (final (i, r) in rows.indexed) strip(g.bright(r), i)].join('\n').trim();
      if (s.draft == 'Press up to edit queued messages') s.draft = '';
      s.pastePlaceholder = _paste.hasMatch(s.input!);

      for (var r = bottom + 1; r < n; r++) {
        final t = g.text(r).trim();
        if (t.isEmpty) continue;
        if (t.contains('mode on') || t.startsWith('⏸') || t.startsWith('⏵')) {
          s.modeText = t;
          break;
        }
        s.statusRows.add(r);
      }
      final m = s.modeText;
      if (m != null) {
        final k = norm(m);
        s.mode = _modes.entries.where((e) => k.contains(e.key)).firstOrNull?.value;
        s.shells = int.tryParse(_shells.firstMatch(m)?.group(1) ?? '') ?? 0;
      }
      s.busy = norm([for (var r = bottom + 1; r < n; r++) g.text(r)].join()).contains('esctointerrupt');
    }

    var prompt = -1, spin = -1;
    for (var r = 0; r < above; r++) {
      final t = g.text(r);
      if (_spinner.hasMatch(t)) spin = r;
      if (t.trimLeft().startsWith('⎿') && t.contains('Interrupted')) s.interrupted = r;
      if (s.limit == null && (t.contains('Usage limit reached') || t.contains('Continuing automatically at'))) {
        s.limit = _block(g, r, above);
      }
      if (!t.startsWith('❯ ')) continue;
      final p = [t.substring(2).trim()];
      var e = r + 1;
      for (; e < above && g.text(e).startsWith('  ') && !norm(g.text(e)).startsWith('⎿'); e++) {
        p.add(g.text(e).trim());
      }
      if (e < n && norm(g.text(e)).startsWith('⎿Queued')) {
        s.queued.add(p.join(' '));
      } else {
        prompt = r;
      }
    }
    if (spin >= 0) {
      s.busy = s.bottomStack;
      final w = StringBuffer(g.text(spin).substring(2).trim());
      for (var r = spin + 1; w.toString().contains(' (') && !w.toString().contains(')') && r < above; r++) {
        final t = g.text(r).trim();
        if (t.isEmpty || rule(r)) break;
        w.write(' $t');
      }
      s.working = w.toString();
    }

    if (s.busy) {
      final start = [for (var r = prompt + 1; r < above; r++) r]
          .where((r) => g.text(r).startsWith('⏺ ') && !_toolCall.hasMatch(g.text(r)))
          .lastOrNull;
      if (start != null) {
        var end = start;
        for (var r = start + 1; r < above; r++) {
          final t = g.text(r);
          if (t.isEmpty) continue;
          if (!t.startsWith('  ')) break;
          end = r;
        }
        s.streaming = (start, end);
      }
    }
    return s;
  }

  /// Row [r] joined with its indented continuation rows.
  static String _block(Grid g, int r, int end) {
    final b = [g.text(r).trim()];
    for (var i = r + 1; i < end && g.text(i).startsWith('  '); i++) {
      b.add(g.text(i).trim());
    }
    return b.join(' ');
  }
}
