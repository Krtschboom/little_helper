import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' show Database;

import 'db_service.dart';
import 'rule_engine.dart';

// ===============================================================
// Checklist storage. Everything lives inside the (encrypted) SQLite
// file in three internal tables (names start with `_app_`, so the
// Inventory screen does not list them):
//
//   _app_checklists        one row per checklist (name, type, config)
//   _app_checklist_items   the entries of NORMAL checklists
//   _app_checklist_checks  the ticked rows of RULE checklists
// ===============================================================

enum ChecklistType { manual, rule }

/// A checklist as stored in `_app_checklists`.
class Checklist {
  Checklist({
    required this.id,
    required this.name,
    required this.type,
    required this.config,
  });

  final int id;
  final String name;
  final ChecklistType type;

  /// Normal list: `{"columns": ["Artikel", "Menge"]}`
  /// Rule list:   `{"sources": [ <RuleSet as JSON>, ... ]}`
  final Map<String, dynamic> config;

  /// Column names of a normal checklist.
  List<String> get columns => [
        for (final c in (config['columns'] as List? ?? const [])) c as String,
      ];

  /// Linked tables + rules of a rule checklist.
  List<RuleSet> get sources => [
        for (final s in (config['sources'] as List? ?? const []))
          RuleSet.fromJson(s as Map<String, dynamic>),
      ];
}

/// One entry of a normal checklist.
class ManualItem {
  const ManualItem({
    required this.id,
    required this.checked,
    required this.cells,
  });

  final int id;
  final bool checked;

  /// One text per column of the checklist.
  final List<String> cells;
}

class ChecklistService {
  ChecklistService._();

  static Database? _readyDb;

  /// The open database; creates the internal tables the first time
  /// it is used for a database.
  static Database get _db {
    final db = DbService.instance.database;
    if (!identical(_readyDb, db)) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS _app_checklists (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          config TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS _app_checklist_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          checklist_id INTEGER NOT NULL,
          position INTEGER NOT NULL,
          checked INTEGER NOT NULL DEFAULT 0,
          cells TEXT NOT NULL
        )
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS _app_checklist_checks (
          checklist_id INTEGER NOT NULL,
          table_name TEXT NOT NULL,
          row_id INTEGER NOT NULL,
          PRIMARY KEY (checklist_id, table_name, row_id)
        )
      ''');
      _readyDb = db;
    }
    return db;
  }

  // --- Checklists ---------------------------------------------

  static Checklist _fromRow(Map<String, Object?> r) => Checklist(
        id: r['id'] as int,
        name: r['name'] as String,
        type: r['type'] == 'rule' ? ChecklistType.rule : ChecklistType.manual,
        config: jsonDecode(r['config'] as String) as Map<String, dynamic>,
      );

  static List<Checklist> all() {
    final rows = _db.select(
      'SELECT id, name, type, config FROM _app_checklists '
      'ORDER BY name COLLATE NOCASE',
    );
    return [for (final r in rows) _fromRow(r)];
  }

  static Checklist? byId(int id) {
    final rows = _db.select(
      'SELECT id, name, type, config FROM _app_checklists WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static int _create(String name, ChecklistType type, Object config) {
    _db.execute(
      'INSERT INTO _app_checklists (name, type, config, created_at) '
      'VALUES (?, ?, ?, ?)',
      [
        name,
        type == ChecklistType.rule ? 'rule' : 'manual',
        jsonEncode(config),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return _db.lastInsertRowId;
  }

  /// Creates a normal checklist with free-text [columns].
  static int createManual(String name, List<String> columns) =>
      _create(name, ChecklistType.manual, {'columns': columns});

  /// Creates a rule based checklist.
  static int createRule(String name, List<RuleSet> sources) => _create(
        name,
        ChecklistType.rule,
        {'sources': [for (final s in sources) s.toJson()]},
      );

  static void rename(int id, String name) {
    _db.execute('UPDATE _app_checklists SET name = ? WHERE id = ?', [name, id]);
  }

  static void updateRuleSources(int id, List<RuleSet> sources) {
    _db.execute(
      'UPDATE _app_checklists SET config = ? WHERE id = ?',
      [
        jsonEncode({'sources': [for (final s in sources) s.toJson()]}),
        id,
      ],
    );
  }

  /// Deletes a checklist with all its entries and ticks.
  static void delete(int id) {
    final db = _db;
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM _app_checklist_items WHERE checklist_id = ?', [id]);
      db.execute('DELETE FROM _app_checklist_checks WHERE checklist_id = ?', [id]);
      db.execute('DELETE FROM _app_checklists WHERE id = ?', [id]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // --- Entries of normal checklists ----------------------------

  static List<ManualItem> items(int checklistId) {
    final rows = _db.select(
      'SELECT id, checked, cells FROM _app_checklist_items '
      'WHERE checklist_id = ? ORDER BY position, id',
      [checklistId],
    );
    return [
      for (final r in rows)
        ManualItem(
          id: r['id'] as int,
          checked: (r['checked'] as int) != 0,
          cells: [
            for (final c in jsonDecode(r['cells'] as String) as List)
              c as String,
          ],
        ),
    ];
  }

  static void addItem(int checklistId, List<String> cells) {
    final next = _db.select(
      'SELECT COALESCE(MAX(position), 0) + 1 AS p '
      'FROM _app_checklist_items WHERE checklist_id = ?',
      [checklistId],
    ).first['p'] as int;
    _db.execute(
      'INSERT INTO _app_checklist_items (checklist_id, position, checked, cells) '
      'VALUES (?, ?, 0, ?)',
      [checklistId, next, jsonEncode(cells)],
    );
  }

  static void updateItem(int itemId, List<String> cells) {
    _db.execute(
      'UPDATE _app_checklist_items SET cells = ? WHERE id = ?',
      [jsonEncode(cells), itemId],
    );
  }

  static void setItemChecked(int itemId, bool checked) {
    _db.execute(
      'UPDATE _app_checklist_items SET checked = ? WHERE id = ?',
      [checked ? 1 : 0, itemId],
    );
  }

  static void deleteItem(int itemId) {
    _db.execute('DELETE FROM _app_checklist_items WHERE id = ?', [itemId]);
  }

  /// Removes all ticked entries of a normal checklist.
  static void deleteCheckedItems(int checklistId) {
    _db.execute(
      'DELETE FROM _app_checklist_items WHERE checklist_id = ? AND checked = 1',
      [checklistId],
    );
  }

  /// Removes the tick from every entry of a normal checklist.
  static void uncheckAllItems(int checklistId) {
    _db.execute(
      'UPDATE _app_checklist_items SET checked = 0 WHERE checklist_id = ?',
      [checklistId],
    );
  }

  /// Done / total entries of every normal checklist (checklist id -> counts).
  static Map<int, ({int done, int total})> manualCounts() {
    final rows = _db.select(
      'SELECT checklist_id, COALESCE(SUM(checked), 0) AS done, COUNT(*) AS total '
      'FROM _app_checklist_items GROUP BY checklist_id',
    );
    return {
      for (final r in rows)
        (r['checklist_id'] as int): (
          done: r['done'] as int,
          total: r['total'] as int,
        ),
    };
  }

  // --- Ticks of rule checklists -------------------------------

  /// Returns the ticked rows of [table] that are still shown
  /// ([matching] = rows the rules currently select) and forgets ticks
  /// of rows that are not shown any more.
  static Set<int> syncChecks(int checklistId, String table, Set<int> matching) {
    final rows = _db.select(
      'SELECT row_id FROM _app_checklist_checks '
      'WHERE checklist_id = ? AND table_name = ?',
      [checklistId, table],
    );
    final stored = {for (final r in rows) r['row_id'] as int};
    final stale = stored.difference(matching);
    if (stale.isNotEmpty) clearChecks(checklistId, table, stale);
    return stored.intersection(matching);
  }

  static void setRowChecked(
    int checklistId,
    String table,
    int rowId,
    bool checked,
  ) {
    if (checked) {
      _db.execute(
        'INSERT OR IGNORE INTO _app_checklist_checks '
        '(checklist_id, table_name, row_id) VALUES (?, ?, ?)',
        [checklistId, table, rowId],
      );
    } else {
      clearChecks(checklistId, table, [rowId]);
    }
  }

  static void clearChecks(int checklistId, String table, Iterable<int> rowIds) {
    final db = _db;
    db.execute('BEGIN');
    try {
      for (final id in rowIds) {
        db.execute(
          'DELETE FROM _app_checklist_checks '
          'WHERE checklist_id = ? AND table_name = ? AND row_id = ?',
          [checklistId, table, id],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // --- Keeping rules in sync with renamed tables/columns ------
  // Called by the Inventory screen. Never throw: a checklist problem
  // must not break renaming a table.

  static void onTableRenamed(String oldName, String newName) {
    try {
      for (final list in all()) {
        if (list.type != ChecklistType.rule) continue;
        final sources = list.sources;
        var changed = false;
        for (final s in sources) {
          if (s.table == oldName) {
            s.table = newName;
            changed = true;
          }
        }
        if (changed) updateRuleSources(list.id, sources);
      }
      _db.execute(
        'UPDATE _app_checklist_checks SET table_name = ? WHERE table_name = ?',
        [newName, oldName],
      );
    } catch (_) {}
  }

  static void onTableDropped(String table) {
    try {
      _db.execute(
        'DELETE FROM _app_checklist_checks WHERE table_name = ?',
        [table],
      );
    } catch (_) {}
  }

  static void onColumnRenamed(String table, String oldName, String newName) {
    try {
      for (final list in all()) {
        if (list.type != ChecklistType.rule) continue;
        final sources = list.sources;
        var changed = false;
        for (final s in sources) {
          if (s.table != table) continue;
          if (s.labelColumn == oldName) {
            s.labelColumn = newName;
            changed = true;
          }
          if (s.groupColumn == oldName) {
            s.groupColumn = newName;
            changed = true;
          }
          final shown = s.displayColumns.indexOf(oldName);
          if (shown >= 0) {
            s.displayColumns[shown] = newName;
            changed = true;
          }
          for (final c in s.conditions) {
            if (c.column == oldName) {
              c.column = newName;
              changed = true;
            }
            if (c.otherColumn == oldName) {
              c.otherColumn = newName;
              changed = true;
            }
          }
        }
        if (changed) updateRuleSources(list.id, sources);
      }
    } catch (_) {}
  }
}
