import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../terminal/key_bar.dart';
import '../terminal/term_session.dart';
import '../terminal/vt.dart';
import 'checks.dart';
import 'grid.dart';

const escapeGap = Duration(milliseconds: 100); // Ink reads Esc + key within ~60 ms as Alt+key (check 1)

sealed class GateWrite {}

class KeyWrite extends GateWrite {
  KeyWrite(this.key, [this.mods = 0]);
  final VtKey key;
  final int mods;
}

class TextWrite extends GateWrite {
  TextWrite(this.text);
  final String text;
}

class PasteWrite extends GateWrite {
  PasteWrite(this.text);
  final String text;
}

class GateStep {
  const GateStep(this.write, {required this.ready, required this.done, this.why});
  final GateWrite write;
  final String? why; // the stop reason when `ready` fails
  final bool Function(Grid g) ready; // the state the write expects, checked right before it
  final bool Function(Grid g) done; // the change that ends the step
}

enum GateOutcome { done, mismatch, timeout, writeFailed, noLead, blocked, busy }

class GateResult {
  const GateResult(this.outcome, this.step, this.total, this.reason);
  final GateOutcome outcome;
  final int step, total;
  final String reason; // '' only when done
  bool get ok => outcome == GateOutcome.done;
}

/// Ends a [WriteGate.run] body early; [WriteGate.run] turns it into its [GateResult].
class GateStop implements Exception {
  const GateStop(this.outcome, this.reason);
  final GateOutcome outcome;
  final String reason;
}

abstract class GateWriter {
  Future<bool> lead(); // true once writes reach the program at once (Live: claimed and leading)
  Future<bool> write(GateWrite w); // one write; false when refused
  bool pasteSafe(String text); // a newline in this paste cannot submit
}

bool _multiline(String text) => text.contains('\n') || text.contains('\r');

/// Writes through a Live pane's claim channel, only while leading, so nothing queues in [TermSession] unchecked.
class LeadWriter implements GateWriter {
  LeadWriter(this._term, this._claim);
  final TermSession? Function() _term;
  final Future<bool> Function() _claim;

  @override
  Future<bool> lead() async {
    final t = _term();
    if (t == null) return false;
    final deadline = Completer<void>();
    final timer = Timer(const Duration(seconds: 10), deadline.complete);
    try {
      bool shown() => !t.replaying && t.snapshot != null; // OPENED, past any Resync: the claim's grid is the program's
      if (!await _until(t, shown, deadline.future)) return false;
      if (!t.leading && !t.pending && !await Future.any([_claim(), deadline.future.then((_) => false)])) return false;
      return await _until(t, () => t.leading && shown(), deadline.future);
    } finally {
      timer.cancel();
    }
  }

  static Future<bool> _until(TermSession t, bool Function() ok, Future<void> deadline) async {
    if (t.ended != null) return false;
    if (ok()) return true;
    final c = Completer<bool>();
    void on() {
      if (c.isCompleted) return;
      if (t.ended != null) return c.complete(false);
      if (ok()) c.complete(true);
    }

    t.addListener(on);
    unawaited(deadline.then((_) => c.isCompleted ? null : c.complete(false)));
    try {
      return await c.future;
    } finally {
      t.removeListener(on);
    }
  }

  @override
  Future<bool> write(GateWrite w) async {
    final t = _term();
    if (t == null || !t.leading) return false;
    return switch (w) {
      KeyWrite(:final key, :final mods) => t.key(key, mods: mods, seq: ''), // never queued: no indirect form needed
      TextWrite(:final text) => t.text(text),
      PasteWrite(:final text) => t.paste(text),
    };
  }

  @override
  bool pasteSafe(String text) => !_multiline(text) || (_term()?.bracketedPaste ?? false);
}

/// Writes through `session.type`: keys as xterm sends them, a paste as plain text, so a newline in it submits.
class TypeWriter implements GateWriter {
  TypeWriter(this._type);
  final Future<String?> Function(String text) _type;

  @override
  Future<bool> lead() async => true;

  @override
  Future<bool> write(GateWrite w) async {
    final String text;
    try {
      text = switch (w) {
        KeyWrite(:final key, :final mods) => xtermSeq(key, mods),
        TextWrite(:final text) || PasteWrite(:final text) => text,
      };
    } on StateError {
      return false; // a key with no xterm form
    }
    return await _type(text) == null;
  }

  @override
  bool pasteSafe(String text) => !_multiline(text);
}

class GateSequence {
  GateSequence._(this._gate);
  final WriteGate _gate;

  Grid get grid => _gate._grid() ?? Grid(const []);

  Future<void> send(GateStep step) => _gate._send(step);

  /// Grows the total for a loop of unknown length.
  void addSteps(int n) => _gate._grow(n);
}

/// The one path every Chat write takes: lead, the expected screen, one write, the screen's answer.
class WriteGate extends ChangeNotifier {
  WriteGate({required this._grids, required this._grid, required this._writer, required this._remote, required this._blocked,
      this._checks = checks});

  final Listenable _grids;
  final Grid? Function() _grid;
  final GateWriter Function() _writer;
  final bool Function() _remote;
  final String? Function() _blocked;
  final Checks _checks;
  bool _running = false;
  int _step = 0, _total = 0;
  Future<void>? _escape; // completes escapeGap after the last Esc went out, across runs

  bool get running => _running;
  int get step => _step;
  int get total => _total;
  String get progress => 'Sending $_step/$_total';

  Future<GateResult> run(int total, Future<void> Function(GateSequence s) body) async {
    if (_running) return _stop(GateResult(GateOutcome.busy, 0, total, 'Another answer is being sent'));
    if (_blocked() case final why?) return _stop(GateResult(GateOutcome.blocked, 0, total, why));
    _running = true;
    _step = 0;
    _total = total;
    notifyListeners();
    GateResult result;
    try {
      await body(GateSequence._(this));
      result = GateResult(GateOutcome.done, _step, _total, '');
    } on GateStop catch (e) {
      result = GateResult(e.outcome, _step, _total, e.reason);
    } finally {
      _running = false;
      notifyListeners();
    }
    if (!result.ok) return _stop(result);
    unawaited(HapticFeedback.lightImpact());
    return result;
  }

  void _grow(int n) {
    _total += n;
    notifyListeners();
  }

  GateResult _stop(GateResult r) {
    unawaited(HapticFeedback.vibrate());
    return r;
  }

  Future<void> _send(GateStep step) async {
    _step++;
    notifyListeners();
    final writer = _writer();
    if (!await writer.lead()) throw const GateStop(GateOutcome.noLead, 'Could not take over the session');
    if (_escape case final gap?) await gap;
    final before = _grid();
    if (before == null || !step.ready(before)) {
      throw GateStop(GateOutcome.mismatch, step.why ?? "Claude's screen is not as expected");
    }
    final w = step.write;
    if (w is PasteWrite && !writer.pasteSafe(w.text)) throw const GateStop(GateOutcome.mismatch, 'Claude is not accepting pastes');

    final answered = Completer<bool>();
    var wrote = false, changed = false;
    Timer? limit, cap;
    void check() {
      final g = _grid();
      if (!answered.isCompleted && g != null && step.done(g)) answered.complete(true);
    }

    void timeout() {
      if (!answered.isCompleted) answered.complete(false);
    }

    void onGrid() {
      if (!wrote) {
        changed = true; // during the write: checked once it returns
        return;
      }
      if (_remote() && limit == null) limit = Timer(_checks.timeout, timeout);
      check();
    }

    _grids.addListener(onGrid);
    try {
      if (w is KeyWrite && w.key == VtKey.escape) _escape = Future<void>.delayed(escapeGap);
      if (!await writer.write(w)) throw const GateStop(GateOutcome.writeFailed, 'The key did not reach the computer');
      wrote = true;
      if (_remote()) {
        cap = Timer(const Duration(seconds: 5), timeout); // a remote grid lags the write by the round-trip
        if (changed) onGrid();
      } else {
        limit = Timer(_checks.timeout, timeout);
        if (changed) check();
      }
      if (!await answered.future) throw const GateStop(GateOutcome.timeout, "Claude's screen did not change");
    } finally {
      _grids.removeListener(onGrid);
      limit?.cancel();
      cap?.cancel();
    }
  }
}
