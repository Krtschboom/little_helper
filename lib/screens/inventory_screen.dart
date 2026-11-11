import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show ResultSet;

import '../services/db_service.dart';
import 'table_editor_screen.dart';

/// Lists all tables of the database and lets the user create new ones.
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  List<String> _tables = [];

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  void _loadTables() {
    final ResultSet result = DbService.instance.database.select(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
      "AND name NOT LIKE '_app_%' "
      "ORDER BY name",
    );
    setState(() {
      _tables = result.map((row) => row['name'] as String).toList();
    });
  }

  Future<void> _createTable() async {
    final definition = await _promptNewTable();
    if (definition == null) return;

    try {
      DbService.instance.database.execute(definition.sql);
      // Remember DATUM/BOOLEAN choices for the date picker / checkbox UI.
      for (final col in definition.columns) {
        DbService.instance
            .recordColumnType(definition.name, col.name, col.type);
      }
      _loadTables();
    } catch (e) {
      if (mounted) {
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
    }
  }

  /// Builds the CREATE TABLE statement from user input.
  Future<({String name, String sql, List<({String name, String type})> columns})?>
      _promptNewTable() {
    final nameCtrl = TextEditingController();
    final columns = <_ColumnSpec>[
      _ColumnSpec(),
    ];

    return showDialog<
        ({String name, String sql, List<({String name, String type})> columns})>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Neue Tabelle erstellen'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tabellenname',
                      hintText: 'z.B. items',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: columns.length,
                      itemBuilder: (context, i) {
                        final col = columns[i];
                        return Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: col.nameCtrl,
                                decoration: InputDecoration(
                                  labelText: 'Spalte ${i + 1}',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: col.type,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'TEXT',
                                    child: Text('TEXT'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'INTEGER',
                                    child: Text('INTEGER'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'REAL',
                                    child: Text('REAL'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'DATUM',
                                    child: Text('DATUM'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'BOOLEAN',
                                    child: Text('BOOLEAN'),
                                  ),
                                ],
                                onChanged: (v) =>
                                    setDialogState(() => col.type = v!),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: columns.length > 1
                                  ? () => setDialogState(
                                      () => columns.removeAt(i))
                                  : null,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        setDialogState(() => columns.add(_ColumnSpec())),
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
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  // DATUM and BOOLEAN have no native SQLite types:
                  // dates are stored as TEXT (ISO format), booleans as
                  // INTEGER (0/1).
                  const sqliteTypes = {
                    'DATUM': 'TEXT',
                    'BOOLEAN': 'INTEGER',
                  };
                  final colDefs = columns
                      .where((c) => c.nameCtrl.text.trim().isNotEmpty)
                      .map((c) =>
                          '"${c.nameCtrl.text.trim()}" '
                          '${sqliteTypes[c.type] ?? c.type}')
                      .toList();
                  if (colDefs.isEmpty) return;
                  Navigator.pop(
                    context,
                    (
                      name: name,
                      sql: 'CREATE TABLE "$name" (${colDefs.join(', ')})',
                      columns: columns
                          .where((c) => c.nameCtrl.text.trim().isNotEmpty)
                          .map((c) => (
                                name: c.nameCtrl.text.trim(),
                                type: c.type,
                              ))
                          .toList(),
                    ),
                  );
                },
                child: const Text('Erstellen'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Column editor: rename, delete and add columns of a table.
  /// Column TYPES of existing columns cannot be changed (SQLite
  /// limitation), but new columns can be TEXT, INTEGER, REAL,
  /// DATUM or BOOLEAN.
  Future<void> _editColumns(String table) async {
    final db = DbService.instance.database;
    final columns = (db.select('PRAGMA table_info("$table")'))
        .map((c) => c['name'] as String)
        .toList();

    final renameCtrl = <String, TextEditingController>{
      for (final c in columns) c: TextEditingController(text: c),
    };
    final deleted = <String>{};
    final newColumns = <_ColumnSpec>[];

    const sqliteTypes = {'DATUM': 'TEXT', 'BOOLEAN': 'INTEGER'};
    const typeItems = [
      DropdownMenuItem(value: 'TEXT', child: Text('TEXT')),
      DropdownMenuItem(value: 'INTEGER', child: Text('INTEGER')),
      DropdownMenuItem(value: 'REAL', child: Text('REAL')),
      DropdownMenuItem(value: 'DATUM', child: Text('DATUM')),
      DropdownMenuItem(value: 'BOOLEAN', child: Text('BOOLEAN')),
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Spalten von "$table" bearbeiten'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Bestehende Spalten:'),
                  for (final c in columns)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: renameCtrl[c],
                              enabled: !deleted.contains(c),
                              decoration: InputDecoration(
                                labelText: c,
                                labelStyle: deleted.contains(c)
                                    ? const TextStyle(
                                        decoration:
                                            TextDecoration.lineThrough)
                                    : null,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: deleted.contains(c)
                                ? 'Löschen rückgängig'
                                : 'Spalte löschen',
                            icon: Icon(deleted.contains(c)
                                ? Icons.undo
                                : Icons.delete_outline),
                            onPressed: () => setDialogState(() {
                              deleted.contains(c)
                                  ? deleted.remove(c)
                                  : deleted.add(c);
                            }),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  const Text('Neue Spalten:'),
                  for (final (i, col) in newColumns.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: col.nameCtrl,
                              decoration: InputDecoration(
                                labelText: 'Neue Spalte ${i + 1}',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              value: col.type,
                              items: typeItems,
                              onChanged: (v) =>
                                  setDialogState(() => col.type = v!),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setDialogState(
                                () => newColumns.remove(col)),
                          ),
                        ],
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => setDialogState(
                        () => newColumns.add(_ColumnSpec())),
                    icon: const Icon(Icons.add),
                    label: const Text('Spalte hinzufügen'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      renameCtrl.values.forEach((c) => c.dispose());
      newColumns.forEach((c) => c.nameCtrl.dispose());
      return;
    }

    try {
      for (final c in columns) {
        if (deleted.contains(c)) {
          db.execute('ALTER TABLE "$table" DROP COLUMN "$c"');
          DbService.instance.deleteColumnType(table, c);
          continue;
        }
        final renamed = renameCtrl[c]!.text.trim();
        if (renamed.isNotEmpty && renamed != c) {
          db.execute(
            'ALTER TABLE "$table" RENAME COLUMN "$c" TO "$renamed"',
          );
          // Move the recorded type along with the rename.
          final type = DbService.instance.columnType(table, c);
          if (type != null) {
            DbService.instance.deleteColumnType(table, c);
            DbService.instance.recordColumnType(table, renamed, type);
          }
        }
      }
      for (final col in newColumns) {
        final name = col.nameCtrl.text.trim();
        if (name.isEmpty) continue;
        db.execute(
          'ALTER TABLE "$table" ADD COLUMN "$name" '
          '${sqliteTypes[col.type] ?? col.type}',
        );
        DbService.instance.recordColumnType(table, name, col.type);
      }

      renameCtrl.values.forEach((c) => c.dispose());
      newColumns.forEach((c) => c.nameCtrl.dispose());
      _loadTables();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tabelle aktualisiert')),
        );
      }
    } catch (e) {
      _showError(e);
    }
  }

  /// Renames a table via ALTER TABLE ... RENAME TO.
  Future<void> _renameTable(String table) async {
    final controller = TextEditingController(text: table);
    final newName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Tabelle "$table" umbenennen'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Neuer Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Umbenennen'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == table) return;

    try {
      DbService.instance.database
          .execute('ALTER TABLE "$table" RENAME TO "$newName"');
      _loadTables();
    } catch (e) {
      _showError(e);
    }
  }

  /// Exports the table content as a CSV file via a save-file dialog.
  Future<void> _exportTable(String table) async {
    try {
      final db = DbService.instance.database;
      final columns = (db.select('PRAGMA table_info("$table")'))
          .map((c) => c['name'] as String)
          .toList();
      final rows = db.select('SELECT * FROM "$table"');

      String csv = columns.map(_csvEscape).join(';') + '\n';
      for (final row in rows) {
        csv += columns
            .map((c) => _csvEscape(row[c]?.toString()))
            .join(';') + '\n';
      }

      final path = await FilePicker.platform.saveFile(
        fileName: '$table.csv',
        bytes: Uint8List.fromList(csv.codeUnits),
      );
      if (path == null) return; // user cancelled
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exportiert nach: $path')),
        );
      }
    } catch (e) {
      _showError(e);
    }
  }

  /// Escapes a value for CSV output (semicolon-separated).
  String _csvEscape(String? value) {
    final v = value ?? '';
    final needsQuotes =
        v.contains(';') || v.contains('"') || v.contains('\n');
    final escaped = v.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  /// Drops a table after confirmation. This deletes the table AND all
  /// its data and cannot be undone.
  Future<void> _deleteTable(String table) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Tabelle "$table" löschen?'),
        content: const Text(
          'Die Tabelle und alle ihre Daten werden unwiderruflich gelöscht.',
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
    if (confirmed != true) return;

    try {
      DbService.instance.database.execute('DROP TABLE "$table"');
      _loadTables();
    } catch (e) {
      _showError(e);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createTable,
        icon: const Icon(Icons.add),
        label: const Text('Neue Tabelle'),
      ),
      body: _tables.isEmpty
          ? const Center(child: Text('Noch keine Tabellen vorhanden.'))
          : ListView.builder(
              itemCount: _tables.length,
              itemBuilder: (context, i) {
                final table = _tables[i];
                return ListTile(
                  leading: const Icon(Icons.table_chart_outlined),
                  title: Text(table),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) {
                      switch (action) {
                        case 'rename':
                          _renameTable(table);
                        case 'edit':
                          _editColumns(table);
                        case 'export':
                          _exportTable(table);
                        case 'delete':
                          _deleteTable(table);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text('Umbenennen'),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: Text('Bearbeiten'),
                      ),
                      PopupMenuItem(
                        value: 'export',
                        child: Text('Exportieren (CSV)'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Löschen'),
                      ),
                    ],
                  ),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TableEditorScreen(table: table),
                      ),
                    );
                    _loadTables(); // refresh after coming back
                  },
                );
              },
            ),
    );
  }
}

class _ColumnSpec {
  final TextEditingController nameCtrl = TextEditingController();
  String type = 'TEXT';
}