// The look from the Elis design: terminal-native dark, Inter for UI, JetBrains Mono for terminal text.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

abstract final class C {
  static const bg = Color(0xFF1C1C20);
  static const surface = Color(0xFF26262B);
  static const surface2 = Color(0xFF2E2E34);
  static const line = Color(0xFF303034);
  static const hover = Color(0x0FE8E8EC);
  static const sel = Color(0x1FE8E8EC);
  static const term = Color(0xFF111114);
  static const text = Color(0xFFE8E8EC);
  static const termText = Color(0xFFD9D6E2);
  static const muted = Color(0xFFA3A3AB);
  static const dim = Color(0xFF6E6E76);
  static const accent = Color(0xFFE08A45); // the logo copper tuned for dark grounds
  static const indigo = Color(0xFF8B8CFF); // the flag, as on the desktop
  static const blocked = Color(0xFFFF9F43);
  static const blockedText = Color(0xFFFFB240);
  static const blockedBg = Color(0xFF2E2623); // blocked 8% over bg
  static const blockedLine = Color(0x4DFF9F43);
  static const blockedChip = Color(0xFF372C24); // blocked 12% over bg
  static const blockedTile = Color(0xFF3C2E25); // blocked 14% over bg
  static const completed = Color(0xFF3FCF73);
  static const completedText = Color(0xFF4ADE80);
  static const active = Color(0xFF5B9CFF);
  static const idle = Color(0xFFD8D8DE);
  static const unseen = Color(0xFFFF453A);
  static const danger = Color(0xFFFF6B6B);
}

const mono = 'JetBrainsMono';
const monoFallback = ['NotoSansSymbols2'];

// Claude Code's ⏺ and ⎿ have no glyph in either font; these look the same and keep the grid
String withGridGlyphs(String text) => text.replaceAll('⏺', '●').replaceAll('⎿', '└');

// elis's seven tint names → swatches
const tints = {
  'red': Color(0xFFFF6B6B),
  'orange': Color(0xFFFF9F0A),
  'yellow': Color(0xFFFFD60A),
  'green': Color(0xFF30D158),
  'blue': Color(0xFF64A8FF),
  'purple': Color(0xFFBF8CFF),
  'gray': Color(0xFF9A98A8),
};

// the rest of macOS's palette, and any `#rrggbb` hex; kept out of `tints` so the picker offers only what both servers accept
const _macTints = {
  'teal': Color(0xFF40C8E0),
  'pink': Color(0xFFFF6482),
  'brown': Color(0xFFAC8E68),
  'indigo': Color(0xFF7D7AFF),
  'mint': Color(0xFF63E6E2),
};

Color? tintColor(String tint) {
  final hex = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(tint);
  return hex != null ? Color(0xFF000000 | int.parse(hex[1]!, radix: 16)) : tints[tint] ?? _macTints[tint];
}

String statusLabel(String status) => switch (status) {
      'blocked' => 'Blocked',
      'completed' => 'Done',
      'active' => 'Working',
      _ => 'Idle',
    };

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(
      surface: C.bg,
      primary: C.accent,
      onPrimary: C.bg,
      secondary: C.accent,
      error: C.danger,
      onSurface: C.text,
      surfaceContainerHighest: C.surface2,
      surfaceContainerHigh: C.surface,
      surfaceContainer: C.surface,
      outline: C.line,
      outlineVariant: C.line,
    ),
  );
  OutlineInputBorder border(Color c) => OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c));
  return base.copyWith(
    appBarTheme: const AppBarTheme(backgroundColor: C.bg, surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: C.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        showDragHandle: true,
        dragHandleColor: Color(0xFF3A3D4A)),
    dialogTheme: const DialogThemeData(backgroundColor: C.surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(color: C.surface2, surfaceTintColor: Colors.transparent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.bg,
      hintStyle: const TextStyle(color: C.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: border(C.line),
      border: border(C.line),
      focusedBorder: border(C.accent),
    ),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            minimumSize: const Size(48, 52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15))),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: C.text,
            backgroundColor: C.surface,
            minimumSize: const Size(44, 44),
            side: const BorderSide(color: C.line),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)))),
    dividerTheme: const DividerThemeData(color: C.line, space: 1),
  );
}

// the app icon beside the app name, the same on the home and pairing screens
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.29),
        child: SvgPicture.asset('assets/elis-icon.svg', width: size, height: size, semanticsLabel: 'Elis'),
      );
}

const sectionLabel = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: C.muted);

// the desktop sidebar's glyphs: active fades, blocked blinks, completed is a diamond; `blink` (the agent's
// `--blink`) also fades a completed one, the only status the shape does not animate on its own
class StatusShape extends StatefulWidget {
  const StatusShape(this.status, {super.key, this.size = 10, this.blink = false, this.still = false});
  final String status;
  final double size;
  final bool blink, still;

  @override
  State<StatusShape> createState() => _StatusShapeState();
}

class _StatusShapeState extends State<StatusShape> with SingleTickerProviderStateMixin {
  late final fade = AnimationController(vsync: this);
  late final opacity = fade.drive(CurveTween(curve: Curves.easeInOut)).drive(Tween(begin: 1.0, end: 0.25));

  Duration? get _period => widget.still || MediaQuery.disableAnimationsOf(context)
      ? null
      : switch (widget.status) {
          'blocked' => const Duration(milliseconds: 500),
          'active' => const Duration(milliseconds: 1400),
          'completed' when widget.blink => const Duration(milliseconds: 1400),
          _ => null,
        };

  void _sync() {
    final p = _period;
    if (p == null) {
      fade.value = 0;
    } else if (!fade.isAnimating || fade.duration != p) {
      fade.duration = p;
      fade.repeat(reverse: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StatusShape old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.status.isEmpty) return const SizedBox.shrink();
    return FadeTransition(
      opacity: opacity,
      child: CustomPaint(size: Size.square(widget.size * 1.2), painter: _ShapePainter(widget.status, widget.size)),
    );
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.status, this.size);
  final String status;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    final c = box.center(Offset.zero);
    final paint = Paint()
      ..color = switch (status) {
        'blocked' => C.blocked,
        'completed' => C.completed,
        'active' => C.active,
        _ => C.idle,
      };
    switch (status) {
      case 'blocked':
        final w = size * 1.2, h = size * 1.1;
        canvas.drawPath(
            Path()
              ..moveTo(c.dx, c.dy - h / 2)
              ..lineTo(c.dx + w / 2, c.dy + h / 2)
              ..lineTo(c.dx - w / 2, c.dy + h / 2)
              ..close(),
            paint);
      case 'completed':
        canvas
          ..save()
          ..translate(c.dx, c.dy)
          ..rotate(pi / 4)
          ..drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: size * 0.85, height: size * 0.85), const Radius.circular(1.5)), paint)
          ..restore();
      default:
        canvas.drawCircle(c, size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) => old.status != status || old.size != size;
}

// lucide icons (ISC), drawn in one color
const lucideSquareStack = '<path d="M4 10c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h4c1.1 0 2 .9 2 2"/>'
    '<path d="M10 16c-1.1 0-2-.9-2-2v-4c0-1.1.9-2 2-2h4c1.1 0 2 .9 2 2"/><rect width="8" height="8" x="14" y="14" rx="2"/>';
const lucideTerminal = '<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>';
const lucideFlag = '<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" x2="4" y1="22" y2="15"/>';

class Lucide extends StatelessWidget {
  const Lucide(this.paths, {super.key, this.size = 18, this.color = C.muted});
  final String paths;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round">$paths</svg>',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
}

const agentNames = {'claude': 'Claude Code', 'codex': 'Codex', 'opencode': 'OpenCode', 'antigravity': 'Antigravity'};

Color agentColor(String agent) => switch (agent) {
      'claude' => const Color(0xFFF0B37E),
      'codex' => const Color(0xFFB9B4FF),
      'antigravity' => const Color(0xFF7FB2FF),
      _ => C.text,
    };

// the agent's logo from elis's launcher icons, or the terminal glyph for a plain shell
class AgentLogo extends StatelessWidget {
  const AgentLogo(this.agent, {super.key, this.size = 16, this.color});
  final String agent;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => agentNames.containsKey(agent)
      ? SvgPicture.asset('assets/agents/$agent.svg',
          width: size, height: size, semanticsLabel: agentNames[agent], colorFilter: ColorFilter.mode(color ?? agentColor(agent), BlendMode.srcIn))
      : Lucide(lucideTerminal, size: size + 2, color: color ?? C.muted);
}

// the logo on a rounded tile, or a prompt glyph for a plain terminal
class AgentIcon extends StatelessWidget {
  const AgentIcon(this.agent, {super.key, this.size = 36, this.background = C.surface2});
  final String agent;
  final double size;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(size * 0.28)),
        alignment: Alignment.center,
        child: agentNames.containsKey(agent)
            ? AgentLogo(agent, size: size * 0.5)
            : Text('>_', style: TextStyle(fontFamily: mono, fontWeight: FontWeight.w700, fontSize: size * 0.36, color: C.muted)),
      );
}
