// Reading an agent's question off its screen text, so the phone can offer the answers as buttons.

class PromptOption {
  const PromptOption(this.key, this.label);
  final String key, label; // key: what to type
  @override
  bool operator ==(Object other) => other is PromptOption && other.key == key && other.label == label;
  @override
  int get hashCode => Object.hash(key, label);
}

final _frame = RegExp(r'^[\s│┃|╭╮╰╯─━]+|[\s│┃|╭╮╰╯─━]+$');
final _numbered = RegExp(r'^(?:[❯›>▶●]\s*)?(\d)[.)]\s+(.+)$');
final _yesNo = RegExp(r'\[(?:y/N|Y/n|y/n)\]|\((?:y/n|Y/n|y/N)\)');

String _clean(String line) => line.replaceAll(_frame, '');

/// Numbered choices ("❯ 1. Yes", "2. No") in the last rows of the screen, as Claude Code, Codex and most TUIs print
/// them; else y/n when the screen ends in a [y/N] question. The numbers must run 1, 2, 3… to count.
List<PromptOption> promptOptions(String screen) {
  final lines = screen.split('\n').reversed.take(16).toList().reversed.map(_clean).toList();
  final found = <PromptOption>[];
  for (final l in lines) {
    final m = _numbered.firstMatch(l);
    if (m == null) continue;
    final key = m.group(1)!;
    if (key == '1') found.clear(); // a later list replaces an earlier one
    if (key != '${found.length + 1}') continue;
    final label = m.group(2)!.trim();
    found.add(PromptOption(key, label.length > 24 ? '${label.substring(0, 23)}…' : label));
  }
  if (found.length >= 2) return found;
  final tail = lines.where((l) => l.trim().isNotEmpty).toList();
  if (tail.isNotEmpty && _yesNo.hasMatch(tail.last)) return const [PromptOption('y', 'Yes'), PromptOption('n', 'No')];
  return const [];
}

/// The last few non-blank rows, without box borders, for a glance at what the agent asks.
String promptTail(String screen, {int rows = 6}) {
  final lines = screen.split('\n').map(_clean).where((l) => l.trim().isNotEmpty && !RegExp(r'^[─━\s]+$').hasMatch(l)).toList();
  return lines.skip(lines.length > rows ? lines.length - rows : 0).join('\n');
}
