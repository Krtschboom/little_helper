import 'package:flutter/material.dart';

import '../services/checklist_service.dart';

/// A normal checklist: free-text entries with one or more columns.
class ManualChecklistScreen extends StatefulWidget {
  const ManualChecklistScreen({super.key, required this.checklistId});

  final int checklistId;

  @override
  State<ManualChecklistScreen> createState() => _ManualChecklistScreenState();
}

class _ManualChecklistScreenState extends State<ManualChecklistScreen> {
  Checklist? _list;
  List<ManualItem> _items = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      final list = ChecklistService.byId(widget.checklistId);
      final items = ChecklistService.items(widget.checklistId);
      setState(() {
        _list = list;
        _items = items;
        _error = list == null ? 'Checkliste nicht gefunden.' : null;
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

  /// Add (item == null) or edit an entry.
  Future<void> _editItem({ManualItem? item}) async {
    final list = _list;
    if (list == null) return;
    final cells = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ItemDialog(columns: list.columns, initial: item?.cells),
    );
    if (cells == null || !mounted) return;
    try {
      if (item == null) {
        ChecklistService.addItem(list.id, cells);
      } else {
        ChecklistService.updateItem(item.id, cells);
      }
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  void _toggle(ManualItem item, bool checked) {
    try {
      ChecklistService.setItemChecked(item.id, checked);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  void _delete(ManualItem item) {
    try {
      ChecklistService.deleteItem(item.id);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _removeChecked() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Erledigte Einträge entfernen?'),
        content: const Text('Alle abgehakten Einträge werden gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      ChecklistService.deleteCheckedItems(widget.checklistId);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  void _uncheckAll() {
    try {
      ChecklistService.uncheckAllItems(widget.checklistId);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final scheme = Theme.of(context).colorScheme;

    if (_error != null || list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Checkliste')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error ?? 'Lädt ...',
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
      );
    }

    final columns = list.columns;
    final done = _items.where((i) => i.checked).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(list.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'uncheck':
                  _uncheckAll();
                case 'remove':
                  _removeChecked();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'uncheck',
                child: Text('Alle Haken entfernen'),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Text('Erledigte Einträge löschen'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editItem(),
        icon: const Icon(Icons.add),
        label: const Text('Eintrag'),
      ),
      body: Column(
        children: [
          // Column headers (only useful with more than one column).
          if (columns.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(64, 8, 56, 0),
              child: Row(
                children: [
                  for (final c in columns)
                    Expanded(
                      child: Text(
                        c,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('Noch keine Einträge.'))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      final style = item.checked
                          ? TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: scheme.onSurface.withValues(alpha: 0.5),
                            )
                          : null;
                      return InkWell(
                        onTap: () => _editItem(item: item),
                        child: Row(
                          children: [
                            Checkbox(
                              value: item.checked,
                              onChanged: (v) => _toggle(item, v ?? false),
                            ),
                            const SizedBox(width: 8),
                            for (var c = 0; c < columns.length; c++)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 4,
                                  ),
                                  child: Text(
                                    c < item.cells.length ? item.cells[c] : '',
                                    style: style,
                                  ),
                                ),
                              ),
                            IconButton(
                              tooltip: 'Eintrag löschen',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(item),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$done von ${_items.length} erledigt',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Dialog to add or edit one entry: one text field per column.
class _ItemDialog extends StatefulWidget {
  const _ItemDialog({required this.columns, this.initial});

  final List<String> columns;
  final List<String>? initial;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final List<TextEditingController> _controllers = [
    for (var i = 0; i < widget.columns.length; i++)
      TextEditingController(
        text: (widget.initial != null && i < widget.initial!.length)
            ? widget.initial![i]
            : '',
      ),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final cells = [for (final c in _controllers) c.text.trim()];
    if (cells.every((c) => c.isEmpty)) return; // nothing typed
    Navigator.pop(context, cells);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Neuer Eintrag' : 'Eintrag bearbeiten'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.columns.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    controller: _controllers[i],
                    autofocus: i == 0,
                    decoration: InputDecoration(labelText: widget.columns[i]),
                    textInputAction: i == widget.columns.length - 1
                        ? TextInputAction.done
                        : TextInputAction.next,
                    onSubmitted: (_) {
                      if (i == widget.columns.length - 1) _save();
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
