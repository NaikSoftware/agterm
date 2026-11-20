import 'package:flutter/material.dart';

import '../theme.dart' show C;
import '../theme.dart' as theme show mono;

/// The text field and its send button under a session: Term's and Chat's.
class Composer extends StatelessWidget {
  const Composer(
      {super.key,
      required this.controller,
      required this.focus,
      required this.onSend,
      this.maxLines = 4,
      this.autocorrect = false,
      this.mono = true,
      this.sendLabel = 'Send',
      this.sendIcon = Icons.arrow_forward,
      this.reason,
      this.accessory,
      this.enabled = true});
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback? onSend; // null disables Send
  final int maxLines;
  final bool autocorrect, mono, enabled;
  final String sendLabel;
  final IconData sendIcon;
  final String? reason; // why Send is off, shown above the field
  final Widget? accessory; // a row above the field

  @override
  Widget build(BuildContext context) {
    final send = enabled ? onSend : null;
    final row = Row(children: [
      Expanded(
        child: TextField(
          key: const Key('composer'),
          controller: controller,
          focusNode: focus,
          enabled: enabled,
          minLines: 1,
          maxLines: maxLines,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => send?.call(),
          autocorrect: autocorrect,
          style: TextStyle(fontFamily: mono ? theme.mono : null, fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Type, then send with Enter',
            fillColor: C.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 48,
        height: 48,
        child: FilledButton(
          key: const Key('send'),
          onPressed: send,
          style: FilledButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: Icon(sendIcon, semanticLabel: sendLabel),
        ),
      ),
    ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: reason == null && accessory == null
          ? row
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              ?accessory,
              if (reason case final r?)
                Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(r, style: const TextStyle(fontSize: 12, color: C.muted))),
              row,
            ]),
    );
  }
}
