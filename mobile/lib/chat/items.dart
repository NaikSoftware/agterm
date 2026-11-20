import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';
import 'rows.dart';
import 'transcript.dart';

const _open = MethodChannel('elis/open');

/// Hands [text] to Android's share sheet.
Future<void> shareText(String text) => _open.invokeMethod<bool>('share', text).catchError((_) => false);

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})[^\n]*\n([\s\S]*?)^ {0,3}\1[ \t]*$', multiLine: true);

/// The fenced blocks of [markdown], joined by a blank line; null without one.
String? fencedCode(String markdown) {
  final blocks = [for (final m in _fence.allMatches(markdown)) m[2]!.replaceFirst(RegExp(r'\n$'), '')];
  return blocks.isEmpty ? null : blocks.join('\n\n');
}

Widget chatRowWidget(BuildContext c, ChatRow r, {required bool fresh}) {
  final row = Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _row(c, r));
  return fresh ? _FadeIn(r.key, row) : row;
}

Widget _row(BuildContext c, ChatRow r) {
  if (r.day != null) {
    return Center(
        child: Text(MaterialLocalizations.of(c).formatMediumDate(r.day!), style: const TextStyle(color: C.dim, fontSize: 12)));
  }
  final i = r.item!;
  return switch (i.kind) {
    'user' => _bubble(c, i),
    'text' => _menu(c, i.text ?? '', _markdown(i.text ?? '')),
    _ => Text(i.text ?? i.name ?? i.kind, style: const TextStyle(color: C.muted)),
  };
}

Widget _bubble(BuildContext c, ChatItem i) => Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(left: 48),
        child: _menu(
          c,
          i.text ?? '',
          Container(
            key: Key('bubble-${i.uuid}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(16)),
            child: Text(i.text ?? '', style: const TextStyle(fontSize: 15)),
          ),
        ),
      ),
    );

// `selectable: true` fights the list's scroll, so text leaves through the long-press menu
Widget _menu(BuildContext c, String text, Widget child) => GestureDetector(behavior: HitTestBehavior.opaque, onLongPress: () => _actions(c, text), child: child);

void _actions(BuildContext c, String text) {
  final code = fencedCode(text);
  showModalBottomSheet<void>(
    context: c,
    builder: (sheet) {
      Widget item(IconData icon, String label, VoidCallback run) => ListTile(
          leading: Icon(icon, color: C.muted),
          title: Text(label),
          onTap: () {
            Navigator.pop(sheet);
            run();
          });
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          item(Icons.copy, 'Copy', () => Clipboard.setData(ClipboardData(text: text))),
          if (code != null) item(Icons.code, 'Copy code', () => Clipboard.setData(ClipboardData(text: code))),
          item(Icons.share_outlined, 'Share', () => shareText(text)),
        ]),
      );
    },
  );
}

Widget _markdown(String text) => Builder(
      builder: (c) => MarkdownBody(
        data: text,
        // the default `pre` already scrolls horizontally in the `code` style
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(c)).copyWith(
          code: const TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 13, color: C.termText),
          codeblockDecoration: BoxDecoration(color: C.term, borderRadius: BorderRadius.circular(8)),
        ),
        // model-written: no image fetch or file read, and only web links leave the app
        imageBuilder: (uri, title, alt) => Text(alt ?? '$uri', style: const TextStyle(color: C.muted)),
        onTapLink: (_, href, _) {
          final uri = Uri.tryParse(href ?? '');
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            _open.invokeMethod<bool>('view', href).catchError((_) => false);
          }
        },
      ),
    );

class _FadeIn extends StatelessWidget {
  const _FadeIn(this.id, this.child);

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        builder: (_, t, child) =>
            Opacity(key: Key('fresh-$id'), opacity: t, child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child)),
        child: child,
      );
}
