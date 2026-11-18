import 'dart:async';

import 'package:flutter/widgets.dart';

import '../theme.dart';
import 'row_cache.dart';
import 'vt.dart';

/// The emulator's grid scaled to the available width. While [hold] is set (synchronized output, mode 2026) the
/// last frame stays, for at most 1 s.
class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.snapshot, required this.hold});

  final VtSnapshot? snapshot;
  final bool hold;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _cache = RowCache();
  late VtSnapshot? _shown = widget.snapshot;
  Timer? _release;

  @override
  void didUpdateWidget(TerminalView old) {
    super.didUpdateWidget(old);
    if (!widget.hold) {
      _release?.cancel();
      _release = null;
      _shown = widget.snapshot;
    } else {
      // started once per hold, not per snapshot, so a steady stream still shows a frame each second
      _release ??= Timer(const Duration(seconds: 1), () => setState(() {
            _release = null;
            _shown = widget.snapshot;
          }));
    }
  }

  @override
  void dispose() {
    _release?.cancel();
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _shown;
    if (s == null) return const ColoredBox(color: C.term, child: SizedBox.expand());
    return LayoutBuilder(builder: (context, box) {
      final m = CellMetrics.fit(box.maxWidth, s.cols);
      return CustomPaint(size: Size(box.maxWidth, s.rows * m.h), painter: TerminalPainter(s, m, _cache));
    });
  }
}

class TerminalPainter extends CustomPainter {
  TerminalPainter(this.snapshot, this.m, this.cache);

  final VtSnapshot snapshot;
  final CellMetrics m;
  final RowCache cache;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = C.term);
    canvas.clipRect(Offset.zero & size);
    final lines = snapshot.lines;
    for (var y = 0; y < lines.length; y++) {
      canvas.save();
      canvas.translate(0, y * m.h);
      canvas.drawPicture(cache.rowPicture(y, lines[y], m));
      canvas.restore();
    }
    cache.endFrame();
    if (snapshot.cursorVisible) {
      canvas.drawRect(Rect.fromLTWH(snapshot.cursorX * m.w, snapshot.cursorY * m.h, m.w, m.h),
          Paint()..color = C.termText.withValues(alpha: 0.6));
    }
  }

  @override
  bool shouldRepaint(TerminalPainter old) => !identical(old.snapshot, snapshot) || !identical(old.m, m);
}
