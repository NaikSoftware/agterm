import 'dart:async';

import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/write_gate.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A write as the script matches it: the text, the key's name, or `paste:<text>`.
String sent(GateWrite w) => switch (w) {
  TextWrite(:final text) => text,
  KeyWrite(:final key) => key.name,
  PasteWrite(:final text) => 'paste:$text',
};

/// Claude as a script of grids: a write matching the next entry shows its grid; any other write leaves the grid as it is.
/// [between] shows a grid when the step after `k` writes starts: an answer typed on the computer.
class ScriptedGrids extends ChangeNotifier implements GateWriter {
  ScriptedGrids(List<(Matcher write, Grid next)> script, Grid first, {Map<int, Grid> between = const {}})
    : _script = [...script],
      _between = {...between},
      grid = first;

  final List<(Matcher, Grid)> _script;
  final Map<int, Grid> _between;
  final writes = <GateWrite>[];
  Grid grid;

  List<String> get sentWrites => [for (final w in writes) sent(w)];

  @override
  Future<bool> lead() async {
    if (_between.remove(writes.length) case final g?) grid = g;
    return true;
  }

  @override
  Future<bool> write(GateWrite w) async {
    writes.add(w);
    if (_script.isNotEmpty && _script.first.$1.matches(sent(w), {})) {
      grid = _script.removeAt(0).$2;
      scheduleMicrotask(notifyListeners);
    }
    return true;
  }

  @override
  bool pasteSafe(String text) => true; // bracketed paste
}

/// [g] with the bottom-most occurrence of [from] in a row's text replaced by [to], keeping each cell's style.
Grid retext(Grid g, String from, String to) {
  for (var r = g.rows.length - 1; r >= 0; r--) {
    final at = g.text(r).indexOf(from);
    if (at < 0) continue;
    final cells = g.rows[r].cells;
    final style = cells[at];
    final next = [
      ...cells.take(at),
      for (final (i, ch) in to.split('').indexed)
        VtCell(ch, fg: (at + i < at + from.length ? cells[at + i] : style).fg, flags: style.flags),
      ...cells.skip(at + from.length),
    ];
    return Grid([...g.rows.take(r), VtRow(next), ...g.rows.skip(r + 1)]);
  }
  throw ArgumentError('no row shows $from');
}
