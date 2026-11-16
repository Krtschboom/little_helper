import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show Database;

import '../services/db_service.dart';

/// Formats a date the way it is stored in the database (ISO, TEXT).
String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Shows the content of one table; cells can be edited, rows can be
/// added and deleted. Rows are identified via SQLite's built-in rowid.
///
/// Performance notes:
///  * Search text and sort keys are computed once per data load, and
///    the filtered/sorted list is cached in [_visible] (not rebuilt
///    on every build()).
///  * The table is a lazy ListView, so only the rows on screen are
///    built (DataTable builds ALL rows, which is what made it slow).
class TableEditorScreen extends StatefulWidget {
  const TableEditorScreen({super.key, required this.table});

  final String table;

  @override
  State<TableEditorScreen> createState() => _TableEditorScreenState();
}

class _TableEditorScreenState extends State<TableEditorScreen> {
  // Fixed layout of the lazy table.
  static const _colWidth = 180.0;
  static const _actionWidth = 56.0;
  static const _rowHeight = 48.0;

  /// Name of the extra column that carries SQLite's rowid.
  static const _ridKey = '__rid';

  List<String> _columns = [];

  /// Column -> declared SQLite type, UPPERCASE ('INTEGER', 'TEXT', ...).
  Map<String, String> _sqlTypes = {};

  /// Column -> app display type ('DATUM', 'BOOLEAN', or the SQLite type).
  Map<String, String> _appTypes = {};

  List<Map<String, Object?>> _rows = [];

  /// Lowercased text of every row (parallel to [_rows]) for searching.
  List<String> _haystack = [];

  /// [_rows] after search and sort. This is what the table shows.
  List<Map<String, Object?>> _visible = [];

  String? _error;
  String _search = '';
  String? _sortColumn;
  bool _sortAscending = true;
  Timer? _debounce;
  final _searchCtrl = TextEditingController();

  Database get _db => DbService.instance.database;
  String get _table => DbService.quoteIdentifier(widget.table);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // --- Loading ------------------------------------------------

  void _reload() {
    try {
      final info = _db.select('PRAGMA table_info($_table)');
      final columns = <String>[];
      final sqlTypes = <String, String>{};
      for (final c in info) {
        final name = c['name'] as String;
        final type = ((c['type'] as String?) ?? '').trim().toUpperCase();
        columns.add(name);
        sqlTypes[name] = type.isEmpty ? 'TEXT' : type;
      }

      // One query for all recorded app types instead of one per call.
      final recorded = DbService.instance.columnTypesFor(widget.table);
      final appTypes = {
        for (final c in columns)
          c: recorded[c] ?? _guessAppType(c, sqlTypes[c]!),
      };

      final rows = [
        for (final r in _db.select('SELECT rowid AS $_ridKey, * FROM $_table'))
          Map<String, Object?>.from(r),
      ];

      setState(() {
        _columns = columns;
        _sqlTypes = sqlTypes;
        _appTypes = appTypes;
        _rows = rows;
        _haystack = [for (final r in rows) _haystackOf(r)];
        _error = null;
        _applyView();
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  /// Updates one row in memory after an edit (instead of reloading
  /// the whole table).
  void _refreshRow(int rowid) {
    final i = _rows.indexWhere((r) => r[_ridKey] == rowid);
    if (i < 0) {
      _reload();
      return;
    }
    final fresh = _db.select(
      'SELECT rowid AS $_ridKey, * FROM $_table WHERE rowid = ?',
      [rowid],
    );
    if (fresh.isEmpty) {
      _reload();
      return;
    }
    final row = Map<String, Object?>.from(fresh.first);
    setState(() {
      _rows[i] = row;
      _haystack[i] = _haystackOf(row);
      _applyView();
    });
  }

  /// App display type of a column when nothing was recorded: guess
  /// from the column name (tables created outside the app), otherwise
  /// the raw SQLite type.
  String _guessAppType(String column, String sqlType) {
    final lower = column.toLowerCase();
    if (lower.contains('datum') ||
        lower.contains('date') ||
        lower.contains('geburtstag') ||
        lower == 'tag') {
      return 'DATUM';
    }
    if (lower.contains('bool') ||
        lower.startsWith('is_') ||
        lower.startsWith('ist_') ||
        lower.startsWith('has_') ||
        lower.startsWith('hat_')) {
      return 'BOOLEAN';
    }
    return sqlType;
  }

  // --- Search and sort ----------------------------------------

  /// All cell texts of a row in one lowercase string. The \u0000
  /// separator keeps a search from matching across two cells.
  String _haystackOf(Map<String, Object?> row) {
    return _columns.map((c) => row[c]?.toString() ?? '').join('\u0000').toLowerCase();
  }

  /// Sort key of a cell: (number or null, lowercase text). Numbers
  /// compare numerically, everything else as text; null = NULL.
  (num?, String)? _sortKey(Object? v) {
    if (v == null) return null;
    final s = v.toString();
    return (v is num ? v : num.tryParse(s), s.toLowerCase());
  }

  /// Rebuilds [_visible] from [_rows]. Call it inside setState whenever
  /// the rows, the search text or the sorting change.
  void _applyView() {
    final query = _search.trim().toLowerCase();
    final idx = <int>[
      for (var i = 0; i < _rows.length; i++)
        if (query.isEmpty || _haystack[i].contains(query)) i,
    ];

    final col = _sortColumn;
    if (col != null && _columns.contains(col)) {
      // Compute every sort key once, not once per comparison.
      final keys = <(num?, String)?>[for (final r in _rows) _sortKey(r[col])];
      idx.sort((a, b) {
        final ka = keys[a];
        final kb = keys[b];
        if (ka == null && kb == null) return 0;
        if (ka == null) return 1; // NULLs last
        if (kb == null) return -1;
        final (na, sa) = ka;
        final (nb, sb) = kb;
        final cmp =
            (na != null && nb != null) ? na.compareTo(nb) : sa.compareTo(sb);
        return _sortAscending ? cmp : -cmp;
      });
    }
    _visible = [for (final i in idx) _rows[i]];
  }

  void _onSearchChanged(String value) {
    // Wait until the user pauses typing before filtering.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _search = value;
        _applyView();
      });
    });
  }

  void _setSort(String column, bool ascending) {
    setState(() {
      _sortColumn = column;
      _sortAscending = ascending;
      _applyView();
    });
  }

  // --- Editing ------------------------------------------------

  /// Tries to convert the input text to a value matching the column type.
  Object? _parse(String value, String column) {
    if (value == 'NULL') return null;
    final type = _sqlTypes[column] ?? 'TEXT';
    if (type.contains('INT')) {
      return int.tryParse(value) ?? value;
    }
    if (type.contains('REAL') ||
        type.contains('FLOA') ||
        type.contains('DOUB')) {
      return double.tryParse(value.replaceAll(',', '.')) ?? value;
    }
    return value;
  }

  bool _asBool(Object? value) =>
      value == 1 || value == '1' || value == 'true' || value == 'ja';

  Future<void> _editCell(Map<String, Object?> row, String column) async {
    final rowid = row[_ridKey] as int;
    final current = row[column];
    final type = _appTypes[column] ?? 'TEXT';

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
      final text = await showDialog<String>(
        context: context,
        builder: (_) => _EditTextDialog(
          title: '$column bearbeiten',
          initial: current?.toString() ?? '',
        ),
      );
      if (text == null) return; // cancelled
      newValue = text.isEmpty ? null : _parse(text, column);
    }

    if (!mounted) return;
    try {
      _db.execute(
        'UPDATE $_table SET ${DbService.quoteIdentifier(column)} = ? '
        'WHERE rowid = ?',
        [newValue, rowid],
      );
      _refreshRow(rowid);
    } catch (e) {
      _showError(e);
    }
  }

  /// [-] / [+] buttons of a COUNTER column: changes the value by
  /// [delta] (NULL counts as 0). Only this one row is updated; the
  /// list is NOT re-sorted, so the row does not jump around while you
  /// keep pressing the button.
  void _stepCell(Map<String, Object?> row, String column, int delta) {
    final rowid = row[_ridKey] as int;
    final col = DbService.quoteIdentifier(column);
    try {
      _db.execute(
        'UPDATE $_table SET $col = COALESCE($col, 0) + ? WHERE rowid = ?',
        [delta, rowid],
      );
      final fresh = _db.select(
        'SELECT $col AS v FROM $_table WHERE rowid = ?',
        [rowid],
      );
      if (fresh.isEmpty) return;
      row[column] = fresh.first['v'];
      final i = _rows.indexOf(row);
      setState(() {
        if (i >= 0) _haystack[i] = _haystackOf(row);
      });
    } catch (e) {
      _showError(e);
    }
  }

  /// Converts what the add-row dialog returned into the value that is
  /// inserted for [column].
  Object? _valueForInsert(String column, Object? raw) {
    final type = _appTypes[column];
    if (type == 'BOOLEAN') return (raw as bool) ? 1 : 0;
    if (type == 'DATUM') {
      return raw == null ? null : _formatDate(raw as DateTime);
    }
    final text = raw as String;
    return text.isEmpty ? null : _parse(text, column);
  }

  /// Opens a form dialog listing one field per column of the table;
  /// filled values are inserted as a new row. DATUM columns get a
  /// calendar picker, BOOLEAN columns a switch.
  Future<void> _addRow() async {
    if (_error != null) return;

    final values = await showDialog<Map<String, Object?>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddRowDialog(
        table: widget.table,
        columns: _columns,
        types: _appTypes,
      ),
    );
    if (values == null || !mounted) return;

    try {
      final colSql = _columns.map(DbService.quoteIdentifier).join(', ');
      final placeholders = _columns.map((_) => '?').join(', ');
      final params = <Object?>[
        for (final c in _columns) _valueForInsert(c, values[c]),
      ];
      _db.execute(
        'INSERT INTO $_table ($colSql) VALUES ($placeholders)',
        params,
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
        content:
            const Text('Diese Aktion kann nicht rückgängig gemacht werden.'),
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
    if (confirmed != true || !mounted) return;

    try {
      _db.execute('DELETE FROM $_table WHERE rowid = ?', [rowid]);
      setState(() {
        final i = _rows.indexWhere((r) => r[_ridKey] == rowid);
        if (i >= 0) {
          _rows.removeAt(i);
          _haystack.removeAt(i);
        }
        _applyView();
      });
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

  // --- UI -----------------------------------------------------

  Widget _buildHeader() {
    return SizedBox(
      height: _rowHeight,
      child: Row(
        children: [
          for (final c in _columns)
            Tooltip(
              message: 'Klicken zum Sortieren',
              child: InkWell(
                onTap: () =>
                    _setSort(c, _sortColumn == c ? !_sortAscending : true),
                child: SizedBox(
                  width: _colWidth,
                  height: _rowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            c,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (_sortColumn == c)
                          Icon(
                            _sortAscending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: 16,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: _actionWidth),
        ],
      ),
    );
  }

  /// One cell. COUNTER columns show  [-]  value  [+]  (tap the value
  /// to type a number); all other cells open the editor on tap.
  Widget _buildCell(Map<String, Object?> row, String column) {
    final text = row[column]?.toString() ?? 'NULL';

    if (_appTypes[column] == 'COUNTER') {
      return SizedBox(
        width: _colWidth,
        height: _rowHeight,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Um 1 verringern',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove),
              onPressed: () => _stepCell(row, column, -1),
            ),
            Expanded(
              child: InkWell(
                onTap: () => _editCell(row, column),
                child: Center(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Um 1 erhöhen',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add),
              onPressed: () => _stepCell(row, column, 1),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: () => _editCell(row, column),
      child: Container(
        width: _colWidth,
        height: _rowHeight,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _buildRow(Map<String, Object?> row) {
    final rowid = row[_ridKey] as int;
    return Row(
      children: [
        for (final c in _columns) _buildCell(row, c),
        SizedBox(
          width: _actionWidth,
          child: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteRow(rowid),
          ),
        ),
      ],
    );
  }

  /// Horizontal scroll for wide tables; the rows themselves are a
  /// lazy ListView, and the header stays pinned above them.
  Widget _buildTable() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: _columns.length * _colWidth + _actionWidth,
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemExtent: _rowHeight, // fixed height = cheap layout
                padding: const EdgeInsets.only(bottom: 88), // room for the FAB
                itemCount: _visible.length,
                itemBuilder: (context, i) => _buildRow(_visible[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.table)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
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
                          _debounce?.cancel();
                          _searchCtrl.clear();
                          setState(() {
                            _search = '';
                            _applyView();
                          });
                        },
                      ),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRow,
        icon: const Icon(Icons.add),
        label: const Text('Zeile'),
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Keine Einträge.'))
          : _visible.isEmpty
              ? const Center(child: Text('Kein Treffer für die Suche.'))
              : _buildTable(),
    );
  }
}

/// Dialog for editing one text/number cell. Its own widget so that it
/// owns and disposes the controller safely.
class _EditTextDialog extends StatefulWidget {
  const _EditTextDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_EditTextDialog> createState() => _EditTextDialogState();
}

class _EditTextDialogState extends State<_EditTextDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'NULL eingeben für einen leeren Wert',
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

/// Form dialog for a new row: one field per column. Returns a map
/// column -> raw value (String for text, bool for BOOLEAN columns,
/// DateTime? for DATUM columns), or null if cancelled.
class _AddRowDialog extends StatefulWidget {
  const _AddRowDialog({
    required this.table,
    required this.columns,
    required this.types,
  });

  final String table;
  final List<String> columns;
  final Map<String, String> types;

  @override
  State<_AddRowDialog> createState() => _AddRowDialogState();
}

class _AddRowDialogState extends State<_AddRowDialog> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, bool> _bools = {};
  final Map<String, DateTime?> _dates = {};

  @override
  void initState() {
    super.initState();
    for (final c in widget.columns) {
      switch (widget.types[c]) {
        case 'BOOLEAN':
          _bools[c] = false;
        case 'DATUM':
          _dates[c] = null;
        default:
          _text[c] = TextEditingController();
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final result = <String, Object?>{};
    for (final c in widget.columns) {
      if (_bools.containsKey(c)) {
        result[c] = _bools[c];
      } else if (_dates.containsKey(c)) {
        result[c] = _dates[c];
      } else {
        result[c] = _text[c]!.text;
      }
    }
    Navigator.pop(context, result);
  }

  Future<void> _pickDate(String column) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dates[column] ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _dates[column] = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Neuer Eintrag in ${widget.table}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in widget.columns)
                if (_bools.containsKey(c))
                  SwitchListTile(
                    title: Text(c),
                    value: _bools[c] ?? false,
                    onChanged: (v) => setState(() => _bools[c] = v),
                  )
                else if (_dates.containsKey(c))
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
                              _dates[c] == null ? '—' : _formatDate(_dates[c]!),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Datum wählen',
                          icon: const Icon(Icons.calendar_month),
                          onPressed: () => _pickDate(c),
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: TextField(
                      controller: _text[c],
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
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Hinzufügen'),
        ),
      ],
    );
  }
}
