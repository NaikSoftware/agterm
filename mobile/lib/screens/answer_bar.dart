import 'package:flutter/material.dart';

import '../theme.dart';
import 'prompt.dart';

/// A prompt's first four options as buttons, the first one filled; a tap answers with the option's key.
class AnswerBar extends StatelessWidget {
  const AnswerBar({super.key, required this.options, required this.onAnswer});
  final List<PromptOption> options;
  final void Function(String key) onAnswer;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        child: Row(children: [
          for (final (i, o) in options.take(4).indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: o.label,
                child: SizedBox(
                  height: 40,
                  child: i == 0
                      ? FilledButton(
                          key: Key('answer-${o.key}'),
                          onPressed: () => onAnswer(o.key),
                          style: FilledButton.styleFrom(
                              backgroundColor: C.blocked,
                              foregroundColor: const Color(0xFF1A1206),
                              minimumSize: const Size(0, 40),
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                          child: Text(options.length > 2 ? o.key : '${o.key} · ${o.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        )
                      : OutlinedButton(
                          key: Key('answer-${o.key}'),
                          onPressed: () => onAnswer(o.key),
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), padding: EdgeInsets.zero),
                          child: Text(options.length > 2 ? o.key : '${o.key} · ${o.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                ),
              ),
            ),
          ],
        ]),
      );
}
