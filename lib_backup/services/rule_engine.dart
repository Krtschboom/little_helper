import 'package:sqlite3/sqlite3.dart' show Database;

import 'db_service.dart';

// ===============================================================
// Rule engine
//
// A stand-alone service (no UI): it describes rules on the columns of
// a table ("stock < minimum", "best-before date in 2 weeks", ...),
// chains them with AND / OR, and finds the rows of the table for
// which the rules apply. The checklists use it, and so can any other
// window later:
//
//   final set = RuleSet(table: 'vorrat', labelColumn: 'name', conditions: [
//     RuleCondition(column: 'bestand', op: RuleOp.lt, number: 2),
//     RuleCondition(
//       column: 'mhd', op: RuleOp.dateWithin, amount: 2, unit: RuleUnit.week,
//       connector: RuleConnector.or,
//     ),
//   ]);
//   final rows = RuleEngine.matchingRows(set);
//
// Chaining uses the usual SQL precedence: AND binds stronger than OR,
// so  a AND b OR c  means  (a AND b) OR c.
// ===============================================================

/// Name of the extra key that carries SQLite's rowid in result rows.
const ruleRowIdKey = '__rid';

/// Formats a date the way dates are stored in the database (ISO, TEXT).
String formatIsoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// What kind of values a column holds (decides which rules fit).
enum RuleKind { number, date, boolean, text }

/// How a rule is joined to the PREVIOUS rule.
enum RuleConnector { and, or }

enum RuleUnit { day, week }

enum RuleOp {
  // numbers (INTEGER, REAL, counters)
  lt(RuleKind.number, '<'),
  le(RuleKind.number, '<='),
  eq(RuleKind.number, '='),
  ne(RuleKind.number, '!='),
  ge(RuleKind.number, '>='),
  gt(RuleKind.number, '>'),
  // dates
  dateWithin(RuleKind.date, 'in höchstens … (auch überfällig)'),
  dateInNext(RuleKind.date, 'in den nächsten …'),
  datePast(RuleKind.date, 'liegt in der Vergangenheit'),
  dateAgo(RuleKind.date, 'liegt mindestens … zurück'),
  // booleans
  isTrue(RuleKind.boolean, 'ist Ja'),
  isFalse(RuleKind.boolean, 'ist Nein'),
  // text
  textContains(RuleKind.text, 'enthält'),
  textEquals(RuleKind.text, 'ist gleich'),
  textEmpty(RuleKind.text, 'ist leer');

  const RuleOp(this.kind, this.label);

  /// The kind of column this operator can be used on.
  final RuleKind kind;

  /// Text shown in the operator dropdown.
  final String label;

  /// True if the operator needs an amount of days/weeks.
  bool get usesAmount =>
      this == dateWithin || this == dateInNext || this == dateAgo;

  /// True if the operator needs a text.
  bool get usesText => this == textContains || this == textEquals;
}

class RuleColumn {
  const RuleColumn(this.name, this.kind);

  final String name;
  final RuleKind kind;
}

String _numText(num? n) {
  if (n == null) return '0';
  return n == n.truncate() ? n.toInt().toString() : n.toString();
}

/// One rule on one column.
class RuleCondition {
  RuleCondition({
    required this.column,
    required this.op,
    this.connector = RuleConnector.and,
    this.number,
    this.otherColumn,
    this.amount = 1,
    this.unit = RuleUnit.day,
    this.text = '',
  });

  String column;
  RuleOp op;

  /// How this rule is joined to the previous one (ignored for the first).
  RuleConnector connector;

  /// Number rules: compare with this number ...
  num? number;

  /// ... or with another number column of the same table.
  String? otherColumn;

  /// Date rules: amount of [unit]s.
  int amount;
  RuleUnit unit;

  /// Text rules: the text to look for.
  String text;

  /// [amount] converted to days.
  int get days => amount * (unit == RuleUnit.week ? 7 : 1);

  /// Human readable form, e.g. `bestand < 5` or `mhd in höchstens 2 Wochen`.
  String describe() {
    final week = unit == RuleUnit.week;
    final dative = week
        ? (amount == 1 ? 'Woche' : 'Wochen')
        : (amount == 1 ? 'Tag' : 'Tagen');
    final accusative = week
        ? (amount == 1 ? 'Woche' : 'Wochen')
        : (amount == 1 ? 'Tag' : 'Tage');
    return switch (op) {
      RuleOp.lt ||
      RuleOp.le ||
      RuleOp.eq ||
      RuleOp.ne ||
      RuleOp.ge ||
      RuleOp.gt =>
        '$column ${op.label} ${otherColumn ?? _numText(number)}',
      RuleOp.dateWithin => '$column in höchstens $amount $dative (auch überfällig)',
      RuleOp.dateInNext => '$column in den nächsten $amount $dative',
      RuleOp.datePast => '$column liegt in der Vergangenheit',
      RuleOp.dateAgo => '$column liegt mindestens $amount $accusative zurück',
      RuleOp.isTrue => '$column ist Ja',
      RuleOp.isFalse => '$column ist Nein',
      RuleOp.textContains => '$column enthält "$text"',
      RuleOp.textEquals => '$column ist gleich "$text"',
      RuleOp.textEmpty => '$column ist leer',
    };
  }

  Map<String, Object?> toJson() => {
        'column': column,
        'op': op.name,
        'connector': connector.name,
        if (number != null) 'number': number,
        if (otherColumn != null) 'otherColumn': otherColumn,
        'amount': amount,
        'unit': unit.name,
        'text': text,
      };

  factory RuleCondition.fromJson(Map<String, dynamic> j) => RuleCondition(
        column: j['column'] as String,
        op: RuleOp.values.byName(j['op'] as String),
        connector:
            RuleConnector.values.byName((j['connector'] as String?) ?? 'and'),
        number: j['number'] as num?,
        otherColumn: j['otherColumn'] as String?,
        amount: (j['amount'] as num?)?.toInt() ?? 1,
        unit: RuleUnit.values.byName((j['unit'] as String?) ?? 'day'),
        text: (j['text'] as String?) ?? '',
      );
}

/// All rules for one table: "show the rows of [table] for which
/// [conditions] apply". [labelColumn] is the column used as the title
/// of a row.
class RuleSet {
  RuleSet({
    required this.table,
    this.labelColumn,
    List<RuleCondition>? conditions,
  }) : conditions = conditions ?? [];

  String table;
  String? labelColumn;
  List<RuleCondition> conditions;

  /// Every column the rules look at (left and right side), without
  /// duplicates, in the order of the rules.
  List<String> get usedColumns {
    final result = <String>[];
    for (final c in conditions) {
      if (!result.contains(c.column)) result.add(c.column);
      final other = c.otherColumn;
      if (other != null && !result.contains(other)) result.add(other);
    }
    return result;
  }

  Map<String, Object?> toJson() => {
        'table': table,
        'labelColumn': labelColumn,
        'conditions': [for (final c in conditions) c.toJson()],
      };

  factory RuleSet.fromJson(Map<String, dynamic> j) => RuleSet(
        table: j['table'] as String,
        labelColumn: j['labelColumn'] as String?,
        conditions: [
          for (final c in (j['conditions'] as List? ?? const []))
            RuleCondition.fromJson(c as Map<String, dynamic>),
        ],
      );
}

/// A new number for a column: set it, or add to it.
class NumberChange {
  const NumberChange({required this.add, required this.value});

  final bool add;
  final num value;
}

class RuleEngine {
  RuleEngine._();

  static Database get _db => DbService.instance.database;

  // --- Looking at the database --------------------------------

  /// Names of the user's tables (without the app's internal ones).
  static List<String> userTables() {
    final result = _db.select(
      r"SELECT name FROM sqlite_master "
      r"WHERE type = 'table' "
      r"AND name NOT LIKE 'sqlite\_%' ESCAPE '\' "
      r"AND name NOT LIKE '\_app\_%' ESCAPE '\' "
      r"ORDER BY name",
    );
    return [for (final r in result) r['name'] as String];
  }

  /// Columns of a table with the kind of value they hold. Empty if the
  /// table does not exist.
  static List<RuleColumn> columnsOf(String table) {
    final types = DbService.instance.appTypesFor(table);
    return [
      for (final e in types.entries) RuleColumn(e.key, kindOfAppType(e.value)),
    ];
  }

  static RuleKind kindOfAppType(String type) {
    final t = type.toUpperCase();
    if (t == 'DATUM') return RuleKind.date;
    if (t == 'BOOLEAN') return RuleKind.boolean;
    if (t == 'COUNTER' ||
        t.contains('INT') ||
        t.contains('REAL') ||
        t.contains('FLOA') ||
        t.contains('DOUB') ||
        t.contains('NUM') ||
        t.contains('DEC')) {
      return RuleKind.number;
    }
    return RuleKind.text;
  }

  /// Checks a rule set against the database. Returns an error text
  /// (German) or null if everything is fine.
  static String? validate(RuleSet set) {
    final columns = columnsOf(set.table);
    if (columns.isEmpty) return 'Tabelle "${set.table}" nicht gefunden.';
    final names = {for (final c in columns) c.name};

    final label = set.labelColumn;
    if (label == null || !names.contains(label)) {
      return 'Die Titel-Spalte fehlt oder existiert nicht mehr.';
    }
    if (set.conditions.isEmpty) return 'Es ist mindestens eine Regel nötig.';

    for (final c in set.conditions) {
      if (!names.contains(c.column)) {
        return 'Die Spalte "${c.column}" existiert nicht mehr.';
      }
      final other = c.otherColumn;
      if (other != null && !names.contains(other)) {
        return 'Die Spalte "$other" existiert nicht mehr.';
      }
      if (c.op.kind == RuleKind.number && other == null && c.number == null) {
        return 'Bei "${c.column}" fehlt die Zahl.';
      }
      if (c.op.usesAmount && c.amount < 0) {
        return 'Bei "${c.column}" fehlt die Anzahl der Tage/Wochen.';
      }
      if (c.op.usesText && c.text.isEmpty) {
        return 'Bei "${c.column}" fehlt der Text.';
      }
    }
    return null;
  }

  // --- Evaluating rules ---------------------------------------

  /// The WHERE condition (with ? placeholders) for a rule set.
  static ({String sql, List<Object?> args}) whereOf(RuleSet set) {
    final sql = StringBuffer();
    final args = <Object?>[];
    for (var i = 0; i < set.conditions.length; i++) {
      final c = set.conditions[i];
      final part = _conditionSql(c);
      if (i > 0) sql.write(c.connector == RuleConnector.or ? ' OR ' : ' AND ');
      sql.write('(${part.sql})');
      args.addAll(part.args);
    }
    return (sql: sql.toString(), args: args);
  }

  /// All rows of the table for which the rules apply. Every row map
  /// also holds the rowid under [ruleRowIdKey].
  static List<Map<String, Object?>> matchingRows(RuleSet set) {
    final where = whereOf(set);
    final label = set.labelColumn;
    final order = label == null
        ? ''
        : ' ORDER BY ${DbService.quoteIdentifier(label)} COLLATE NOCASE';
    final result = _db.select(
      'SELECT rowid AS $ruleRowIdKey, * '
      'FROM ${DbService.quoteIdentifier(set.table)} '
      'WHERE ${where.sql}$order',
      where.args,
    );
    return [for (final r in result) Map<String, Object?>.from(r)];
  }

  static String _escapeLike(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  static ({String sql, List<Object?> args}) _conditionSql(RuleCondition c) {
    final col = DbService.quoteIdentifier(c.column);
    switch (c.op) {
      case RuleOp.lt:
      case RuleOp.le:
      case RuleOp.eq:
      case RuleOp.ne:
      case RuleOp.ge:
      case RuleOp.gt:
        {
          // An empty (NULL) number counts as 0.
          final sym = switch (c.op) {
            RuleOp.lt => '<',
            RuleOp.le => '<=',
            RuleOp.eq => '=',
            RuleOp.ne => '!=',
            RuleOp.ge => '>=',
            _ => '>',
          };
          final other = c.otherColumn;
          if (other != null) {
            final otherSql = DbService.quoteIdentifier(other);
            return (
              sql: 'COALESCE($col, 0) $sym COALESCE($otherSql, 0)',
              args: <Object?>[],
            );
          }
          return (
            sql: 'COALESCE($col, 0) $sym ?',
            args: <Object?>[c.number ?? 0],
          );
        }
      case RuleOp.dateWithin:
        return (
          sql: "date($col) <= date('now', 'localtime', ?)",
          args: <Object?>['+${c.days} days'],
        );
      case RuleOp.dateInNext:
        return (
          sql: "(date($col) >= date('now', 'localtime') "
              "AND date($col) <= date('now', 'localtime', ?))",
          args: <Object?>['+${c.days} days'],
        );
      case RuleOp.datePast:
        return (
          sql: "date($col) < date('now', 'localtime')",
          args: <Object?>[],
        );
      case RuleOp.dateAgo:
        return (
          sql: "date($col) <= date('now', 'localtime', ?)",
          args: <Object?>['-${c.days} days'],
        );
      case RuleOp.isTrue:
        return (
          sql: "lower(COALESCE($col, 0)) IN ('1', 'true', 'ja')",
          args: <Object?>[],
        );
      case RuleOp.isFalse:
        return (
          sql: "lower(COALESCE($col, 0)) NOT IN ('1', 'true', 'ja')",
          args: <Object?>[],
        );
      case RuleOp.textContains:
        return (
          sql: "COALESCE($col, '') LIKE ? ESCAPE '\\'",
          args: <Object?>['%${_escapeLike(c.text)}%'],
        );
      case RuleOp.textEquals:
        return (
          sql: "lower(COALESCE($col, '')) = lower(?)",
          args: <Object?>[c.text],
        );
      case RuleOp.textEmpty:
        return (
          sql: "COALESCE($col, '') = ''",
          args: <Object?>[],
        );
    }
  }

  // --- Changing rows ------------------------------------------

  /// Writes new values into the rows [rowIds] of [table]: [numbers]
  /// sets or increases number columns, [dates] sets date columns
  /// (value = ISO date 'YYYY-MM-DD'). All or nothing. Returns the
  /// number of rows that were updated.
  static int applyChanges(
    String table,
    Iterable<int> rowIds, {
    Map<String, NumberChange> numbers = const {},
    Map<String, String> dates = const {},
  }) {
    final sets = <String>[];
    final args = <Object?>[];
    numbers.forEach((column, change) {
      final col = DbService.quoteIdentifier(column);
      sets.add(change.add ? '$col = COALESCE($col, 0) + ?' : '$col = ?');
      args.add(change.value);
    });
    dates.forEach((column, iso) {
      sets.add('${DbService.quoteIdentifier(column)} = ?');
      args.add(iso);
    });
    if (sets.isEmpty) return 0;

    final ids = rowIds.toList();
    final db = _db;
    var count = 0;
    db.execute('BEGIN');
    try {
      final stmt = db.prepare(
        'UPDATE ${DbService.quoteIdentifier(table)} '
        'SET ${sets.join(', ')} WHERE rowid = ?',
      );
      try {
        for (final id in ids) {
          stmt.execute([...args, id]);
          count++;
        }
      } finally {
        stmt.dispose();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return count;
  }
}
