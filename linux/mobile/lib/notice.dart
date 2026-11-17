// A notice drops in at the top of the screen, in the root overlay. A SnackBar sat on the session's composer, and one with
// an action never left on its own (Flutter 3.47 persists action snack bars), so it covered the input until it was swiped.
import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

OverlayEntry? _entry;
Timer? _timer;

/// Shows [text] at the top for [duration], replacing the notice already there. Swipe up to dismiss it early.
void showNotice(BuildContext context, String text, {String? action, VoidCallback? onAction, Duration duration = const Duration(seconds: 4)}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  hideNotice();
  _entry = OverlayEntry(
    builder: (_) => _Notice(
      text: text,
      action: action,
      onAction: () {
        hideNotice();
        onAction?.call();
      },
    ),
  );
  overlay.insert(_entry!);
  _timer = Timer(duration, hideNotice);
}

void hideNotice() {
  _timer?.cancel();
  _timer = null;
  _entry?.remove();
  _entry = null;
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action, required this.onAction});
  final String text;
  final String? action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: -1.2, end: 0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (_, y, child) => FractionalTranslation(translation: Offset(0, y), child: child),
              child: Dismissible(
                key: const Key('notice'),
                direction: DismissDirection.up,
                onDismissed: (_) => hideNotice(),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 560, minHeight: 52),
                  decoration: BoxDecoration(
                    color: C.surface2,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: C.line),
                    boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 24, offset: Offset(0, 8))],
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 6, action == null ? 16 : 6, 6),
                      child: Row(children: [
                        Expanded(
                          child: Text(text,
                              maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.35, color: C.text)),
                        ),
                        if (action != null)
                          TextButton(
                            onPressed: onAction,
                            style: TextButton.styleFrom(foregroundColor: C.accent, minimumSize: const Size(48, 44)),
                            child: Text(action!, style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
