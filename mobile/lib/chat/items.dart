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

/// [exited] and [stale] turn open subagent rows to "stopped".
Widget chatRowWidget(BuildContext c, ChatRow r, {required bool fresh, bool exited = false, bool stale = false}) {
  final row = Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _row(c, r, exited || stale));
  return fresh ? _FadeIn(r.key, row) : row;
}

Widget _row(BuildContext c, ChatRow r, bool gone) {
  if (r.day != null) {
    return Center(
        child: Text(MaterialLocalizations.of(c).formatMediumDate(r.day!), style: const TextStyle(color: C.dim, fontSize: 12)));
  }
  if (r.group.isNotEmpty) {
    return _Expandable(
      key: ValueKey(r.key),
      title: Text(groupLabel(r.group)),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final t in r.group) _toolRow(t, stopped: false)]),
    );
  }
  final i = r.item!;
  return switch (i.kind) {
    'user' => _bubble(c, i),
    'text' => _menu(c, i.text ?? '', _markdown(i.text ?? '')),
    'tool' => _toolRow(i, stopped: r.interruptedAfter || gone),
    _ => Text(i.text ?? i.name ?? i.kind, style: const TextStyle(color: C.muted)),
  };
}

/// The label of a read-only group, e.g. `Read 7 files · Searched 2`.
String groupLabel(List<ChatItem> tools) {
  final read = tools.where((t) => t.name == 'Read').length, listed = tools.where((t) => t.name == 'LS').length;
  final searched = tools.length - read - listed;
  return [
    if (read > 0) 'Read $read ${read == 1 ? 'file' : 'files'}',
    if (searched > 0) 'Searched $searched',
    if (listed > 0) 'Listed $listed',
  ].join(' · ');
}

enum SubagentState { running, finished, stopped }

SubagentState subagentState(ChatItem agentTool, {required bool interruptedAfter, required bool exited, required bool stale}) {
  if (!agentTool.running || agentTool.mark == 'done' || agentTool.mark == 'error') return SubagentState.finished;
  return interruptedAfter || exited || stale ? SubagentState.stopped : SubagentState.running;
}

String markText(String? mark) => switch (mark) {
      null => '',
      'ok' => '✓',
      'error' => '✗',
      'done' => '✓ done',
      final m when m.startsWith('exit ') => '✗ $m',
      final m => m,
    };

const _toolStyle = TextStyle(color: C.muted, fontSize: 13);
const _monoStyle = TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 12, color: C.termText);

Widget _toolRow(ChatItem i, {required bool stopped}) {
  final agent = i.name == 'Agent' || i.name == 'Task';
  final trailing = !agent
      ? markText(i.mark)
      : switch (subagentState(i, interruptedAfter: stopped, exited: false, stale: false)) {
          SubagentState.running => '◯ running',
          SubagentState.stopped => 'stopped',
          SubagentState.finished => markText(i.mark ?? 'done'),
        };
  final patch = i.patch, output = i.output;
  return _Expandable(
    key: ValueKey('tool-${i.uuid}'),
    title: Row(
      spacing: 8,
      children: [
        Text(
          agent ? i.agentName ?? 'Agent' : i.name ?? 'tool',
          style: TextStyle(fontWeight: FontWeight.w600, color: agent ? tintColor(i.agentColor ?? '') : null),
        ),
        if (agent && i.agentType != null) Text(i.agentType!),
        Expanded(child: Text(i.arg ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
        Text(trailing, style: trailing.startsWith('✗') ? const TextStyle(color: C.danger) : null),
      ],
    ),
    body: patch != null
        ? _diff(i.file, patch)
        : output == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(output, style: _monoStyle),
                  if (i.clipped) const Text('Full output in Term', style: TextStyle(color: C.dim)),
                ],
              ),
  );
}

Color? _lineColor(String l) => l.startsWith('-') ? C.danger : l.startsWith('+') ? C.completedText : null;

Widget _diff(String? file, List<Hunk> hunks) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final h in hunks) ...[
        Container(
          color: C.surface,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text('${file ?? ''}  @@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@', style: const TextStyle(color: C.dim)),
        ),
        for (final l in h.lines)
          Container(
            color: _lineColor(l)?.withValues(alpha: .12),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(l, style: _monoStyle.copyWith(color: _lineColor(l))),
          ),
      ],
    ]);

/// A secondary-coloured row whose tap opens [body] under it; no [body], no tap.
class _Expandable extends StatefulWidget {
  const _Expandable({super.key, required this.title, this.body});

  final Widget title;
  final Widget? body;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final body = widget.body;
    return DefaultTextStyle.merge(
      style: _toolStyle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: body == null ? null : () => setState(() => open = !open),
            child: Row(
              children: [
                Text(open && body != null ? '▾ ' : '▸ '),
                Expanded(child: widget.title),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topLeft,
            child: open && body != null
                ? Padding(padding: const EdgeInsets.only(left: 14, top: 4), child: body)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
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
