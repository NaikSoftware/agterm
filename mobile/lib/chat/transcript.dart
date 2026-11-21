// Decoding a `session.transcript` reply (plan A's contract). A wrongly typed field reads as absent, never throws.

String? _str(Map m, String k) => m[k] is String ? m[k] as String : null;

// `start`, `next`, `size` and `at` may arrive as decimal strings.
int? _int(Map m, String k) => switch (m[k]) {
      final int v => v,
      final String v => int.tryParse(v),
      _ => null,
    };

bool _bool(Map m, String k) => m[k] == true;

Map<String, dynamic>? _map(Map m, String k) => m[k] is Map ? Map<String, dynamic>.from(m[k] as Map) : null;

List<Map<String, dynamic>> _maps(Map m, String k) =>
    [for (final e in m[k] is List ? m[k] as List : const []) if (e is Map) Map<String, dynamic>.from(e)];

class TranscriptPage {
  TranscriptPage.fromJson(Map<String, dynamic> r)
      : transcript = _str(r, 'transcript') ?? '',
        size = _int(r, 'size') ?? 0,
        start = _int(r, 'start') ?? 0,
        next = _int(r, 'next') ?? 0,
        reset = _bool(r, 'reset'),
        skipped = _int(r, 'skipped') ?? 0,
        items = [for (final m in _maps(r, 'items')) ChatItem.fromJson(m)],
        pending = [for (final m in _maps(r, 'pending')) PendingCall.fromJson(m)],
        meta = _map(r, 'meta') == null ? null : TranscriptMeta.fromJson(_map(r, 'meta')!),
        commands = r['commands'] is List ? [for (final m in _maps(r, 'commands')) SlashCommand.fromJson(m)] : null;

  final String transcript;
  final int size, start, next, skipped;
  final bool reset;
  final List<ChatItem> items;
  final List<PendingCall> pending;
  final TranscriptMeta? meta;
  final List<SlashCommand>? commands;
}

class ChatItem {
  ChatItem.fromJson(Map<String, dynamic> m)
      : raw = m,
        kind = _str(m, 'kind') ?? '',
        uuid = _str(m, 'uuid') ?? '',
        at = _int(m, 'at') ?? 0,
        time = DateTime.tryParse(_str(m, 'time') ?? '');

  final Map<String, dynamic> raw;
  final String kind, uuid;
  final int at;
  final DateTime? time;

  String? get id => _str(raw, 'id');
  String? get text => _str(raw, 'text');
  String? get name => _str(raw, 'name');
  String? get arg => _str(raw, 'arg');
  String? get mark => _str(raw, 'mark');
  String? get output => _str(raw, 'output');
  List<Hunk>? get patch => raw['patch'] is List ? [for (final h in _maps(raw, 'patch')) Hunk.fromJson(h)] : null;
  String? get file => _str(raw, 'file');
  bool get isError => _bool(raw, 'isError');
  bool get rejected => _bool(raw, 'rejected');
  int? get exitCode => _int(raw, 'exitCode');
  bool get clipped => _bool(raw, 'clipped');
  bool get running => _bool(raw, 'running');
  bool get isAgent => name == 'Agent' || name == 'Task';
  String? get agentType => _str(raw, 'agentType');
  String? get agentName => _str(raw, 'agentName');
  String? get agentColor => _str(raw, 'agentColor');
  String? get message => _str(raw, 'message');
  int? get durationMs => _int(raw, 'durationMs');
  int? get bytes => _int(raw, 'bytes');

  bool get isHumanPrompt =>
      const {'typed', 'queued', 'suggestion_accepted'}.contains(_str(raw, 'promptSource')) || _str(raw, 'origin') == 'human';
}

class Hunk {
  Hunk.fromJson(Map<String, dynamic> m)
      : oldStart = _int(m, 'oldStart') ?? 0,
        oldLines = _int(m, 'oldLines') ?? 0,
        newStart = _int(m, 'newStart') ?? 0,
        newLines = _int(m, 'newLines') ?? 0,
        lines = [for (final l in m['lines'] is List ? m['lines'] as List : const []) if (l is String) l];

  final int oldStart, oldLines, newStart, newLines;
  final List<String> lines;
}

class PendingCall {
  PendingCall(this.id, this.uuid, this.source, this.name, this.input, this.clipped, {this.agentType, this.agentName});

  PendingCall.fromJson(Map<String, dynamic> m)
      : this(_str(m, 'id') ?? '', _str(m, 'uuid') ?? '', _str(m, 'source') ?? 'main', _str(m, 'name') ?? '', _map(m, 'input'),
            _bool(m, 'clipped'),
            agentType: _str(m, 'agentType'), agentName: _str(m, 'agentName'));

  final String id, uuid, source, name;
  final Map<String, dynamic>? input;
  final bool clipped;
  final String? agentType, agentName;
}

class PrRef {
  PrRef.fromJson(Map<String, dynamic> m)
      : prNumber = _int(m, 'prNumber'),
        prRepository = _str(m, 'prRepository'),
        prUrl = _str(m, 'prUrl');

  final int? prNumber;
  final String? prRepository, prUrl;
}

class Todo {
  Todo.fromJson(Map<String, dynamic> m)
      : content = _str(m, 'content') ?? '',
        status = _str(m, 'status') ?? '',
        activeForm = _str(m, 'activeForm');

  final String content, status;
  final String? activeForm;
}

class TranscriptMeta {
  TranscriptMeta.fromJson(Map<String, dynamic> m)
      : title = _str(m, 'title'),
        lastPrompt = _str(m, 'lastPrompt'),
        permissionMode = _str(m, 'permissionMode'),
        pr = _map(m, 'pr') == null ? null : PrRef.fromJson(_map(m, 'pr')!),
        agentName = _str(m, 'agentName'),
        model = _str(m, 'model'),
        effort = _str(m, 'effort'),
        todos = [for (final t in _maps(m, 'todos')) Todo.fromJson(t)],
        queued = [for (final q in m['queued'] is List ? m['queued'] as List : const []) if (q is String) q],
        continuedIn = _str(m, 'continuedIn'),
        skillsAt = _int(m, 'skillsAt');

  final String? title, lastPrompt, permissionMode, agentName, model, effort, continuedIn;
  final PrRef? pr;
  final List<Todo> todos;
  final List<String> queued;
  final int? skillsAt;
}

class SlashCommand {
  SlashCommand(this.name, this.description, this.skill, this.panel);

  SlashCommand.fromJson(Map<String, dynamic> m)
      : this(_str(m, 'name') ?? '', _str(m, 'description') ?? '', _str(m, 'source') == 'skill', _bool(m, 'panel'));

  final String name, description;
  final bool skill, panel;
}

enum TranscriptError {
  hostTooOld,
  noAdapter,
  notFound,
  other;

  static TranscriptError of(String message) {
    final m = message.trim();
    if (m.startsWith('unknown command') || m.contains('too old') ||
        (m.startsWith('invalid request:') && m.contains('session.transcript'))) {
      return hostTooOld;
    }
    if (m.contains('no adapter')) return noAdapter;
    if (m.contains('transcript not found')) return notFound;
    return other;
  }
}
