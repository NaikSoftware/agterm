import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'card_checks.dart';
import 'chat_view.dart';
import 'checks.dart';
import 'claude_screen.dart';
import 'feed.dart';
import 'grid.dart';
import 'prompt_cards.dart';
import 'prompt_dialog.dart';
import 'prompt_match.dart';

/// Every card shown, per call id, after its dialog is gone: answered from the phone, stopped, or closed on the computer.
class PromptLedger extends ChangeNotifier {
  PromptLedger({required this.grids, required this.grid, required this.feed, required this.blocked}) : _switches = feed.switches {
    grids.addListener(_onGrid);
    feed.addListener(_onFeed);
  }

  static const closedText = 'Closed on the computer';

  final Listenable grids;
  final Grid? Function() grid;
  final TranscriptFeed feed;
  final String? Function() blocked; // exited or stale: every mark clears

  final _shown = <String>{}, _answered = <String>{}, _stopped = <String>{}, _marked = <String>{};
  final _off = <String, int>{}; // consecutive grids whose dialog is not this call's
  int _switches;

  /// Called from build: never notifies.
  void shown(String id) {
    if (_shown.add(id)) HapticFeedback.heavyImpact();
  }

  void answered(String id) {
    _answered.add(id);
    if (_marked.remove(id)) notifyListeners();
  }

  void stopped(String id) {
    if (_stopped.add(id)) notifyListeners();
  }

  bool suppressed(String id) => _stopped.contains(id);

  String? mark(String toolId) => blocked() == null && _marked.contains(toolId) ? closedText : null;

  void _onGrid() {
    final g = grid();
    if (g == null || g.blank) return; // a Resync replaying, or nothing drawn yet
    final before = _state;
    if (blocked() != null) {
      _marked.clear();
      _off.clear();
    } else {
      if (ClaudeScreen.read(g).bottomStack) _stopped.clear();
      final d = PromptDialog.read(g);
      for (final c in feed.pending) {
        if (!_shown.contains(c.id)) continue;
        if (d != null && anchored(d, c)) {
          _off.remove(c.id);
          _marked.remove(c.id);
        } else if ((_off[c.id] = (_off[c.id] ?? 0) + 1) >= 2 && !_answered.contains(c.id)) {
          _marked.add(c.id);
        }
      }
    }
    if (before != _state) notifyListeners();
  }

  String get _state => '${_marked.toList()..sort()}|${_stopped.toList()..sort()}';

  void _onFeed() {
    final before = _state;
    if (feed.switches != _switches) {
      _switches = feed.switches;
      for (final s in [_shown, _answered, _stopped, _marked]) {
        s.clear();
      }
      _off.clear();
    } else {
      final open = {for (final c in feed.pending) c.id};
      for (final s in [_shown, _answered, _stopped, _marked]) {
        s.retainWhere(open.contains);
      }
      _off.removeWhere((id, _) => !open.contains(id));
    }
    if (blocked() != null) _marked.clear();
    if (before != _state) notifyListeners();
  }

  @override
  void dispose() {
    grids.removeListener(_onGrid);
    feed.removeListener(_onFeed);
    super.dispose();
  }
}

const _proven = checks; // the parameter below shadows the global

/// Docks the card for the dialog matched to one pending call; null opens the panel sheet.
PromptCardBuilder promptCardBuilder(PromptLedger ledger, {Checks checks = _proven, CardChecks cards = cardChecks}) => (context, c) {
  // without SGR the current tab and dim text cannot be told apart
  if (!c.grid.colours) return null;
  final m = matchPrompt(PromptDialog.read(c.grid), c.pending);
  if (m == null) return null;
  final id = m.call.id;
  if (ledger.suppressed(id)) return null;
  ledger.shown(id);
  void done() => ledger.answered(id);
  void stop() => ledger.stopped(id);
  final key = ValueKey(id);
  return switch (m.kind) {
    PromptKind.ask => AskCard(key: key, c: c, m: m, onDone: done, onStop: stop, checks: checks, cards: cards),
    PromptKind.permission => PermissionCard(key: key, c: c, m: m, onDone: done, onStop: stop, checks: checks, cards: cards),
    PromptKind.plan => PlanCard(key: key, c: c, m: m, onDone: done, onStop: stop, checks: checks, cards: cards),
  };
};
