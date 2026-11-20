import 'package:flutter/material.dart';

import '../model.dart';
import '../theme.dart';
import 'feed.dart';
import 'grid.dart';
import 'write_gate.dart';

/// Claude's session as a chat: the transcript's items over the live grid; every write goes through [gate].
class ChatView extends StatelessWidget {
  const ChatView(
      {super.key,
      required this.feed,
      required this.grid,
      required this.grids,
      required this.gate,
      required this.s,
      required this.exited,
      required this.stale,
      required this.onTerm});

  final TranscriptFeed feed;
  final Grid? Function() grid;
  final Listenable grids;
  final WriteGate gate;
  final Session s;
  final bool exited, stale;
  final VoidCallback onTerm;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: C.bg,
        child: ListenableBuilder(
          listenable: feed,
          builder: (context, _) => Column(children: [
            if (exited)
              ListTile(
                  key: const Key('chatExited'),
                  title: const Text('Claude exited'),
                  trailing: TextButton(onPressed: onTerm, child: const Text('Term'))),
            if (stale) const Padding(padding: EdgeInsets.all(8), child: Text('Reconnecting…', style: TextStyle(color: C.muted))),
            Expanded(
              child: ListView(reverse: true, padding: const EdgeInsets.fromLTRB(12, 48, 12, 12), children: [
                for (final i in feed.items.reversed)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(i.text ?? i.name ?? i.kind)),
              ]),
            ),
          ]),
        ),
      );
}
