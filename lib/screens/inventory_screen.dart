import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show ResultSet;

import '../services/db_service.dart';
import 'table_editor_screen.dart';

/// Quotes a table/column name for SQL (doubles any `"` inside it).
String _q(String name) => DbService.quoteIdentifier(name);

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
      r"SELECT name FROM sqlite_master "
      r"WHERE type = 'table' "
      r"AND name NOT LIKE 'sqlite\_%' ESCAPE '\' "
      r"AND name NOT LIKE '\_app\_%' ESCAPE '\' "
      r"ORDER BY name",
    );
    setState(() {
      _tables = result.map((row) => row['name'] as String).toList();
    });
  }

  /// FAB: choose between creating an empty table manually or
  /// importing an existing CSV file.
  Future<void> _createTable() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.grid_on_outlined),
              title: const Text('Neue Tabelle erstellen'),
              subtitle: const Text('Spalten und Typen selbst festlegen'),
              onTap: () => Navigator.pop(context, 'manual'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('CSV importieren'),
              subtitle: const Text('Spaltennamen aus der Datei übernehmen'),
              onTap: () => Navigator.pop(context, 'csv'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    if (choice == 'csv') {
      await _importCsv();
      return;
    }

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
                                initialValue: col.type,
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
                          '${_q(c.nameCtrl.text.trim())} '
                          '${sqliteTypes[c.type] ?? c.type}')
                      .toList();
                  if (colDefs.isEmpty) return;
                  Navigator.pop(
                    context,
                    (
                      name: name,
                      sql: 'CREATE TABLE ${_q(name)} (${colDefs.join(', ')})',
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
    final columns = (db.select('PRAGMA table_info(${_q(table)})'))
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
                              initialValue: col.type,
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
      for (var c in renameCtrl.values) {
        c.dispose();
      }
      for (var c in newColumns) {
        c.nameCtrl.dispose();
      }
      return;
    }

    try {
      for (final c in columns) {
        if (deleted.contains(c)) {
          db.execute('ALTER TABLE ${_q(table)} DROP COLUMN ${_q(c)}');
          DbService.instance.deleteColumnType(table, c);
          continue;
        }
        final renamed = renameCtrl[c]!.text.trim();
        if (renamed.isNotEmpty && renamed != c) {
          db.execute(
            'ALTER TABLE ${_q(table)} RENAME COLUMN ${_q(c)} TO ${_q(renamed)}',
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
          'ALTER TABLE ${_q(table)} ADD COLUMN ${_q(name)} '
          '${sqliteTypes[col.type] ?? col.type}',
        );
        DbService.instance.recordColumnType(table, name, col.type);
      }

      for (var c in renameCtrl.values) {
        c.dispose();
      }
      for (var c in newColumns) {
        c.nameCtrl.dispose();
      }
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
          .execute('ALTER TABLE ${_q(table)} RENAME TO ${_q(newName)}');
      // Move the recorded DATUM/BOOLEAN types to the new table name.
      DbService.instance.renameTableTypes(table, newName);
      _loadTables();
    } catch (e) {
      _showError(e);
    }
  }

  /// Imports a CSV file as a new table. The column names are taken
  /// from the header row, the types are auto-detected and can be
  /// adjusted per column before creating the table.
  Future<void> _importCsv() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true, // read the bytes directly (also needed on Linux)
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return; // user cancelled

    final content = utf8.decode(file.bytes!, allowMalformed: true);
    final delim = _sniffDelimiter(content);
    final rows = _parseCsv(content, delim);
    if (rows.isEmpty) {
      _showError('Die CSV-Datei ist leer.');
      return;
    }

    final header = rows.first;
    final dataRows = rows.skip(1).toList();
    if (header.isEmpty || header.every((h) => h.trim().isEmpty)) {
      _showError('Die CSV-Datei hat keine gültige Kopfzeile.');
      return;
    }

    // Auto-detect a type for every column from its values.
    final types = <String>[];
    for (var i = 0; i < header.length; i++) {
      final values = dataRows
          .map((r) => i < r.length ? r[i].trim() : '')
          .toList();
      types.add(_guessType(values));
    }

    final definition = await _promptCsvImport(file.name, header, types);
    if (definition == null) return;

    try {
      final db = DbService.instance.database;
      // All-or-nothing: build the table and insert everything inside
      // one transaction.
      db.execute('BEGIN');
      try {
        db.execute(definition.sql);
        final placeholders = List.filled(header.length, '?').join(', ');
        final insertSql =
            'INSERT INTO ${_q(definition.name)} VALUES ($placeholders)';
        // sqlite3's execute() takes no parameters - use a prepared
        // statement instead.
        final stmt = db.prepare(insertSql);
        try {
          for (final row in dataRows) {
            stmt.execute([
              for (var i = 0; i < header.length; i++)
                _convertValue(
                  i < row.length ? row[i].trim() : '',
                  definition.columns[i].type,
                ),
            ]);
          }
        } finally {
          stmt.dispose();
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      // Remember DATUM/BOOLEAN choices for the date picker / checkbox UI.
      for (final col in definition.columns) {
        DbService.instance
            .recordColumnType(definition.name, col.name, col.type);
      }
      _loadTables();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '"${definition.name}" importiert '
              '(${dataRows.length} Zeilen)',
            ),
          ),
        );
      }
    } catch (e) {
      _showError(e);
    }
  }

  /// Import dialog: table name plus one type dropdown per CSV column,
  /// pre-filled with the auto-detected type.
  Future<({String name, String sql, List<({String name, String type})> columns})?>
      _promptCsvImport(
    String fileName,
    List<String> header,
    List<String> guessedTypes,
  ) {
    final nameCtrl = TextEditingController();
    // Suggest the file name (without extension) as table name.
    final baseName = fileName.replaceAll(RegExp(r'\.csv$', caseSensitive: false), '').trim();
    nameCtrl.text = baseName;

    final types = <String>[...guessedTypes];
    final usedNames = <String>{};
    // Make duplicate/empty column names unique.
    final columnNames = <String>[];
    for (final h in header) {
      var name = h.trim();
      if (name.isEmpty) name = 'Spalte';
      var candidate = name;
      var n = 2;
      while (usedNames.contains(candidate)) {
        candidate = '$name $n';
        n++;
      }
      usedNames.add(candidate);
      columnNames.add(candidate);
    }

    return showModalBottomSheet<
        ({String name, String sql, List<({String name, String type})> columns})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'CSV importieren',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Spaltennamen wurden aus der Datei übernommen – '
                'Typen kannst du anpassen.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Tabellenname',
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: header.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            columnNames[i],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: types[i],
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
                                setSheetState(() => types[i] = v!),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  const sqliteTypes = {
                    'DATUM': 'TEXT',
                    'BOOLEAN': 'INTEGER',
                  };
                  final colDefs = [
                    for (var i = 0; i < columnNames.length; i++)
                      '${_q(columnNames[i])} ${sqliteTypes[types[i]] ?? types[i]}',
                  ];
                  Navigator.pop(
                    context,
                    (
                      name: name,
                      sql: 'CREATE TABLE ${_q(name)} (${colDefs.join(', ')})',
                      columns: [
                        for (var i = 0; i < columnNames.length; i++)
                          (name: columnNames[i], type: types[i]),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.check),
                label: const Text('Importieren'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Guesses the column type from all non-empty values of a column.
  String _guessType(List<String> values) {
    final nonEmpty =
        values.where((v) => v.isNotEmpty).toList();
    if (nonEmpty.isEmpty) return 'TEXT';

    final intRegex = RegExp(r'^-?\d+$');
    final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    const boolValues = {'true', 'false', 'ja', 'nein', 'wahr', 'falsch'};

    bool all(bool Function(String) test) => nonEmpty.every(test);

    if (all((v) => intRegex.hasMatch(v))) return 'INTEGER';
    if (all((v) => double.tryParse(v.replaceAll(',', '.')) != null)) {
      return 'REAL';
    }
    if (all((v) => dateRegex.hasMatch(v))) return 'DATUM';
    if (all((v) => boolValues.contains(v.toLowerCase()))) return 'BOOLEAN';
    return 'TEXT';
  }

  /// Converts a raw CSV value to the value inserted for the given
  /// logical type (DATUM stays TEXT, BOOLEAN becomes 0/1).
  Object? _convertValue(String raw, String type) {
    if (raw.isEmpty) return null;
    switch (type) {
      case 'INTEGER':
        return int.tryParse(raw) ?? int.tryParse(raw.split('.').first);
      case 'REAL':
        return double.tryParse(raw.replaceAll(',', '.'));
      case 'BOOLEAN':
        final v = raw.toLowerCase();
        const truthy = {'1', 'true', 'ja', 'wahr', 'yes'};
        return truthy.contains(v) ? 1 : 0;
      default: // TEXT, DATUM
        return raw;
    }
  }

  /// Detects whether the file uses ';' or ',' as separator by
  /// counting both in the first lines.
  String _sniffDelimiter(String content) {
    var semis = 0;
    var commas = 0;
    for (final line in content.split('\n').take(5)) {
      semis += ';'.allMatches(line).length;
      commas += ','.allMatches(line).length;
    }
    return commas > semis ? ',' : ';';
  }

  /// Parses CSV content into rows, honouring quoted fields that may
  /// contain the delimiter, escaped quotes (""), and newlines.
  List<List<String>> _parseCsv(String content, String delim) {
    final rows = <List<String>>[];
    final row = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < content.length; i++) {
      final ch = content[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < content.length && content[i + 1] == '"') {
            sb.write('"');
            i++; // skip escaped quote
          } else {
            inQuotes = false;
          }
        } else {
          sb.write(ch);
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == delim) {
        row.add(sb.toString());
        sb.clear();
      } else if (ch == '\r' || ch == '\n') {
        if (ch == '\r' && i + 1 < content.length && content[i + 1] == '\n') {
          i++;
        }
        row.add(sb.toString());
        sb.clear();
        if (row.length > 1 || row.first.isNotEmpty) {
          rows.add(List.of(row));
        }
        row.clear();
      } else {
        sb.write(ch);
      }
    }
    if (sb.isNotEmpty || row.isNotEmpty) {
      row.add(sb.toString());
      if (row.length > 1 || row.first.isNotEmpty) {
        rows.add(row);
      }
    }
    return rows;
  }

  /// Exports the table content as a CSV file via a save-file dialog.
  Future<void> _exportTable(String table) async {
    try {
      final db = DbService.instance.database;
      final columns = (db.select('PRAGMA table_info(${_q(table)})'))
          .map((c) => c['name'] as String)
          .toList();
      final rows = db.select('SELECT * FROM ${_q(table)}');

      // StringBuffer instead of `csv += ...` (which copies the whole
      // text for every row).
      final buffer = StringBuffer()
        ..writeln(columns.map(_csvEscape).join(';'));
      for (final row in rows) {
        buffer.writeln(
          columns.map((c) => _csvEscape(row[c]?.toString())).join(';'),
        );
      }

      final path = await FilePicker.platform.saveFile(
        fileName: '$table.csv',
        // utf8.encode (not codeUnits): umlauts must be written as UTF-8.
        bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
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
        v.contains(';') ||
        v.contains('"') ||
        v.contains('\n') ||
        v.contains('\r');
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
      DbService.instance.database.execute('DROP TABLE ${_q(table)}');
      DbService.instance.deleteTableTypes(table);
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