import 'transcript.dart';

/// One list row: an item, a group of items, or a day separator ([day] set).
class ChatRow {
  const ChatRow(this.key, {this.item, this.group = const [], this.day});

  final String key;
  final ChatItem? item;
  final List<ChatItem> group;
  final DateTime? day;
}

DateTime? _day(ChatItem i) {
  final t = i.time?.toLocal();
  return t == null ? null : DateTime(t.year, t.month, t.day);
}

String _dayKey(DateTime d) => 'day-${d.toIso8601String().substring(0, 10)}';

/// The rows for [items] (oldest first), newest first for a `reverse: true` list; a day row sits above each day's first item.
List<ChatRow> chatRows(List<ChatItem> items) {
  final rows = <ChatRow>[];
  DateTime? shown;
  for (final i in items) {
    final d = _day(i);
    if (d != null && d != shown) {
      rows.add(ChatRow(_dayKey(d), day: d));
      shown = d;
    }
    rows.add(ChatRow(i.uuid, item: i));
  }
  return rows.reversed.toList();
}
