// The look from the "agterm Mobile" design canvas: terminal-native dark, Inter for UI, JetBrains Mono for terminal text.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

abstract final class C {
  static const bg = Color(0xFF0D0E12);
  static const surface = Color(0xFF16181F);
  static const surface2 = Color(0xFF1E2029);
  static const line = Color(0xFF2A2D39);
  static const term = Color(0xFF08090C);
  static const text = Color(0xFFECEAF3);
  static const termText = Color(0xFFD9D6E2);
  static const muted = Color(0xFFA09EAE);
  static const dim = Color(0xFF6F6D7C);
  static const accent = Color(0xFFB9B4FF);
  static const blocked = Color(0xFFFF9F0A);
  static const blockedText = Color(0xFFFFB240);
  static const blockedBg = Color(0xFF1F1A12);
  static const blockedLine = Color(0xFF4A3512);
  static const blockedChip = Color(0xFF2A2016);
  static const completed = Color(0xFF30D158);
  static const completedText = Color(0xFF4ADE80);
  static const active = Color(0xFFDBD9E6);
  static const danger = Color(0xFFFF6B6B);
}

const mono = 'JetBrainsMono';

// agterm's seven tint names → swatches
const tints = {
  'red': Color(0xFFFF6B6B),
  'orange': Color(0xFFFF9F0A),
  'yellow': Color(0xFFFFD60A),
  'green': Color(0xFF30D158),
  'blue': Color(0xFF64A8FF),
  'purple': Color(0xFFBF8CFF),
  'gray': Color(0xFF9A98A8),
};

Color statusColor(String status) => switch (status) {
      'blocked' => C.blocked,
      'completed' => C.completed,
      'active' => C.active,
      _ => Colors.transparent,
    };

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
    snackBarTheme: const SnackBarThemeData(backgroundColor: C.surface2, contentTextStyle: TextStyle(color: C.text), behavior: SnackBarBehavior.floating),
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

const sectionLabel = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1, color: C.muted);

class StatusDot extends StatefulWidget {
  const StatusDot(this.status, {super.key, this.size = 8, this.blink = false});
  final String status;
  final double size;
  final bool blink; // the agent asked for a pulse (`active --blink` while it works)

  @override
  State<StatusDot> createState() => _StatusDotState();
}

// the desktop sidebar's fade: one cosine cycle a second, alpha 0.2 to 1
class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  bool get _pulsing => widget.blink && widget.status != 'idle' && widget.status.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_pulsing) pulse.repeat();
  }

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    if (_pulsing && !pulse.isAnimating) pulse.repeat();
    if (!_pulsing && pulse.isAnimating) pulse.reset();
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: statusColor(widget.status),
        border: widget.status == 'idle' || widget.status.isEmpty ? Border.all(color: C.dim, width: 1.5) : null,
      ),
    );
    if (!_pulsing) return dot;
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, child) => Opacity(opacity: 0.2 + 0.8 * (0.5 + 0.5 * cos(pulse.value * 2 * pi)), child: child),
      child: dot,
    );
  }
}

const agentNames = {'claude': 'Claude Code', 'codex': 'Codex', 'opencode': 'OpenCode', 'antigravity': 'Antigravity'};

// the agent's logo from agterm-qt's launcher icons, or a prompt glyph for a plain terminal
class AgentIcon extends StatelessWidget {
  const AgentIcon(this.agent, {super.key, this.size = 36, this.background = C.surface2});
  final String agent;
  final double size;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final color = switch (agent) {
      'claude' => const Color(0xFFF0B37E),
      'codex' => C.accent,
      'antigravity' => const Color(0xFF7FB2FF),
      _ => C.text,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(size * 0.28)),
      alignment: Alignment.center,
      child: agentNames.containsKey(agent)
          ? SvgPicture.asset('assets/agents/$agent.svg', width: size * 0.5, height: size * 0.5, colorFilter: ColorFilter.mode(color, BlendMode.srcIn))
          : Text('>_', style: TextStyle(fontFamily: mono, fontWeight: FontWeight.w700, fontSize: size * 0.36, color: C.muted)),
    );
  }
}
