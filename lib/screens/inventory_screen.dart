import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show ResultSet;

import '../services/checklist_service.dart';
import '../services/db_service.dart';
import '../widgets/text_prompt_dialog.dart';
import 'table_editor_screen.dart';

/// Quotes a table/column name for SQL (doubles any `"` inside it).
String _q(String name) => DbService.quoteIdentifier(name);

/// App-level column types -> what SQLite really stores:
///   DATUM   -> TEXT    (ISO date)
///   BOOLEAN -> INTEGER (0/1)
///   COUNTER -> INTEGER (shown with [-] value [+] buttons in the table)
const _sqliteTypes = {
  'DATUM': 'TEXT',
  'BOOLEAN': 'INTEGER',
  'COUNTER': 'INTEGER',
};

/// The types the user can pick in the dropdowns. (COUNTER is not in
/// the list: it is "INTEGER" + the +/- checkbox.)
const List<DropdownMenuItem<String>> _typeItems = [
  DropdownMenuItem(value: 'TEXT', child: Text('TEXT')),
  DropdownMenuItem(value: 'INTEGER', child: Text('INTEGER')),
  DropdownMenuItem(value: 'REAL', child: Text('REAL')),
  DropdownMenuItem(value: 'DATUM', child: Text('DATUM')),
  DropdownMenuItem(value: 'BOOLEAN', child: Text('BOOLEAN')),
];

typedef _ColumnDef = ({String name, String type});
typedef _TableDef = ({String name, String sql, List<_ColumnDef> columns});

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
    if (choice == null || !mounted) return;

    if (choice == 'csv') {
      await _importCsv();
      return;
    }

    final definition = await showDialog<_TableDef>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _NewTableDialog(),
    );
    if (definition == null || !mounted) return;

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

  /// Column editor: rename, delete and add columns of a table.
  /// Column TYPES of existing columns cannot be changed (SQLite
  /// limitation), but new columns can be TEXT, INTEGER (optionally with
  /// +/- buttons), REAL, DATUM or BOOLEAN. For existing integer columns
  /// the +/- buttons can be switched on and off.
  Future<void> _editColumns(String table) async {
    final db = DbService.instance.database;
    final recorded = DbService.instance.columnTypesFor(table);
    final existing = <_ExistingColumn>[
      for (final c in db.select('PRAGMA table_info(${_q(table)})'))
        _existingColumn(
          c['name'] as String,
          (c['type'] as String?) ?? '',
          recorded,
        ),
    ];

    final edits = await showDialog<_ColumnEdits>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditColumnsDialog(table: table, columns: existing),
    );
    if (edits == null || !mounted) return;

    try {
      // All-or-nothing: if one change fails, none of them is applied.
      db.execute('BEGIN');
      try {
        for (final column in existing) {
          final c = column.name;
          if (edits.deleted.contains(c)) {
            db.execute('ALTER TABLE ${_q(table)} DROP COLUMN ${_q(c)}');
            DbService.instance.deleteColumnType(table, c);
            continue;
          }
          var name = c;
          final renamed = edits.renames[c];
          if (renamed != null) {
            db.execute(
              'ALTER TABLE ${_q(table)} RENAME COLUMN ${_q(c)} TO ${_q(renamed)}',
            );
            // Move the recorded type along with the rename.
            final type = DbService.instance.columnType(table, c);
            if (type != null) {
              DbService.instance.deleteColumnType(table, c);
              DbService.instance.recordColumnType(table, renamed, type);
            }
            name = renamed;
          }
          final counter = edits.counters[c];
          if (counter != null) {
            DbService.instance.recordColumnType(
              table,
              name,
              counter ? 'COUNTER' : 'INTEGER',
            );
          }
        }
        for (final col in edits.newColumns) {
          db.execute(
            'ALTER TABLE ${_q(table)} ADD COLUMN ${_q(col.name)} '
            '${_sqliteTypes[col.type] ?? col.type}',
          );
          DbService.instance.recordColumnType(table, col.name, col.type);
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }

      // Rule checklists that use a renamed column follow the new name
      // (after COMMIT, so a rollback can never leave them out of sync).
      for (final e in edits.renames.entries) {
        ChecklistService.onColumnRenamed(table, e.key, e.value);
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
    final newName = await showTextPrompt(
      context,
      title: 'Tabelle "$table" umbenennen',
      label: 'Neuer Name',
      initial: table,
      confirmLabel: 'Umbenennen',
    );
    if (newName == null || newName.isEmpty || newName == table || !mounted) {
      return;
    }

    try {
      DbService.instance.database
          .execute('ALTER TABLE ${_q(table)} RENAME TO ${_q(newName)}');
      // Move the recorded DATUM/BOOLEAN/COUNTER types to the new name.
      DbService.instance.renameTableTypes(table, newName);
      // Rule checklists that use this table follow the new name.
      ChecklistService.onTableRenamed(table, newName);
      _loadTables();
    } catch (e) {
      _showError(e);
    }
  }
  /// Imports a CSV file as a new table. The column names are taken
  /// from the header row, the types are auto-detected and can be
  /// adjusted per column before creating the table.
  Future<void> _importCsv() async {
    final file = await FilePicker.pickFile(
      type: FileType.any, // FileType.custom is broken on Linux
    );
    if (file == null) return; // user cancelled

    // v13 loads content lazily - read the bytes explicitly.
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;

    final content = utf8.decode(bytes, allowMalformed: true);
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

    if (!mounted) return;
    final definition = await showModalBottomSheet<_TableDef>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CsvImportSheet(
        fileName: file.name,
        header: header,
        guessedTypes: types,
      ),
    );
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
          stmt.close();
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
  /// Imports a CSV file as a new table. The column names are taken
  /// from the header row, the types are auto-detected and can be
  /// adjusted per column before creating the table.
  // Future<void> _importCsv() async {
  //   final result = await FilePicker.platform.pickFiles(
  //     type: FileType.any,
  //     withData: true, // read the bytes directly (also needed on Linux)
  //   );
  //   final file = result?.files.single;
  //   if (file == null || file.bytes == null) return; // user cancelled

  //   final content = utf8.decode(file.bytes!, allowMalformed: true);
  //   final delim = _sniffDelimiter(content);
  //   final rows = _parseCsv(content, delim);
  //   if (rows.isEmpty) {
  //     _showError('Die CSV-Datei ist leer.');
  //     return;
  //   }

  //   final header = rows.first;
  //   final dataRows = rows.skip(1).toList();
  //   if (header.isEmpty || header.every((h) => h.trim().isEmpty)) {
  //     _showError('Die CSV-Datei hat keine gültige Kopfzeile.');
  //     return;
  //   }

  //   // Auto-detect a type for every column from its values.
  //   final types = <String>[];
  //   for (var i = 0; i < header.length; i++) {
  //     final values = dataRows
  //         .map((r) => i < r.length ? r[i].trim() : '')
  //         .toList();
  //     types.add(_guessType(values));
  //   }

  //   if (!mounted) return;
  //   final definition = await showModalBottomSheet<_TableDef>(
  //     context: context,
  //     isScrollControlled: true,
  //     showDragHandle: true,
  //     builder: (_) => _CsvImportSheet(
  //       fileName: file.name,
  //       header: header,
  //       guessedTypes: types,
  //     ),
  //   );
  //   if (definition == null) return;

  //   try {
  //     final db = DbService.instance.database;
  //     // All-or-nothing: build the table and insert everything inside
  //     // one transaction.
  //     db.execute('BEGIN');
  //     try {
  //       db.execute(definition.sql);
  //       final placeholders = List.filled(header.length, '?').join(', ');
  //       final insertSql =
  //           'INSERT INTO ${_q(definition.name)} VALUES ($placeholders)';
  //       // sqlite3's execute() takes no parameters - use a prepared
  //       // statement instead.
  //       final stmt = db.prepare(insertSql);
  //       try {
  //         for (final row in dataRows) {
  //           stmt.execute([
  //             for (var i = 0; i < header.length; i++)
  //               _convertValue(
  //                 i < row.length ? row[i].trim() : '',
  //                 definition.columns[i].type,
  //               ),
  //           ]);
  //         }
  //       } finally {
  //         stmt.dispose();
  //       }
  //       db.execute('COMMIT');
  //     } catch (_) {
  //       db.execute('ROLLBACK');
  //       rethrow;
  //     }
  //     // Remember DATUM/BOOLEAN choices for the date picker / checkbox UI.
  //     for (final col in definition.columns) {
  //       DbService.instance
  //           .recordColumnType(definition.name, col.name, col.type);
  //     }
  //     _loadTables();
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(
  //           content: Text(
  //             '"${definition.name}" importiert '
  //             '(${dataRows.length} Zeilen)',
  //           ),
  //         ),
  //       );
  //     }
  //   } catch (e) {
  //     _showError(e);
  //   }
  // }

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
      case 'COUNTER':
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

      final buffer = StringBuffer()
        ..writeln(columns.map(_csvEscape).join(';'));
      for (final row in rows) {
        buffer.writeln(
          columns.map((c) => _csvEscape(row[c]?.toString())).join(';'),
        );
      }

      final path = await FilePicker.saveFile(
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
  /// Exports the table content as a CSV file via a save-file dialog.
  // Future<void> _exportTable(String table) async {
  //   try {
  //     final db = DbService.instance.database;
  //     final columns = (db.select('PRAGMA table_info(${_q(table)})'))
  //         .map((c) => c['name'] as String)
  //         .toList();
  //     final rows = db.select('SELECT * FROM ${_q(table)}');

  //     // StringBuffer instead of `csv += ...` (which copies the whole
  //     // text for every row).
  //     final buffer = StringBuffer()
  //       ..writeln(columns.map(_csvEscape).join(';'));
  //     for (final row in rows) {
  //       buffer.writeln(
  //         columns.map((c) => _csvEscape(row[c]?.toString())).join(';'),
  //       );
  //     }

  //     final path = await FilePicker.platform.saveFile(
  //       fileName: '$table.csv',
  //       // utf8.encode (not codeUnits): umlauts must be written as UTF-8.
  //       bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
  //     );
  //     if (path == null) return; // user cancelled
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(content: Text('Exportiert nach: $path')),
  //       );
  //     }
  //   } catch (e) {
  //     _showError(e);
  //   }
  // }

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
      ChecklistService.onTableDropped(table);
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

// ---------------------------------------------------------------
// Dialogs and small widgets. Every dialog that has text fields is
// its own StatefulWidget: it creates its TextEditingControllers and
// disposes them in dispose() - the only safe moment, because by then
// the dialog is completely gone (disposing right after showDialog()
// returns can crash in debug mode while the closing animation runs).
// ---------------------------------------------------------------

/// A column the user is defining (new table or new column).
class _ColumnSpec {
  _ColumnSpec() : nameCtrl = TextEditingController();

  final TextEditingController nameCtrl;

  /// TEXT, INTEGER, REAL, DATUM or BOOLEAN (what the dropdown shows).
  String baseType = 'TEXT';

  /// "+/- buttons" checkbox; only meaningful for INTEGER.
  bool counter = false;

  String get name => nameCtrl.text.trim();

  /// The type the app records: INTEGER + checkbox = COUNTER.
  String get appType =>
      (baseType == 'INTEGER' && counter) ? 'COUNTER' : baseType;

  /// The type SQLite gets in CREATE/ALTER TABLE.
  String get sqlType => _sqliteTypes[appType] ?? appType;

  void dispose() => nameCtrl.dispose();
}

/// A column that already exists in a table (for the column editor).
class _ExistingColumn {
  const _ExistingColumn({
    required this.name,
    required this.canCounter,
    required this.counter,
  });

  final String name;

  /// True for integer columns: only they can have +/- buttons.
  final bool canCounter;

  /// True if the +/- buttons are currently switched on.
  final bool counter;
}

_ExistingColumn _existingColumn(
  String name,
  String sqlType,
  Map<String, String> recorded,
) {
  final app = recorded[name];
  final canCounter = app == null
      ? sqlType.toUpperCase().contains('INT')
      : (app == 'INTEGER' || app == 'COUNTER');
  return _ExistingColumn(
    name: name,
    canCounter: canCounter,
    counter: app == 'COUNTER',
  );
}

/// What the column editor dialog hands back.
class _ColumnEdits {
  const _ColumnEdits({
    required this.deleted,
    required this.renames,
    required this.counters,
    required this.newColumns,
  });

  /// Existing columns to drop.
  final Set<String> deleted;

  /// Old name -> new name.
  final Map<String, String> renames;

  /// Existing column -> +/- buttons switched on (true) or off (false).
  /// Only contains columns where the setting was changed.
  final Map<String, bool> counters;

  /// Columns to add (name + app type).
  final List<_ColumnDef> newColumns;
}

/// Type dropdown used in all column dialogs.
class _TypeDropdown extends StatelessWidget {
  const _TypeDropdown({required this.type, required this.onChanged});

  final String type;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: type,
      items: _typeItems,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

/// The "+/- buttons" checkbox shown below INTEGER columns.
class _CounterCheckbox extends StatelessWidget {
  const _CounterCheckbox({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      title: const Text('Plus-/Minus-Buttons in der Tabelle'),
      subtitle: const Text('Wert direkt um 1 erhöhen oder verringern'),
    );
  }
}

/// "New table" dialog: table name plus a list of columns.
class _NewTableDialog extends StatefulWidget {
  const _NewTableDialog();

  @override
  State<_NewTableDialog> createState() => _NewTableDialogState();
}

class _NewTableDialogState extends State<_NewTableDialog> {
  final _nameCtrl = TextEditingController();
  final List<_ColumnSpec> _columns = [_ColumnSpec()];

  /// Removed columns: disposed together with the dialog (not earlier,
  /// their text fields are still on screen until the next rebuild).
  final List<_ColumnSpec> _retired = [];

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
    if (name.isEmpty) return;
    final specs = _columns.where((c) => c.name.isNotEmpty).toList();
    if (specs.isEmpty) return;

    // DATUM, BOOLEAN and COUNTER have no native SQLite types: dates
    // are stored as TEXT (ISO format), booleans and counters as INTEGER.
    final colDefs = specs.map((c) => '${_q(c.name)} ${c.sqlType}').join(', ');
    Navigator.pop<_TableDef>(context, (
      name: name,
      sql: 'CREATE TABLE ${_q(name)} ($colDefs)',
      columns: [for (final c in specs) (name: c.name, type: c.appType)],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Neue Tabelle erstellen'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Tabellenname',
                hintText: 'z.B. items',
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _columns.length,
                itemBuilder: (context, i) {
                  final col = _columns[i];
                  return Column(
                    // The key ties the dropdown's state to THIS column
                    // (otherwise removing a column shows wrong types).
                    key: ObjectKey(col),
                    children: [
                      Row(
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
                            child: _TypeDropdown(
                              type: col.baseType,
                              onChanged: (v) => setState(() {
                                col.baseType = v;
                                if (v != 'INTEGER') col.counter = false;
                              }),
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
                      ),
                      if (col.baseType == 'INTEGER')
                        _CounterCheckbox(
                          value: col.counter,
                          onChanged: (v) => setState(() => col.counter = v),
                        ),
                    ],
                  );
                },
              ),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _columns.add(_ColumnSpec())),
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

/// Column editor dialog: rename / delete existing columns, switch
/// +/- buttons on integer columns, add new columns.
class _EditColumnsDialog extends StatefulWidget {
  const _EditColumnsDialog({required this.table, required this.columns});

  final String table;
  final List<_ExistingColumn> columns;

  @override
  State<_EditColumnsDialog> createState() => _EditColumnsDialogState();
}

class _EditColumnsDialogState extends State<_EditColumnsDialog> {
  late final Map<String, TextEditingController> _renameCtrl = {
    for (final c in widget.columns)
      c.name: TextEditingController(text: c.name),
  };
  late final Map<String, bool> _counters = {
    for (final c in widget.columns) c.name: c.counter,
  };
  final Set<String> _deleted = {};
  final List<_ColumnSpec> _newColumns = [];
  final List<_ColumnSpec> _retired = [];

  @override
  void dispose() {
    for (final c in _renameCtrl.values) {
      c.dispose();
    }
    for (final c in _newColumns) {
      c.dispose();
    }
    for (final c in _retired) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final renames = <String, String>{};
    final counters = <String, bool>{};
    for (final c in widget.columns) {
      if (_deleted.contains(c.name)) continue;
      final newName = _renameCtrl[c.name]!.text.trim();
      if (newName.isNotEmpty && newName != c.name) renames[c.name] = newName;
      final counter = _counters[c.name] ?? false;
      if (c.canCounter && counter != c.counter) counters[c.name] = counter;
    }
    Navigator.pop<_ColumnEdits>(
      context,
      _ColumnEdits(
        deleted: {..._deleted},
        renames: renames,
        counters: counters,
        newColumns: [
          for (final c in _newColumns)
            if (c.name.isNotEmpty) (name: c.name, type: c.appType),
        ],
      ),
    );
  }

  Widget _existingRow(_ExistingColumn c) {
    final deleted = _deleted.contains(c.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _renameCtrl[c.name],
                  enabled: !deleted,
                  decoration: InputDecoration(
                    labelText: c.name,
                    labelStyle: deleted
                        ? const TextStyle(
                            decoration: TextDecoration.lineThrough,
                          )
                        : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: deleted ? 'Löschen rückgängig' : 'Spalte löschen',
                icon: Icon(deleted ? Icons.undo : Icons.delete_outline),
                onPressed: () => setState(() {
                  if (!_deleted.remove(c.name)) _deleted.add(c.name);
                }),
              ),
            ],
          ),
          if (c.canCounter && !deleted)
            _CounterCheckbox(
              value: _counters[c.name] ?? false,
              onChanged: (v) => setState(() => _counters[c.name] = v),
            ),
        ],
      ),
    );
  }

  Widget _newRow(int i, _ColumnSpec col) {
    return Padding(
      key: ObjectKey(col),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Row(
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
                child: _TypeDropdown(
                  type: col.baseType,
                  onChanged: (v) => setState(() {
                    col.baseType = v;
                    if (v != 'INTEGER') col.counter = false;
                  }),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _newColumns.remove(col);
                  _retired.add(col);
                }),
              ),
            ],
          ),
          if (col.baseType == 'INTEGER')
            _CounterCheckbox(
              value: col.counter,
              onChanged: (v) => setState(() => col.counter = v),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Spalten von "${widget.table}" bearbeiten'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Bestehende Spalten:'),
              for (final c in widget.columns) _existingRow(c),
              const Divider(),
              const Text('Neue Spalten:'),
              for (final (i, col) in _newColumns.indexed) _newRow(i, col),
              TextButton.icon(
                onPressed: () => setState(() => _newColumns.add(_ColumnSpec())),
                icon: const Icon(Icons.add),
                label: const Text('Spalte hinzufügen'),
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

/// CSV import sheet: table name plus one type dropdown per CSV column,
/// pre-filled with the auto-detected type.
class _CsvImportSheet extends StatefulWidget {
  const _CsvImportSheet({
    required this.fileName,
    required this.header,
    required this.guessedTypes,
  });

  final String fileName;
  final List<String> header;
  final List<String> guessedTypes;

  @override
  State<_CsvImportSheet> createState() => _CsvImportSheetState();
}

class _CsvImportSheetState extends State<_CsvImportSheet> {
  final _nameCtrl = TextEditingController();
  late final List<String> _columnNames;
  late final List<String> _types; // TEXT, INTEGER, REAL, DATUM, BOOLEAN
  late final List<bool> _counters; // +/- buttons per column

  @override
  void initState() {
    super.initState();
    // Suggest the file name (without extension) as table name.
    _nameCtrl.text = widget.fileName
        .replaceAll(RegExp(r'\.csv$', caseSensitive: false), '')
        .trim();

    _types = [...widget.guessedTypes];
    _counters = List.filled(widget.header.length, false);

    // Make duplicate/empty column names unique.
    final usedNames = <String>{};
    final names = <String>[];
    for (final h in widget.header) {
      var name = h.trim();
      if (name.isEmpty) name = 'Spalte';
      var candidate = name;
      var n = 2;
      while (usedNames.contains(candidate)) {
        candidate = '$name $n';
        n++;
      }
      usedNames.add(candidate);
      names.add(candidate);
    }
    _columnNames = names;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _import() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final columns = <_ColumnDef>[
      for (var i = 0; i < _columnNames.length; i++)
        (
          name: _columnNames[i],
          type: (_types[i] == 'INTEGER' && _counters[i]) ? 'COUNTER' : _types[i],
        ),
    ];
    final colDefs = columns
        .map((c) => '${_q(c.name)} ${_sqliteTypes[c.type] ?? c.type}')
        .join(', ');
    Navigator.pop<_TableDef>(context, (
      name: name,
      sql: 'CREATE TABLE ${_q(name)} ($colDefs)',
      columns: columns,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Tabellenname'),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _columnNames.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            _columnNames[i],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: _TypeDropdown(
                            type: _types[i],
                            onChanged: (v) => setState(() {
                              _types[i] = v;
                              if (v != 'INTEGER') _counters[i] = false;
                            }),
                          ),
                        ),
                      ],
                    ),
                    if (_types[i] == 'INTEGER')
                      _CounterCheckbox(
                        value: _counters[i],
                        onChanged: (v) => setState(() => _counters[i] = v),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.check),
            label: const Text('Importieren'),
          ),
        ],
      ),
    );
  }
}
