import 'package:flutter/material.dart';

import '../screens/answer_bar.dart';
import '../screens/prompt.dart';
import '../terminal/key_bar.dart';
import '../terminal/terminal_view.dart';
import '../terminal/vt.dart';
import '../theme.dart';
import 'grid.dart';

/// Claude's live rows with the key bar and the answer bar, for a screen Chat does not draw; its keys bypass the gate.
class PanelSheet extends StatefulWidget {
  const PanelSheet({super.key, required this.grid, required this.onKey, required this.onAnswer, required this.onHide, this.stopped});

  final Grid? grid;
  final void Function(String? seq, VtKey? key, int mods) onKey;
  final void Function(String key) onAnswer;
  final VoidCallback onHide;
  final String? stopped; // shown verbatim at the top

  @override
  State<PanelSheet> createState() => _PanelSheetState();
}

class _PanelSheetState extends State<PanelSheet> {
  double _drag = 0;

  @override
  Widget build(BuildContext context) {
    final g = widget.grid;
    final text = g == null ? '' : [for (var r = 0; r < g.rows.length; r++) g.text(r)].join('\n');
    final options = promptOptions(text);
    final snapshot = g?.snapshot;
    return Material(
      key: const Key('panelSheet'),
      color: C.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(children: [
          // the rows scroll, so only the handle takes the swipe
          GestureDetector(
            key: const Key('panelHandle'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _drag = 0,
            onVerticalDragUpdate: (d) => _drag += d.delta.dy,
            onVerticalDragEnd: (d) {
              if (_drag > 48 || (d.primaryVelocity ?? 0) > 300) widget.onHide();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                  child: Container(width: 36, height: 4, decoration: BoxDecoration(color: C.muted, borderRadius: BorderRadius.circular(2)))),
            ),
          ),
          if (widget.stopped case final s?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text(s, key: const Key('panelStopped'), style: const TextStyle(fontSize: 13))),
            ),
          Expanded(
            child: ColoredBox(
              color: C.term,
              // bottom first: Claude draws its panels at the end of the grid
              child: SingleChildScrollView(
                reverse: true,
                child: snapshot != null
                    ? TerminalView(snapshot: snapshot, hold: false)
                    : Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(text, key: const Key('panelText'), style: const TextStyle(fontFamily: mono, fontSize: 11, color: C.termText)),
                      ),
              ),
            ),
          ),
          if (options.isNotEmpty) AnswerBar(options: options, onAnswer: widget.onAnswer),
          KeyBar(onKey: widget.onKey),
        ]),
      ),
    );
  }
}
