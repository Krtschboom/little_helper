import 'package:flutter/material.dart';

import '../services/checklist_service.dart';
import '../widgets/text_prompt_dialog.dart';
import 'manual_checklist_screen.dart';
import 'rule_checklist_screen.dart';
import 'rule_editor_screen.dart';

/// Lists all checklists. The plus button creates a new one.
class ChecklistsScreen extends StatefulWidget {
  const ChecklistsScreen({super.key});

  @override
  State<ChecklistsScreen> createState() => _ChecklistsScreenState();
}

class _ChecklistsScreenState extends State<ChecklistsScreen> {
  List<Checklist> _lists = [];
  Map<int, ({int done, int total})> _counts = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      final lists = ChecklistService.all();
      final counts = ChecklistService.manualCounts();
      setState(() {
        _lists = lists;
        _counts = counts;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fehler'),
        content: Text(e.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final choice = await showModalBottomSheet<ChecklistType>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('Normale Checkliste'),
              subtitle: const Text('Einträge mit mehreren Spalten selbst eintippen'),
              onTap: () => Navigator.pop(context, ChecklistType.manual),
            ),
            ListTile(
              leading: const Icon(Icons.rule),
              title: const Text('Regelbasierte Checkliste'),
              subtitle: const Text('Einträge erscheinen automatisch aus Tabellen'),
              onTap: () => Navigator.pop(context, ChecklistType.rule),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    try {
      if (choice == ChecklistType.manual) {
        final def = await showDialog<({String name, List<String> columns})>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const _NewManualChecklistDialog(),
        );
        if (def == null) return;
        ChecklistService.createManual(def.name, def.columns);
      } else {
        final result = await Navigator.of(context).push<RuleEditorResult>(
          MaterialPageRoute(builder: (_) => const RuleEditorScreen()),
        );
        if (result == null) return;
        ChecklistService.createRule(result.name, result.sources);
      }
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _open(Checklist list) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => list.type == ChecklistType.manual
            ? ManualChecklistScreen(checklistId: list.id)
            : RuleChecklistScreen(checklistId: list.id),
      ),
    );
    if (mounted) _load(); // counts may have changed
  }

  Future<void> _rename(Checklist list) async {
    final name = await showTextPrompt(
      context,
      title: 'Checkliste umbenennen',
      label: 'Neuer Name',
      initial: list.name,
      confirmLabel: 'Umbenennen',
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      ChecklistService.rename(list.id, name);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _editRules(Checklist list) async {
    final result = await Navigator.of(context).push<RuleEditorResult>(
      MaterialPageRoute(
        builder: (_) => RuleEditorScreen(
          initialName: list.name,
          initialSources: list.sources,
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      ChecklistService.rename(list.id, result.name);
      ChecklistService.updateRuleSources(list.id, result.sources);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(Checklist list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Checkliste "${list.name}" löschen?'),
        content: const Text(
          'Die Checkliste und alle ihre Einträge werden gelöscht. '
          'Tabellen, die mit ihr verknüpft sind, bleiben unverändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      ChecklistService.delete(list.id);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  String _subtitle(Checklist list) {
    if (list.type == ChecklistType.manual) {
      final c = _counts[list.id];
      final done = c == null ? '0 Einträge' : '${c.done} von ${c.total} erledigt';
      return 'Normale Checkliste · $done';
    }
    final n = list.sources.length;
    return 'Regelbasiert · $n ${n == 1 ? 'Tabelle' : 'Tabellen'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checklists')),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        tooltip: 'Neue Checkliste',
        child: const Icon(Icons.add),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            )
          : _lists.isEmpty
              ? const Center(child: Text('Noch keine Checklisten vorhanden.'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _lists.length,
                  itemBuilder: (context, i) {
                    final list = _lists[i];
                    return ListTile(
                      leading: Icon(
                        list.type == ChecklistType.manual
                            ? Icons.checklist
                            : Icons.rule,
                      ),
                      title: Text(list.name),
                      subtitle: Text(_subtitle(list)),
                      onTap: () => _open(list),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (action) {
                          switch (action) {
                            case 'rename':
                              _rename(list);
                            case 'rules':
                              _editRules(list);
                            case 'delete':
                              _delete(list);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Umbenennen'),
                          ),
                          if (list.type == ChecklistType.rule)
                            const PopupMenuItem(
                              value: 'rules',
                              child: Text('Regeln bearbeiten'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Löschen'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

/// Dialog for a new normal checklist: a name plus the column names.
class _NewManualChecklistDialog extends StatefulWidget {
  const _NewManualChecklistDialog();

  @override
  State<_NewManualChecklistDialog> createState() =>
      _NewManualChecklistDialogState();
}

class _NewManualChecklistDialogState extends State<_NewManualChecklistDialog> {
  final _nameCtrl = TextEditingController();
  final List<TextEditingController> _columns = [
    TextEditingController(text: 'Eintrag'),
  ];

  /// Removed column fields: disposed with the dialog (their text fields
  /// are still on screen until the next rebuild).
  final List<TextEditingController> _retired = [];

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final c in _columns) {
      c.dispose();
    }
    for (final c in _retired) {
      c.dispose();
    }
    super.dispose();
  }

  void _create() {
    final name = _nameCtrl.text.trim();
    final columns = [
      for (final c in _columns)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    if (name.isEmpty || columns.isEmpty) return;
    Navigator.pop(context, (name: name, columns: columns));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Neue Checkliste'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name der Checkliste',
                hintText: 'z.B. Packliste',
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _columns.length,
                itemBuilder: (context, i) {
                  final ctrl = _columns[i];
                  return Row(
                    key: ObjectKey(ctrl),
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          decoration: InputDecoration(
                            labelText: 'Spalte ${i + 1}',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: _columns.length > 1
                            ? () => setState(() {
                                  _retired.add(_columns.removeAt(i));
                                })
                            : null,
                      ),
                    ],
                  );
                },
              ),
            ),
            TextButton.icon(
              onPressed: () =>
                  setState(() => _columns.add(TextEditingController())),
              icon: const Icon(Icons.add),
              label: const Text('Spalte hinzufügen'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _create,
          child: const Text('Erstellen'),
        ),
      ],
    );
  }
}
