import 'package:flutter/material.dart';

import '../model.dart';
import '../theme.dart';
import 'actions.dart';
import 'session.dart';

// elis's workspace "+" menu: the launcher ids and the command each types into the new shell
const launchers = [
  ('terminal', 'Terminal', ''),
  ('claude', 'Claude Code', 'claude'),
  ('codex', 'Codex', 'codex'),
  ('opencode', 'OpenCode', 'opencode'),
  ('antigravity', 'Antigravity', 'agy'),
];

Future<void> showNewSession(BuildContext context, ElisModel m, {String? workspaceId, Session? parent}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: NewSessionSheet(model: m, workspaceId: workspaceId, parent: parent, host: context),
      ),
    );

class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({super.key, required this.model, required this.host, this.workspaceId, this.parent});
  final ElisModel model;
  final String? workspaceId;
  final Session? parent;
  final BuildContext host; // pushes the new session's screen after the sheet closes

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  late String launcher = 'terminal';
  late String? workspace = widget.workspaceId ?? widget.model.workspaces.where((w) => w.active).firstOrNull?.id ?? widget.model.workspaces.firstOrNull?.id;
  final name = TextEditingController();
  late final cwd = TextEditingController(text: widget.parent?.cwd ?? '');
  bool showOnDesktop = false, busy = false;
  String? error;

  Future<void> createWorkspace() async {
    final n = await promptText(context, 'New workspace', hint: 'Name', action: 'Create');
    if (n == null || n.trim().isEmpty) return;
    try {
      final r = await widget.model.call('workspace.new', args: {'name': n.trim()});
      await widget.model.refresh();
      setState(() => workspace = r['id'] as String? ?? workspace);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> create() async {
    setState(() => (busy = true, error = null));
    final l = launchers.firstWhere((x) => x.$1 == launcher);
    final args = <String, dynamic>{
      if (name.text.trim().isNotEmpty) 'name': name.text.trim(),
      if (cwd.text.trim().isNotEmpty) 'cwd': expandHome(cwd.text.trim(), _home()),
      if (l.$3.isNotEmpty) 'command': l.$3,
      if (widget.parent == null && workspace != null) 'workspace': workspace,
      if (!showOnDesktop) 'noSelect': true,
    };
    try {
      final r = await widget.model.call(widget.parent == null ? 'session.new' : 'session.companion.new', target: widget.parent?.id, args: args);
      await widget.model.refresh();
      if (!mounted) return;
      Navigator.pop(context);
      final id = r['id'] as String?;
      if (id != null && widget.host.mounted) {
        Navigator.of(widget.host).push(MaterialPageRoute(builder: (_) => SessionScreen(model: widget.model, sessionId: id)));
      }
    } catch (e) {
      setState(() => (busy = false, error = '$e'));
    }
  }

  // the computer's home, from a session's folder; "~" only works when some session shows it
  String _home() =>
      widget.model.sessions.map((s) => homePrefix.stringMatch(s.cwd)).whereType<String>().firstOrNull ??
      widget.model.workspaces.map((w) => homePrefix.stringMatch(w.folder)).whereType<String>().firstOrNull ??
      '~';

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final label = launchers.firstWhere((x) => x.$1 == launcher).$2;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.parent == null ? 'New session' : 'New companion of ${widget.parent!.name}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 18),
          const Text('START', style: sectionLabel),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.45,
            children: [
              for (final l in launchers)
                _LauncherTile(id: l.$1, title: l.$2, selected: l.$1 == launcher, onTap: () => setState(() => launcher = l.$1)),
            ],
          ),
          if (widget.parent == null) ...[
            const SizedBox(height: 18),
            const Text('WORKSPACE', style: sectionLabel),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final w in m.workspaces)
                ChoiceChip(
                  label: Text(w.name),
                  selected: w.id == workspace,
                  onSelected: (_) => setState(() => workspace = w.id),
                  showCheckmark: false,
                  selectedColor: C.text,
                  labelStyle: TextStyle(color: w.id == workspace ? C.bg : C.text, fontWeight: w.id == workspace ? FontWeight.w600 : null),
                  backgroundColor: C.surface2,
                  side: BorderSide(color: w.id == workspace ? C.text : C.line),
                  shape: const StadiumBorder(),
                ),
              ActionChip(
                label: const Text('+ New workspace', style: TextStyle(color: C.accent)),
                onPressed: createWorkspace,
                backgroundColor: Colors.transparent,
                side: const BorderSide(color: Color(0xFF573A25)), // copper 35% over bg
                shape: const StadiumBorder(),
              ),
            ]),
          ],
          const SizedBox(height: 18),
          const Text('NAME', style: sectionLabel),
          const SizedBox(height: 6),
          TextField(key: const Key('newName'), controller: name, decoration: const InputDecoration(hintText: "Optional — the program's title by default")),
          const SizedBox(height: 14),
          const Text('FOLDER', style: sectionLabel),
          const SizedBox(height: 6),
          TextField(
            controller: cwd,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            decoration: InputDecoration(hintText: switch (m.workspaces.where((w) => w.id == workspace).firstOrNull?.folder) { final f? => shortHome(f), _ => 'The workspace folder' }),
            autocorrect: false,
          ),
          CheckboxListTile(
            value: showOnDesktop,
            onChanged: (v) => setState(() => showOnDesktop = v ?? false),
            title: const Text('Show it on the computer too'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          if (error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(error!, style: const TextStyle(color: C.danger))),
          FilledButton(
            key: const Key('createSession'),
            onPressed: busy ? null : create,
            child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text('Start $label'),
          ),
        ]),
      ),
    );
  }
}

class _LauncherTile extends StatelessWidget {
  const _LauncherTile({required this.id, required this.title, required this.selected, required this.onTap});
  final String id, title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? const Color(0xFF2D2521) : C.surface2, // copper 10% over bg
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? C.accent : C.line, width: selected ? 1.5 : 1)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Semantics(
            selected: selected,
            button: true,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              AgentIcon(id, size: 28, background: Colors.transparent),
              const SizedBox(height: 4),
              Text(title, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w600 : null)),
            ]),
          ),
        ),
      );
}
