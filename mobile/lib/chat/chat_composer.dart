import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/composer.dart';
import '../terminal/vt.dart';
import '../theme.dart';
import 'checks.dart';
import 'claude_screen.dart';
import 'feed.dart';
import 'grid.dart';
import 'transcript.dart';
import 'write_gate.dart';

const _checks = checks; // the field below shadows the constant in its own default
const _instant = {'model', 'effort', 'fast', 'status', 'tasks', 'usage'}; // run at once, never queued
const _changed = "Claude's input changed on the computer";

/// [all] matching [typed] (with or without its `/`): prefix matches first, then substring ones, ignoring case.
List<SlashCommand> slashMatches(List<SlashCommand> all, String typed) {
  final t = (typed.startsWith('/') ? typed.substring(1) : typed).toLowerCase();
  bool prefix(SlashCommand c) => c.name.toLowerCase().startsWith(t);
  return [...all.where(prefix), ...all.where((c) => !prefix(c) && c.name.toLowerCase().contains(t))];
}

/// Claude's draft shows [text]: its first 40 characters, whitespace ignored, or a paste placeholder.
bool pasteShown(ClaudeScreen s, String text) {
  final k = norm(text);
  return s.pastePlaceholder || norm(s.draft).contains(k.substring(0, min(40, k.length)));
}

// the input block's rows as drawn: a Ctrl+U that only removes a newline changes no trimmed text
String _inputRows(Grid g) => switch (ClaudeScreen.read(g).inputRows) {
      (final a, final b) => [for (var r = a; r < b; r++) g.text(r)].join('\n'),
      null => '',
    };

/// Chat's composer: adopts Claude's draft, sends through [gate], and offers the "/" menu.
class ChatComposer extends StatefulWidget {
  const ChatComposer(
      {super.key,
      required this.feed,
      required this.screen,
      required this.colours,
      required this.remote,
      this.server = false,
      required this.gate,
      this.disabledBy,
      this.held,
      this.onOpen,
      this.onSending,
      this.checks = _checks});

  final TranscriptFeed feed;
  final ClaudeScreen? Function() screen;
  final bool colours; // a Live pane's grid: dim text tells a placeholder from a draft
  final bool remote, server;
  final WriteGate gate;
  final String? disabledBy;
  final String? held; // a prompt or panel owns Claude's input: the composer is disabled with this line
  final VoidCallback? onOpen; // shows the hidden panel again
  final VoidCallback? onSending; // a send the gate takes
  final Checks checks;

  @override
  State<ChatComposer> createState() => ChatComposerState();
}

class ChatComposerState extends State<ChatComposer> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _menuPortal = OverlayPortalController(), _menuLink = LayerLink(), _box = GlobalKey();
  String? _adopted; // the draft taken from Claude's row, which Send clears there first
  bool _seen = false, _sending = false, _running = false, _stopRun = false, _readopt = false;
  String? _offer, _offerDraft; // the text a changed row stopped, and that row

  @override
  void initState() {
    super.initState();
    widget.gate.addListener(_onGate);
    _menuPortal.show(); // the menu's own builder is empty without a match
    _adopt();
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gate != widget.gate) {
      oldWidget.gate.removeListener(_onGate);
      widget.gate.addListener(_onGate);
    }
    _adopt();
    if (_offer != null && (widget.disabledBy != null || norm(widget.screen()?.draft ?? '') != _offerDraft)) _offer = null;
  }

  @override
  void dispose() {
    widget.gate.removeListener(_onGate);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  // another run started while Claude works is a Stop or Cancel: an Esc before any output puts the prompt back (check 13)
  void _onGate() {
    final running = widget.gate.running;
    if (running == _running) return;
    _running = running;
    if (running) {
      _stopRun = !_sending && (widget.screen()?.busy ?? false);
    } else if (_stopRun) {
      _stopRun = false;
      _readopt = true;
      _adopt();
    }
  }

  void _adopt() {
    final s = widget.colours ? widget.screen() : null;
    if (s == null || !s.bottomStack) return;
    final now = !_seen || (_readopt && !s.busy);
    _seen = true;
    if (!now) return;
    _readopt = false;
    if (_field.text.isNotEmpty || s.pastePlaceholder || s.draft.isEmpty) return;
    _field.text = _adopted = s.draft;
  }

  /// Puts [text] in the field, the cursor at its end.
  void insert(String text) {
    _field.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  String? _blocked(ClaudeScreen? s) =>
      widget.disabledBy ??
      widget.checks.writeBlockedOn(remote: widget.remote, server: widget.server) ??
      (s != null && s.dialog
          ? 'Claude shows a dialog'
          : s == null || !s.bottomStack
              ? "Waiting for Claude's screen"
              // a polled colourless grid can miss a dialog raised since: its typed digit or Enter would answer it
              : !widget.colours && s.busy
                  ? 'Claude is working: this pane sends only while Claude is idle'
                  : null);

  /// Sends [text] to Claude through the gate; the field clears when it held [text].
  Future<void> send(String text, {bool replace = false}) async {
    text = text.trimRight();
    if (text.isEmpty) return;
    if (_blocked(widget.screen()) case final why?) return _tell(why);
    widget.onSending?.call();
    setState(() {
      _sending = true;
      _offer = null;
    });
    final r = await widget.gate.run(2, (q) => widget.colours ? _live(q, text, replace) : _typed(q, text));
    if (!mounted) return;
    final draft = norm(widget.screen()?.draft ?? '');
    final offer = r.reason == _changed && draft.isNotEmpty;
    setState(() {
      _sending = false;
      if (r.ok && _field.text.trimRight() == text) _field.clear();
      if (offer) {
        _offer = text;
        _offerDraft = draft;
      }
    });
    if (!r.ok && !offer) _tell(r.reason);
  }

  void _tell(String why) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(why)));

  Future<void> _live(GateSequence q, String text, bool replace) async {
    final draft = ClaudeScreen.read(q.grid).draft;
    if (draft.isNotEmpty) {
      if (!replace && norm(draft) != norm(_adopted ?? '')) throw const GateStop(GateOutcome.mismatch, _changed);
      await _clear(q);
    }
    final c = widget.checks;
    final bang = !c.pastedBangSwitches && text.length > 1 && (text.startsWith('!') || text.startsWith('#'));
    var shown = text;
    if (!c.pastedCommandRuns && text.startsWith('/')) {
      if (text.contains('\n')) throw const GateStop(GateOutcome.mismatch, 'A command is one line');
      await q.send(_write(TextWrite(text), text));
    } else if (bang) {
      q.addSteps(1);
      String? before;
      await q.send(GateStep(TextWrite(text[0]), ready: (g) {
        before = _inputRows(g);
        return _empty(ClaudeScreen.read(g));
      }, done: (g) => _inputRows(g) != before));
      shown = text.substring(1);
      await q.send(GateStep(PasteWrite(shown), ready: (g) => ClaudeScreen.read(g).bottomStack, done: (g) => pasteShown(ClaudeScreen.read(g), shown)));
    } else {
      await q.send(_write(PasteWrite(text), text));
    }
    bool human(ChatItem i) => i.kind == 'user' && i.isHumanPrompt;
    final humans = widget.feed.items.where(human).length;
    await q.send(GateStep(KeyWrite(VtKey.enter), ready: (g) {
      final s = ClaudeScreen.read(g);
      return s.bottomStack && pasteShown(s, shown);
    }, done: (g) {
      final s = ClaudeScreen.read(g);
      // a panel command leaves the bottom stack
      return s.dialog || s.busy || (s.bottomStack && s.draft.isEmpty && !s.pastePlaceholder) || widget.feed.items.where(human).length > humans;
    }));
    _adopted = null;
  }

  static bool _empty(ClaudeScreen s) => s.bottomStack && s.draft.isEmpty && !s.pastePlaceholder;

  GateStep _write(GateWrite w, String text) =>
      GateStep(w, ready: (g) => _empty(ClaudeScreen.read(g)), done: (g) => pasteShown(ClaudeScreen.read(g), text));

  // check 5: one press per visual row plus one per newline, so it repeats until the row reads empty
  Future<void> _clear(GateSequence q) async {
    final key = widget.checks.clearInput;
    if (key == null) throw const GateStop(GateOutcome.mismatch, "Claude's input is not empty");
    for (var n = 0; ClaudeScreen.read(q.grid).draft.isNotEmpty; n++) {
      if (n == 40) throw const GateStop(GateOutcome.mismatch, "Claude's input did not clear");
      q.addSteps(1);
      String? before;
      await q.send(GateStep(KeyWrite(key.$1, key.$2), ready: (g) {
        before = _inputRows(g);
        final s = ClaudeScreen.read(g);
        return s.bottomStack && s.draft.isNotEmpty;
      }, done: (g) => _inputRows(g) != before));
    }
    _adopted = null;
  }

  // a `session.text` grid has no SGR: a placeholder reads as text, so no draft check and no clear
  Future<void> _typed(GateSequence q, String text) async {
    String? before;
    String all(Grid g) => [for (var r = 0; r < g.rows.length; r++) g.text(r)].join('\n');
    bool ready(Grid g) {
      before = all(g);
      return ClaudeScreen.read(g).bottomStack;
    }

    await q.send(GateStep(PasteWrite(text), ready: ready, done: (g) => all(g) != before));
    await q.send(GateStep(KeyWrite(VtKey.enter), ready: ready, done: (g) => all(g) != before));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([_field, widget.gate, widget.feed]),
        builder: (context, _) {
          final s = widget.screen();
          final text = _field.text;
          final blocked = _blocked(s);
          final command = RegExp(r'^/(\S+)').firstMatch(text.trim())?.group(1);
          final queue = (s?.busy ?? false) && !_instant.contains(command);
          final menu = text.startsWith('/') && !text.contains(RegExp(r'\s')) ? slashMatches(widget.feed.commands, text) : const <SlashCommand>[];
          final held = widget.held;
          final reason = _sending && widget.gate.running
              ? widget.gate.progress
              : text.trim().isNotEmpty && _offer == null && held == null
                  ? blocked
                  : null;
          final canSend = text.trim().isNotEmpty && blocked == null && !widget.gate.running;
          // the menu floats above the composer, over the list, so the bottom area's scroll never clips its first rows
          return OverlayPortal(
            controller: _menuPortal,
            overlayChildBuilder: (_) => _menu(menu),
            child: CompositedTransformTarget(
              key: _box,
              link: _menuLink,
              child: Composer(
                  controller: _field,
                  focus: _focus,
                  onSend: canSend ? () => send(_field.text) : null,
                  maxLines: 6,
                  autocorrect: true,
                  mono: false,
                  sendLabel: queue ? 'Queue' : 'Send',
                  sendIcon: queue ? Icons.schedule : Icons.arrow_forward,
                  reason: reason,
                  enabled: held == null,
                  accessory: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ModeChip(
                        screen: s,
                        meta: widget.feed.meta,
                        gate: widget.gate,
                        remote: widget.remote,
                        server: widget.server,
                        disabledBy: widget.disabledBy,
                        checks: widget.checks),
                    if (_offer != null) _offerRow(),
                    if (held != null)
                      Row(key: const Key('composerHeld'), children: [
                        Flexible(child: Text(held, style: const TextStyle(fontSize: 12, color: C.muted))),
                        if (widget.onOpen != null) ...[
                          const Text(' · ', style: TextStyle(fontSize: 12, color: C.muted)),
                          TextButton(key: const Key('panelOpen'), onPressed: widget.onOpen, child: const Text('Open')),
                        ],
                      ]),
                  ]),
                ),
              ),
          );
        },
      );

  Widget _offerRow() => Row(children: [
        const Expanded(child: Text(_changed, style: TextStyle(fontSize: 12, color: C.muted))),
        TextButton(onPressed: () => send(_offer!, replace: true), child: const Text('Replace')),
        TextButton(onPressed: () => setState(() => _offer = null), child: const Text('Keep')),
      ]);

  // laid out after the composer: a build-time read misses a reason line the same frame adds
  Widget _menu(List<SlashCommand> commands) => commands.isEmpty
      ? const SizedBox.shrink()
      : LayoutBuilder(builder: (context, _) {
          final box = _box.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return const SizedBox.shrink();
          final room = box.localToGlobal(Offset.zero).dy - MediaQuery.paddingOf(context).top - kToolbarHeight - 8; // below the app bar
          return Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _menuLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.size.width, minWidth: box.size.width, maxHeight: max(0, min(220, room))),
                child: Material(
                  color: C.surface,
                  elevation: 6,
                  child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                    for (final c in commands)
                      ListTile(
                        key: Key('slash-${c.name}'),
                        dense: true,
                        title: Text('/${c.name}', style: const TextStyle(fontFamily: mono)),
                        subtitle: c.description.isEmpty ? null : Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: c.panel ? const Text('opens in panel', style: TextStyle(fontSize: 12, color: C.muted)) : null,
                        onTap: () => insert('/${c.name} '),
                      ),
                  ]),
                ),
              ),
            ),
          );
        });
}

// Claude's own mode-line wording: the picker shows it verbatim (card rule 10)
const _modeLabels = {
  ClaudeMode.manual: 'manual mode on',
  ClaudeMode.acceptEdits: 'accept edits on',
  ClaudeMode.plan: 'plan mode on',
  ClaudeMode.auto: 'auto mode on',
  ClaudeMode.bypass: 'bypass permissions on',
};
const _modeNames = {
  ClaudeMode.manual: 'manual',
  ClaudeMode.acceptEdits: 'accept edits',
  ClaudeMode.plan: 'plan',
  ClaudeMode.auto: 'auto',
  ClaudeMode.bypass: 'bypass',
};
const _permissionModes = {
  'default': ClaudeMode.manual,
  'acceptEdits': ClaudeMode.acceptEdits,
  'plan': ClaudeMode.plan,
  'auto': ClaudeMode.auto,
  'bypassPermissions': ClaudeMode.bypass,
};

/// The composer's mode chip and shell badge: Shift+Tab through [gate] until Claude shows the picked mode.
class ModeChip extends StatefulWidget {
  const ModeChip(
      {super.key,
      required this.screen,
      required this.meta,
      required this.gate,
      required this.remote,
      this.server = false,
      this.disabledBy,
      this.checks = _checks});

  final ClaudeScreen? screen;
  final TranscriptMeta? meta;
  final WriteGate gate;
  final bool remote, server;
  final String? disabledBy;
  final Checks checks;

  @override
  State<ModeChip> createState() => ModeChipState();
}

class ModeChipState extends State<ModeChip> {
  bool _bypassSeen = false;

  List<ClaudeMode> get _cycle =>
      [ClaudeMode.manual, ClaudeMode.acceptEdits, ClaudeMode.plan, ClaudeMode.auto, if (_bypassSeen) ClaudeMode.bypass];

  /// One Shift+Tab per step until Claude shows [target]; stops when the start mode returns, after at most 5 steps.
  Future<GateResult> cycleTo(ClaudeMode target) {
    final cycle = _cycle;
    final start = widget.screen?.mode;
    var total = start == null || !cycle.contains(target) ? 1 : (cycle.indexOf(target) - cycle.indexOf(start)) % cycle.length;
    total = max(1, total);
    return widget.gate.run(total, (q) async {
      final from = ClaudeScreen.read(q.grid).mode;
      var mode = from;
      for (var n = 0; mode != target; n++) {
        if (n == 5 || (n > 0 && mode == from)) throw GateStop(GateOutcome.mismatch, 'Claude did not reach ${_modeLabels[target]}');
        if (n >= total) {
          total++;
          q.addSteps(1);
        }
        final expected = mode;
        await q.send(GateStep(KeyWrite(VtKey.tab, vtShift), ready: (g) {
          final s = ClaudeScreen.read(g);
          return s.idle && s.mode != null && s.mode == expected;
        }, done: (g) => switch (ClaudeScreen.read(g).mode) { final m? => m != expected, null => false }));
        unawaited(HapticFeedback.selectionClick());
        mode = ClaudeScreen.read(q.grid).mode;
      }
    });
  }

  Future<void> _pick() async {
    final current = widget.screen?.mode;
    final target = await showModalBottomSheet<ClaudeMode>(
        context: context,
        builder: (context) {
          ClaudeMode? armed;
          return StatefulBuilder(
              builder: (context, setSheet) => SafeArea(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final m in _cycle)
                        ListTile(
                          key: Key('mode-${m.name}'),
                          title: Text(_modeLabels[m]!),
                          subtitle: armed == m ? const Text('Tap again to switch') : null,
                          trailing: m == current ? const Icon(Icons.check) : null,
                          selected: armed == m,
                          onTap: () {
                            if (m == current) return Navigator.pop(context);
                            // a mode that auto-approves calls needs a second tap
                            if ((m == ClaudeMode.auto || m == ClaudeMode.bypass) && armed != m) return setSheet(() => armed = m);
                            Navigator.pop(context, m);
                          },
                        ),
                    ]),
                  ));
        });
    if (target == null || !mounted) return;
    final r = await cycleTo(target);
    if (!r.ok && mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(r.reason)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.screen;
    final meta = widget.meta?.permissionMode;
    if (s?.mode == ClaudeMode.bypass || meta == 'bypassPermissions') _bypassSeen = true;
    final hidden = s?.modeText == null; // G hides the mode line: the transcript's mode, dimmed
    final label = switch (s?.mode) {
      final m? => _modeNames[m]!,
      null when !hidden => s!.modeText!.split('·').first.replaceFirst(RegExp(r'^[⏸⏵\s]+'), '').trim(),
      null => _modeNames[_permissionModes[meta]] ?? meta ?? 'mode',
    };
    final enabled = s != null &&
        s.idle &&
        s.mode != null &&
        widget.disabledBy == null &&
        widget.checks.writeBlockedOn(remote: widget.remote, server: widget.server) == null &&
        !widget.gate.running;
    final shells = s?.shells ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        ActionChip(
          key: const Key('mode-chip'),
          label: Text(label, style: TextStyle(fontSize: 12, color: hidden ? C.muted : null)),
          visualDensity: VisualDensity.compact,
          onPressed: enabled ? _pick : null,
        ),
        if (shells > 0) ...[
          const SizedBox(width: 8),
          Text('$shells shell${shells == 1 ? '' : 's'}',
              key: const Key('shell-badge'), style: const TextStyle(fontSize: 12, color: C.muted)),
        ],
      ]),
    );
  }
}
