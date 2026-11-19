// Row menus: what the desktop sidebar's context menus do, as bottom sheets.
import 'package:flutter/material.dart';

import '../model.dart';
import '../notice.dart';
import '../theme.dart';
import 'new_session.dart';

Future<String?> promptText(BuildContext context, String title, {String initial = '', String hint = '', String action = 'Save'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
          key: const Key('promptField'),
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(context, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: Text(action)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: C.danger), onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ==
    true;

/// Shows the error a command answered once it finishes, if the screen is still there.
Future<void> reportOf(BuildContext context, Future<String?> result) async {
  final error = await result;
  if (context.mounted) report(context, error);
}

void report(BuildContext context, String? error) {
  if (error != null && context.mounted) showNotice(context, error);
}

Widget _item(IconData icon, String label, VoidCallback onTap, {Color? color, Key? key}) => ListTile(
      key: key,
      leading: Icon(icon, color: color ?? C.muted),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
      minTileHeight: 52,
    );

Future<String?> pickTint(BuildContext context, String title) => showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final t in tints.entries)
                Semantics(
                  label: t.key,
                  button: true,
                  child: Material(
                    color: t.value,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () => Navigator.pop(context, t.key),
                      customBorder: const CircleBorder(),
                      child: const SizedBox(width: 48, height: 48),
                    ),
                  ),
                ),
              OutlinedButton(onPressed: () => Navigator.pop(context, 'clear'), child: const Text('None')),
            ]),
          ]),
        ),
      ),
    );

Future<void> showSessionActions(BuildContext context, ElisModel m, Session s, {VoidCallback? onClosed, VoidCallback? onComposer}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (sheet) {
      void run(Future<String?> Function() action) async {
        Navigator.pop(sheet);
        reportOf(context, action());
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(s.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            _item(Icons.desktop_windows_outlined, 'Show on the computer', () => run(() => m.act('session.select', target: s.id))),
            if (onComposer != null)
              _item(Icons.keyboard_outlined, ComposerPref.shown ? 'Hide composer' : 'Show composer', key: const Key('composerToggle'), () {
                Navigator.pop(sheet);
                ComposerPref.set(!ComposerPref.shown).catchError((_) {});
                onComposer();
              }),
            _item(Icons.edit_outlined, 'Rename', () async {
              Navigator.pop(sheet);
              final name = await promptText(context, 'Rename session', initial: s.name);
              if (name != null && context.mounted) reportOf(context, m.act('session.rename', target: s.id, args: {'name': name}));
            }),
            _item(s.flagged ? Icons.flag : Icons.outlined_flag, s.flagged ? 'Unflag' : 'Flag',
                () => run(() => m.act('session.flag', target: s.id, args: {'mode': s.flagged ? 'off' : 'on'}))),
            if (s.status != 'idle')
              _item(Icons.radio_button_unchecked, 'Clear status', () => run(() => m.act('session.status', target: s.id, args: {'status': 'idle'}))),
            if (s.unseen > 0) _item(Icons.mark_email_read_outlined, 'Mark notifications seen', () => run(() => m.act('session.seen', target: s.id))),
            _item(Icons.short_text, s.context.isEmpty ? 'Set context line' : 'Edit context line', () async {
              Navigator.pop(sheet);
              final text = await promptText(context, 'Context line', initial: s.context, hint: 'What this session is about');
              if (text != null && context.mounted) {
                reportOf(context, m.act('session.context', target: s.id, args: text.trim().isEmpty ? {'mode': 'clear'} : {'mode': 'set', 'text': text}));
              }
            }),
            _item(Icons.palette_outlined, 'Tint', () async {
              Navigator.pop(sheet);
              final t = await pickTint(context, 'Tint session');
              if (t != null && context.mounted) {
                reportOf(context, m.act('session.tint', target: s.id, args: t == 'clear' ? {'mode': 'clear'} : {'mode': 'set', 'tint': t}));
              }
            }),
            _item(Icons.drive_file_move_outlined, 'Move to workspace', () async {
              Navigator.pop(sheet);
              final w = await showModalBottomSheet<String>(
                context: context,
                builder: (c) => SafeArea(
                  child: ListView(shrinkWrap: true, children: [
                    for (final w in m.workspaces.where((w) => w.id != s.workspaceId))
                      ListTile(title: Text(w.name), onTap: () => Navigator.pop(c, w.id), minTileHeight: 52),
                  ]),
                ),
              );
              if (w != null && context.mounted) reportOf(context, m.act('session.move', target: s.id, args: {'workspace': w}));
            }),
            _item(Icons.copy_outlined, 'Duplicate', () => run(() => m.act('session.duplicate', target: s.id, args: {'noSelect': true}))),
            _item(Icons.subdirectory_arrow_right, 'New companion', () async {
              Navigator.pop(sheet);
              await showNewSession(context, m, workspaceId: s.workspaceId, parent: s);
            }),
            _item(Icons.close, 'Close session', key: const Key('closeSession'), color: C.danger, () async {
              Navigator.pop(sheet);
              if (!await confirm(context, 'Close "${s.name}"?', 'Its terminal and the program running in it end on the computer.', 'Close')) return;
              final err = await m.act('session.close', target: s.id);
              if (context.mounted) report(context, err);
              if (err == null) onClosed?.call();
            }),
            const SizedBox(height: 8),
          ]),
        ),
      );
    },
  );
}

Future<void> showWorkspaceActions(BuildContext context, ElisModel m, Workspace w) {
  return showModalBottomSheet(
    context: context,
    builder: (sheet) {
      void run(Future<String?> Function() action) async {
        Navigator.pop(sheet);
        reportOf(context, action());
      }

      final allFlagged = w.sessions.isNotEmpty && w.sessions.every((s) => s.flagged);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(w.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
          _item(Icons.add, 'New session here', () async {
            Navigator.pop(sheet);
            await showNewSession(context, m, workspaceId: w.id);
          }),
          _item(Icons.edit_outlined, 'Rename', () async {
            Navigator.pop(sheet);
            final name = await promptText(context, 'Rename workspace', initial: w.name);
            if (name != null && name.isNotEmpty && context.mounted) reportOf(context, m.act('workspace.rename', target: w.id, args: {'name': name}));
          }),
          _item(allFlagged ? Icons.flag : Icons.outlined_flag, allFlagged ? 'Unflag all sessions' : 'Flag all sessions',
              () => run(() => m.act('workspace.flag', target: w.id, args: {'mode': allFlagged ? 'off' : 'on'}))),
          _item(Icons.palette_outlined, 'Tint', () async {
            Navigator.pop(sheet);
            final t = await pickTint(context, 'Tint workspace');
            if (t != null && context.mounted) {
              reportOf(context, m.act('workspace.tint', target: w.id, args: t == 'clear' ? {'mode': 'clear'} : {'mode': 'set', 'tint': t}));
            }
          }),
          _item(Icons.delete_outline, 'Delete workspace', color: C.danger, () async {
            Navigator.pop(sheet);
            if (!await confirm(context, 'Delete "${w.name}"?', 'Its ${w.sessions.length} sessions close on the computer.', 'Delete')) return;
            if (context.mounted) reportOf(context, m.act('workspace.delete', target: w.id));
          }),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
}
