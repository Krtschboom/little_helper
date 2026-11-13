import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show Database;

import '../services/db_service.dart';

/// Shows the content of one table; cells can be edited, rows can be
/// added and deleted. Rows are identified via SQLite's built-in rowid.
class TableEditorScreen extends StatefulWidget {
  const TableEditorScreen({super.key, required this.table});

  final String table;

  @override
  State<TableEditorScreen> createState() => _TableEditorScreenState();
}

class _TableEditorScreenState extends State<TableEditorScreen> {
  List<String> _columns = [];
  List<Map<String, Object?>> _rows = [];
  String? _error;
  String _search = '';
  String? _sortColumn;
  bool _sortAscending = true;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Database get _db => DbService.instance.database;
  String get _table => '"${widget.table}"';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    try {
      final info = _db.select('PRAGMA table_info($_table)');
      final rows = _db
          .select('SELECT rowid AS _rowid_, * FROM $_table')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      setState(() {
        _columns = info.map((c) => c['name'] as String).toList();
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  /// Tries to convert the input text to a value matching the column type.
  Object? _parse(String? value, String column) {
    if (value == null || value == 'NULL') return null;
    final type = _columnType(column);
    if (type.contains('INT')) {
      return int.tryParse(value) ?? value;
    }
    if (type.contains('REAL') || type.contains('FLOA') || type.contains('DOUB')) {
      return double.tryParse(value) ?? value;
    }
    return value;
  }

  String _columnType(String column) {
    final info = _db.select('PRAGMA table_info($_table)');
    for (final c in info) {
      if (c['name'] == column) return (c['type'] as String?) ?? 'TEXT';
    }
    return 'TEXT';
  }

  /// App display type of a column ('DATUM', 'BOOLEAN', ...) if known,
  /// otherwise a name-based heuristic, otherwise the raw SQLite type.
  String _appType(String column) {
    final recorded = DbService.instance
        .columnType(widget.table, column);
    if (recorded != null) return recorded;

    // Fallback for tables created outside the app: guess from the
    // column name. Only used when no type was recorded.
    final lower = column.toLowerCase();
    if (lower.contains('datum') || lower.contains('date') ||
        lower.contains('geburtstag') || lower == 'tag') {
      return 'DATUM';
    }
    if (lower.contains('bool') || lower.startsWith('is_') ||
        lower.startsWith('ist_') || lower.startsWith('has_') ||
        lower.startsWith('hat_')) {
      return 'BOOLEAN';
    }
    return _columnType(column);
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  bool _asBool(Object? value) =>
      value == 1 || value == '1' || value == 'true' || value == 'ja';

  Future<void> _editCell(int rowid, String column) async {
    final row =
        _rows.firstWhere((r) => r['_rowid_'] == rowid, orElse: () => {});
    final current = row[column];
    final type = _appType(column);

    Object? newValue;
    if (type == 'BOOLEAN') {
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$column bearbeiten'),
          content: SwitchListTile(
            title: const Text('Ja / Nein'),
            value: _asBool(current),
            onChanged: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
          ],
        ),
      );
      if (result == null) return; // cancelled
      newValue = result ? 1 : 0;
    } else if (type == 'DATUM') {
      final initial =
          DateTime.tryParse(current?.toString() ?? '') ?? DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(1900),
        lastDate: DateTime(2100),
      );
      if (picked == null) return; // cancelled
      newValue = _formatDate(picked);
    } else {
      final controller =
          TextEditingController(text: current?.toString() ?? '');
      final text = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$column bearbeiten'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'NULL eingeben für einen leeren Wert',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Speichern'),
            ),
          ],
        ),
      );
      if (text == null) return; // cancelled
      newValue = text.isEmpty ? null : _parse(text, column);
    }

    try {
      _db.execute(
        'UPDATE $_table SET "$column" = ? WHERE rowid = ?',
        [newValue, rowid],
      );
      _reload();
    } catch (e) {
      _showError(e);
    }
  }

  /// Opens a form dialog listing one field per column title of the
  /// table; filled values are inserted as a new row. DATUM columns
  /// get a calendar picker, BOOLEAN columns a checkbox.
  Future<void> _addRow() async {
    if (_error != null) return;

    final types = {for (final c in _columns) c: _appType(c)};
    final textControllers = <String, TextEditingController>{
      for (final c in _columns)
        if (types[c] != 'DATUM' && types[c] != 'BOOLEAN')
          c: TextEditingController(),
    };
    final boolValues = <String, bool>{
      for (final c in _columns)
        if (types[c] == 'BOOLEAN') c: false,
    };
    final dateValues = <String, DateTime?>{
      for (final c in _columns)
        if (types[c] == 'DATUM') c: null,
    };

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Neuer Eintrag in ${widget.table}'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in _columns)
                    if (types[c] == 'BOOLEAN')
                      SwitchListTile(
                        title: Text(c),
                        value: boolValues[c] ?? false,
                        onChanged: (v) =>
                            setDialogState(() => boolValues[c] = v),
                      )
                    else if (types[c] == 'DATUM')
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: c,
                                  helperText: 'Leer lassen = NULL',
                                ),
                                child: Text(
                                  dateValues[c] == null
                                      ? '—'
                                      : _formatDate(dateValues[c]!),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Datum wählen',
                              icon: const Icon(Icons.calendar_month),
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: dateValues[c] ??
                                      DateTime.now(),
                                  firstDate: DateTime(1900),
                                  lastDate: DateTime(2100),
                                );
                                if (picked != null) {
                                  setDialogState(() => dateValues[c] = picked);
                                }
                              },
                            ),
                          ],
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: TextField(
                          controller: textControllers[c],
                          decoration: InputDecoration(
                            labelText: c,
                            helperText: 'Leer lassen = NULL',
                          ),
                        ),
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
              child: const Text('Hinzufügen'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      textControllers.values.forEach((c) => c.dispose());
      return;
    }

    try {
      final colSql = _columns.map((c) => '"$c"').join(', ');
      final placeholders = _columns.map((_) => '?').join(', ');
      final values = _columns.map((c) {
        if (types[c] == 'BOOLEAN') return boolValues[c]! ? 1 : 0;
        if (types[c] == 'DATUM') {
          final d = dateValues[c];
          return d == null ? null : _formatDate(d);
        }
        final text = textControllers[c]!.text;
        return text.isEmpty ? null : _parse(text, c);
      }).toList();
      textControllers.values.forEach((c) => c.dispose());

      _db.execute(
        'INSERT INTO $_table ($colSql) VALUES ($placeholders)',
        values,
      );
      _reload();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _deleteRow(int rowid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Zeile löschen?'),
        content: const Text('Diese Aktion kann nicht rückgängig gemacht werden.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      _db.execute('DELETE FROM $_table WHERE rowid = ?', [rowid]);
      _reload();
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
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

  /// Rows filtered by the search text and sorted by the selected
  /// column (if any). Sorting compares numbers numerically and
  /// everything else as lowercase text; NULL always comes last.
  List<Map<String, Object?>> get _visibleRows {
    Iterable<Map<String, Object?>> rows = _rows;
    final query = _search.trim().toLowerCase();
    if (query.isNotEmpty) {
      rows = rows.where((row) => _columns.any(
          (c) => (row[c]?.toString() ?? '').toLowerCase().contains(query)));
    }
    final col = _sortColumn;
    if (col == null || !_columns.contains(col)) return rows.toList();

    final sorted = [...rows]..sort((a, b) {
        final av = a[col];
        final bv = b[col];
        if (av == null && bv == null) return 0;
        if (av == null) return 1; // NULLs last
        if (bv == null) return -1;
        final an = num.tryParse(av.toString());
        final bn = num.tryParse(bv.toString());
        final cmp = (an != null && bn != null)
            ? an.compareTo(bn)
            : av.toString().toLowerCase().compareTo(
                bv.toString().toLowerCase());
        return _sortAscending ? cmp : -cmp;
      });
    return sorted;
  }

  void _setSort(String column, bool ascending) {
    setState(() {
      _sortColumn = column;
      _sortAscending = ascending;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.table)),
        body: Center(child: Text(_error!, style: const TextStyle(color: Colors.red))),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.table),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'In allen Spalten suchen...',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Suche löschen',
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRow,
        icon: const Icon(Icons.add),
        label: const Text('Zeile'),
      ),
      body: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Keine Einträge.'),
                )
              : _visibleRows.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Kein Treffer für die Suche.'),
                    )
                  : DataTable(
                      columns: [
                        ..._columns.map(
                          (c) => DataColumn(
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(c),
                                if (_sortColumn == c)
                                  Icon(
                                    _sortAscending
                                        ? Icons.arrow_upward
                                        : Icons.arrow_downward,
                                    size: 16,
                                  ),
                              ],
                            ),
                            tooltip: 'Klicken zum Sortieren',
                            onSort: (i, _) => _setSort(
                              c,
                              // DataTable always passes ascending=true
                              // when sortColumnIndex is unset, so we
                              // toggle the direction ourselves.
                              _sortColumn == c ? !_sortAscending : true,
                            ),
                          ),
                        ),
                        const DataColumn(label: Text('')), // delete
                      ],
                      rows: _visibleRows.map((row) {
                    final rowid = row['_rowid_'] as int;
                    return DataRow(
                      cells: [
                        ..._columns.map(
                          (c) => DataCell(
                            InkWell(
                              onTap: () => _editCell(rowid, c),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 200,
                                ),
                                child: Text(
                                  row[c]?.toString() ?? 'NULL',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ),
                        DataCell(
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteRow(rowid),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
        ),
      ),
    );
  }
}