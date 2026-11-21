import '../model.dart';

enum ViewMode { chat, term }

/// The user's Chat/Term pick per Elis session; null is Auto. In memory only: it lasts while the phone app runs.
class ModePicks {
  static final Map<String, ViewMode> _picks = {};

  /// Sessions whose host answered `session.transcript` as too old, so Auto stops bouncing to Chat there.
  static final Set<String> tooOld = {};

  static ViewMode? of(String sessionId) => _picks[sessionId];

  static void pick(String sessionId, ViewMode? mode) =>
      mode == null ? _picks.remove(sessionId) : _picks[sessionId] = mode;
}

bool chatAvailable(Session s, String pane) =>
    s.liveAgent == 'claude' && s.agentSessionId.isNotEmpty && s.agentPane == pane && !ModePicks.tooOld.contains(s.id);

ViewMode shownMode(Session s, String pane) =>
    chatAvailable(s, pane) && ModePicks.of(s.id) != ViewMode.term ? ViewMode.chat : ViewMode.term;
