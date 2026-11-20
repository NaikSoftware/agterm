import 'transcript.dart';

/// One list row: an item, a group of read-only tool items, or a day separator ([day] set).
class ChatRow {
  const ChatRow(this.key, {this.item, this.group = const [], this.day, this.interruptedAfter = false, this.summary});

  final String key;
  final ChatItem? item;
  final List<ChatItem> group;
  final DateTime? day;
  // an `interrupted` item follows this one: an open Agent call reads "stopped"
  final bool interruptedAfter;
  // the `compactSummary` folded under this `compact` divider
  final ChatItem? summary;
}

DateTime? _day(ChatItem i) {
  final t = i.time?.toLocal();
  return t == null ? null : DateTime(t.year, t.month, t.day);
}

String _dayKey(DateTime d) => 'day-${d.toIso8601String().substring(0, 10)}';

/// The rows for [items] (oldest first), newest first for a `reverse: true` list; a day row sits above each day's first item.
/// A `compactSummary` right after a `compact` folds into the divider's row, keyed by the divider.
/// Three or more consecutive read-only tool items share one row, keyed by the first so a poll that grows it keeps the key.
List<ChatRow> chatRows(List<ChatItem> items) {
  final rows = <ChatRow>[];
  final lastStop = items.lastIndexWhere((i) => i.kind == 'interrupted');
  var run = <ChatItem>[];
  void flush() {
    if (run.length >= 3) {
      rows.add(ChatRow('group-${run.first.uuid}', group: run));
    } else {
      rows.addAll([for (final i in run) ChatRow(i.uuid, item: i)]);
    }
    run = [];
  }

  DateTime? shown;
  for (final (n, i) in items.indexed) {
    final last = rows.lastOrNull?.item;
    if (i.kind == 'compactSummary' && run.isEmpty && last?.kind == 'compact' && rows.last.summary == null) {
      rows.last = ChatRow(last!.uuid, item: last, summary: i);
      continue;
    }
    final d = _day(i);
    if (d != null && d != shown) {
      flush();
      rows.add(ChatRow(_dayKey(d), day: d));
      shown = d;
    }
    if (i.kind == 'tool' && i.readOnly) {
      run.add(i);
      continue;
    }
    flush();
    rows.add(ChatRow(i.uuid, item: i, interruptedAfter: n < lastStop));
  }
  flush();
  return rows.reversed.toList();
}
