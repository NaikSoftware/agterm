import 'dart:convert';
import 'dart:math';

import 'grid.dart';
import 'prompt_dialog.dart';
import 'transcript.dart';

enum PromptKind { ask, permission, plan }

class PromptMatch {
  PromptMatch(this.call, this.kind, this.dialog, this.question);

  final PendingCall call;
  final PromptKind kind;
  final PromptDialog dialog;
  final int? question; // the shown question's index in input.questions; null on Review
}

PromptKind? promptKind(PendingCall c) => switch (c.name) {
  'AskUserQuestion' => PromptKind.ask,
  'ExitPlanMode' => PromptKind.plan,
  'Bash' || 'Write' || 'Edit' || 'WebFetch' => PromptKind.permission,
  final n when n.startsWith('mcp__') => PromptKind.permission,
  _ => null,
};

bool anchored(PromptDialog d, PendingCall c) => _anchor(d, c) != null;

/// Null when no pending call anchors to [d], or two or more do: the panel sheet shows then.
PromptMatch? matchPrompt(PromptDialog? d, List<PendingCall> pending) {
  if (d == null) return null;
  final hits = [
    for (final c in pending)
      if (_anchor(d, c) case final a?) PromptMatch(c, promptKind(c)!, d, a.question),
  ];
  return hits.length == 1 ? hits.single : null;
}

String _base(String path) => path.split('/').last;

bool _has(String hay, String needle) => needle.isNotEmpty && hay.contains(needle);

({int? question})? _anchor(PromptDialog d, PendingCall c) {
  final kind = promptKind(c), input = c.input;
  if (kind == null || input == null || c.clipped || !_source(d, c)) return null;
  String str(String k) => input[k] is String ? input[k] as String : '';
  if (kind == PromptKind.ask) return _ask(d, input);
  final ok = switch (c.name) {
    'Bash' => str('command').trim().isNotEmpty && norm(d.boxed) == norm(str('command')),
    'Write' || 'Edit' => _path(d, str('file_path')),
    'WebFetch' => _url(d, str('url')),
    'ExitPlanMode' => _plan(d, input),
    _ => input.isNotEmpty && input.values.every((v) => _has(norm(d.body), norm(v is String ? v : jsonEncode(v)))),
  };
  return ok ? (question: null) : null;
}

// "· from the" is an expected-state check; X is the model-chosen agent type or name.
bool _source(PromptDialog d, PendingCall c) {
  final h = norm(d.header);
  if (c.source == 'main') return !h.contains('·fromthe');
  // shortcut: a header X that only starts with the type or name anchors too (the 45-column header interleaves the
  // title's second word before "agent"), upgrade by reading X from the header's rows
  return [c.agentType, c.agentName].any((x) {
    final from = '·fromthe${norm(x ?? '')}', at = h.indexOf(from);
    return norm(x ?? '').isNotEmpty && at >= 0 && h.indexOf('agent', at + from.length) >= 0;
  });
}

({int? question})? _ask(PromptDialog d, Map<String, dynamic> input) {
  final qs = [
    for (final q in input['questions'] is List ? input['questions'] as List : const [])
      if (q is Map) q,
  ];
  String text(Map q, String k) => q[k] is String ? q[k] as String : '';
  bool header(Map q) => text(q, 'header').length > 10 || _has(norm(d.header), norm(text(q, 'header')));
  if (qs.isEmpty) return null;
  if (d.review) {
    final shown = d.reviewQuestions;
    final same =
        shown.length == qs.length &&
        [for (var i = 0; i < qs.length; i++) norm(shown[i]) == norm(text(qs[i], 'question')) && header(qs[i])]
            .every((b) => b);
    return same ? (question: null) : null;
  }
  final labels = [
    for (final o in d.options)
      if (o.number != null) norm(o.label),
  ];
  for (var i = 0; i < qs.length; i++) {
    final q = qs[i],
        options = [
          for (final o in q['options'] is List ? q['options'] as List : const [])
            if (o is Map) o,
        ];
    if (norm(d.question) != norm(text(q, 'question')) || norm(d.question).isEmpty || !header(q)) continue;
    if (options.isEmpty || labels.length < options.length) continue;
    final inOrder = [for (var k = 0; k < options.length; k++) labels[k] == norm(text(options[k], 'label'))];
    if (inOrder.every((b) => b)) return (question: i);
  }
  return null;
}

// The header shows the path cut after "…" or relative to the cwd ("../"); whatever is left must end file_path.
bool _path(PromptDialog d, String filePath) {
  final h = norm(d.header), p = norm(filePath), base = norm(_base(filePath));
  if (base.isEmpty || !_has(norm(d.question), base)) return false;
  final dots = h.lastIndexOf('../'), cut = max(h.lastIndexOf('…') + 1, dots < 0 ? 0 : dots + 3);
  if (cut == 0) return h.endsWith(base);
  final tail = h.substring(cut);
  return tail.length >= base.length && p.endsWith(tail);
}

// boxed joins "url: <url>" and "prompt: <prompt>" with no separator, so the URL must end where "prompt:" starts.
bool _url(PromptDialog d, String url) {
  final u = norm(url).replaceFirst(RegExp(r'/$'), '');
  return u.isNotEmpty && RegExp('url:${RegExp.escape(u)}/?prompt:').hasMatch(norm(d.boxed));
}

bool _plan(PromptDialog d, Map<String, dynamic> input) {
  final file = input['planFilePath'], plan = input['plan'];
  if (file is String && file.isNotEmpty) return _has(norm(d.footer), norm(_base(file)));
  final heading = plan is String ? RegExp(r'^#+\s*(.*)$', multiLine: true).firstMatch(plan)?.group(1) ?? '' : '';
  return _has(norm(d.body), norm(heading));
}
