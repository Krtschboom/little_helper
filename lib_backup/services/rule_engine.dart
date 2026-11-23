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

/// Extra key in result rows of a rule set with a unique column: how
/// many table rows were merged into this one entry.
const ruleCountKey = '__cnt';

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
    this.groupColumn,
    this.uniqueColumn,
    List<String>? displayColumns,
    List<RuleCondition>? conditions,
  })  : displayColumns = displayColumns ?? [],
        conditions = conditions ?? [];

  String table;
  String? labelColumn;

  /// Optional: rows with the same value in this column are listed
  /// together under a header (e.g. the supermarket).
  String? groupColumn;

  /// Optional "unique" column (e.g. the name): all rows with the same
  /// value are merged into ONE entry. The rules then look at the
  /// merged values: number columns are added up, for date columns the
  /// earliest date counts.
  String? uniqueColumn;

  /// Extra columns shown next to the title (e.g. price, quantity).
  List<String> displayColumns;
  List<RuleCondition> conditions;

  /// The columns shown next to the title: the chosen [displayColumns],
  /// or - if none were chosen - the columns the rules look at.
  List<String> get shownColumns {
    if (displayColumns.isNotEmpty) return displayColumns;
    return [
      for (final c in usedColumns)
        if (c != labelColumn && c != groupColumn) c,
    ];
  }

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

  /// Number columns the rules compare (the ones that can be changed
  /// when something is added to the table).
  List<String> get numberColumns => {
        for (final c in conditions)
          if (c.op.kind == RuleKind.number) c.column,
      }.toList();

  /// Date columns the rules look at.
  List<String> get dateColumns => {
        for (final c in conditions)
          if (c.op.kind == RuleKind.date) c.column,
      }.toList();

  /// Number columns that are only the RIGHT side of a comparison
  /// ("stock < minimum"): they are a threshold, not an amount.
  List<String> get thresholdColumns {
    final left = numberColumns;
    return {
      for (final c in conditions)
        if (c.otherColumn != null && !left.contains(c.otherColumn)) c.otherColumn!,
    }.toList();
  }

  /// The columns the user can fill in when adding an entry by hand:
  /// title, unique and group column, the shown columns and the
  /// columns of the rules (so merging by date works).
  List<String> get entryColumns {
    final result = <String>[];
    void add(String? c) {
      if (c != null && !result.contains(c)) result.add(c);
    }

    add(labelColumn);
    add(uniqueColumn);
    add(groupColumn);
    shownColumns.forEach(add);
    usedColumns.forEach(add);
    return result;
  }

  Map<String, Object?> toJson() => {
        'table': table,
        'labelColumn': labelColumn,
        'groupColumn': groupColumn,
        'uniqueColumn': uniqueColumn,
        'displayColumns': displayColumns,
        'conditions': [for (final c in conditions) c.toJson()],
      };

  factory RuleSet.fromJson(Map<String, dynamic> j) => RuleSet(
        table: j['table'] as String,
        labelColumn: j['labelColumn'] as String?,
        groupColumn: j['groupColumn'] as String?,
        uniqueColumn: j['uniqueColumn'] as String?,
        displayColumns: [
          for (final c in (j['displayColumns'] as List? ?? const [])) c as String,
        ],
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

/// The new values for ONE row of a table.
class RowChange {
  const RowChange({
    required this.rowId,
    this.numbers = const {},
    this.dates = const {},
    this.uniqueValue,
  });

  /// SQLite rowid of the row.
  final int rowId;

  /// Value of the unique column of the entry (only for rule sets with
  /// a unique column). Then NOT just this row is changed: the rows with
  /// the same value are looked at (see [RuleEngine.applyChanges]).
  final String? uniqueValue;

  /// Number column -> set / increase.
  final Map<String, NumberChange> numbers;

  /// Date column -> ISO date 'YYYY-MM-DD'.
  final Map<String, String> dates;

  bool get isEmpty => numbers.isEmpty && dates.isEmpty;
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
    final group = set.groupColumn;
    if (group != null && !names.contains(group)) {
      return 'Die Spalte "$group" (Überschrift) existiert nicht mehr.';
    }
    final unique = set.uniqueColumn;
    if (unique != null && !names.contains(unique)) {
      return 'Die Spalte "$unique" (Zusammenfassen) existiert nicht mehr.';
    }
    for (final c in set.displayColumns) {
      if (!names.contains(c)) return 'Die angezeigte Spalte "$c" existiert nicht mehr.';
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
  ///
  /// With a [RuleSet.uniqueColumn] the rows with the same value there
  /// are merged first: one result per value, holding the SUM of the
  /// number columns of the rules and the EARLIEST date of the date
  /// columns of the rules (all other columns come from the first row
  /// of the group). The rowid is then the one of that first row and
  /// [ruleCountKey] says how many rows were merged.
  static List<Map<String, Object?>> matchingRows(RuleSet set) {
    final where = whereOf(set);
    final label = set.labelColumn;
    final group = set.groupColumn;
    final orderParts = [
      // Rows without a group value come last.
      if (group != null)
        '(${DbService.quoteIdentifier(group)} IS NULL), '
            '${DbService.quoteIdentifier(group)} COLLATE NOCASE',
      if (label != null) '${DbService.quoteIdentifier(label)} COLLATE NOCASE',
    ];
    final order = orderParts.isEmpty ? '' : ' ORDER BY ${orderParts.join(', ')}';

    final unique = set.uniqueColumn;
    final source = unique == null
        ? 'SELECT rowid AS $ruleRowIdKey, * '
            'FROM ${DbService.quoteIdentifier(set.table)}'
        : _mergedSql(set, unique);

    final result = _db.select(
      'SELECT * FROM ($source) WHERE ${where.sql}$order',
      where.args,
    );
    return [for (final r in result) Map<String, Object?>.from(r)];
  }

  /// SQL for "one row per value of [unique]": the first row of every
  /// group, with the rule columns replaced by their merged values.
  static String _mergedSql(RuleSet set, String unique) {
    const q = DbService.quoteIdentifier;
    final aggregates = <String>[];
    final alias = <String, String>{}; // column -> alias of its merged value

    void aggregate(String column, String expression) {
      final name = '"__a${aggregates.length}"';
      aggregates.add('$expression AS $name');
      alias[column] = name;
    }

    // An empty (NULL) number counts as 0, like in the rules.
    for (final c in set.numberColumns) {
      aggregate(c, 'SUM(COALESCE(${q(c)}, 0))');
    }
    for (final c in set.dateColumns) {
      aggregate(c, 'MIN(${q(c)})');
    }
    // "stock < minimum": the minimum is a threshold, it is not added up.
    for (final c in set.thresholdColumns) {
      aggregate(c, 'MAX(COALESCE(${q(c)}, 0))');
    }

    final columns = <String>[];
    for (final c in columnsOf(set.table)) {
      final merged = alias[c.name];
      final value = merged != null ? 'g.$merged' : 't.${q(c.name)}';
      columns.add('$value AS ${q(c.name)}');
    }
    final groupParts = [
      'MIN(rowid) AS __first',
      'COUNT(*) AS __count',
      ...aggregates,
    ];
    return 'SELECT t.rowid AS $ruleRowIdKey, ${columns.join(', ')}, '
        'g.__count AS $ruleCountKey '
        'FROM ${q(set.table)} AS t JOIN ('
        'SELECT ${groupParts.join(', ')} FROM ${q(set.table)} '
        'GROUP BY ${q(unique)} COLLATE NOCASE'
        ') AS g ON t.rowid = g.__first';
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

  /// Writes new values into the table: every [RowChange] has its own
  /// numbers (set / increase) and dates. All or nothing.
  /// Returns the number of entries that were changed.
  ///
  /// Normal case: the row with [RowChange.rowId] is updated.
  ///
  /// With [uniqueColumn] (and a [RowChange.uniqueValue]) the entry is a
  /// group of rows with the same value in that column:
  ///  * new dates given and a row of the group already has exactly these
  ///    dates -> the numbers go into that row;
  ///  * new dates given, but no row has them -> the newest row of the
  ///    group is COPIED, with the new dates and the new numbers (the
  ///    number columns of the rules start at 0 in the copy);
  ///  * no dates given -> the numbers go into the newest row of the group.
  static int applyChanges(
    String table,
    List<RowChange> changes, {
    String? uniqueColumn,
    List<String> numberColumns = const [],
  }) {
    final db = _db;
    var count = 0;
    db.execute('BEGIN');
    try {
      for (final change in changes) {
        if (change.isEmpty) continue;
        final unique = change.uniqueValue;
        if (uniqueColumn != null && unique != null) {
          _upsertInGroup(
            table,
            uniqueColumn,
            unique,
            numbers: change.numbers,
            dates: change.dates,
            numberColumns: numberColumns,
          );
        } else {
          _updateRow(table, change.rowId, change.numbers, change.dates);
        }
        count++;
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return count;
  }

  /// Adds entries that were typed in by hand to the table of [set].
  /// Every entry maps column -> text as typed (dates as ISO text,
  /// booleans as '1' / '0'; empty texts are ignored). Without a unique
  /// column every entry becomes a new row. With one, an entry is merged
  /// like in [applyChanges]: same value + same date -> the numbers are
  /// added to that row, same value + other date -> copy of the newest
  /// row, new value -> new row. All or nothing; returns the count.
  static int addEntries(RuleSet set, List<Map<String, String>> entries) {
    final kinds = {for (final c in columnsOf(set.table)) c.name: c.kind};
    final unique = set.uniqueColumn;
    final db = _db;
    var count = 0;
    db.execute('BEGIN');
    try {
      for (final entry in entries) {
        final typed = <String, Object?>{};
        for (final e in entry.entries) {
          final kind = kinds[e.key];
          final text = e.value.trim();
          if (kind == null || text.isEmpty) continue;
          switch (kind) {
            case RuleKind.number:
              {
                final n = num.tryParse(text.replaceAll(',', '.'));
                if (n != null) typed[e.key] = n;
              }
            case RuleKind.boolean:
              typed[e.key] = (text == '1' || text.toLowerCase() == 'ja') ? 1 : 0;
            case RuleKind.date:
            case RuleKind.text:
              typed[e.key] = text;
          }
        }
        if (typed.isEmpty) continue;

        final uniqueValue = unique == null ? null : typed[unique]?.toString();
        if (unique != null && uniqueValue != null) {
          final numbers = <String, NumberChange>{};
          final dates = <String, String>{};
          final extra = Map<String, Object?>.of(typed)..remove(unique);
          for (final c in set.numberColumns) {
            final v = typed[c];
            if (v is num) {
              numbers[c] = NumberChange(add: true, value: v);
              extra.remove(c);
            }
          }
          for (final c in set.dateColumns) {
            final v = typed[c];
            if (v is String) {
              dates[c] = v;
              extra.remove(c);
            }
          }
          _upsertInGroup(
            set.table,
            unique,
            uniqueValue,
            numbers: numbers,
            dates: dates,
            extra: extra,
            numberColumns: set.numberColumns,
          );
        } else {
          _insertRow(set.table, typed);
        }
        count++;
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return count;
  }

  /// UPDATE of one row by rowid.
  static void _updateRow(
    String table,
    int rowId,
    Map<String, NumberChange> numbers,
    Map<String, String> dates,
  ) {
    final sets = <String>[];
    final args = <Object?>[];
    numbers.forEach((column, n) {
      final col = DbService.quoteIdentifier(column);
      sets.add(n.add ? '$col = COALESCE($col, 0) + ?' : '$col = ?');
      args.add(n.value);
    });
    dates.forEach((column, iso) {
      sets.add('${DbService.quoteIdentifier(column)} = ?');
      args.add(iso);
    });
    if (sets.isEmpty) return;
    _db.execute(
      'UPDATE ${DbService.quoteIdentifier(table)} '
      'SET ${sets.join(', ')} WHERE rowid = ?',
      [...args, rowId],
    );
  }

  /// INSERT of a new row. Primary key columns are left to SQLite;
  /// NOT NULL columns without a value get 0 / '' so the insert works.
  static void _insertRow(String table, Map<String, Object?> values) {
    const q = DbService.quoteIdentifier;
    final info = _db.select('PRAGMA table_info(${q(table)})');
    final names = <String>[];
    final args = <Object?>[];
    for (final c in info) {
      if ((c['pk'] as int) > 0) continue;
      final name = c['name'] as String;
      if (values.containsKey(name)) {
        names.add(name);
        args.add(values[name]);
      } else if ((c['notnull'] as int) != 0 && c['dflt_value'] == null) {
        final declared = ((c['type'] as String?) ?? '').toUpperCase();
        names.add(name);
        args.add(kindOfAppType(declared) == RuleKind.number ? 0 : '');
      }
    }
    if (names.isEmpty) {
      _db.execute('INSERT INTO ${q(table)} DEFAULT VALUES');
      return;
    }
    _db.execute(
      'INSERT INTO ${q(table)} (${names.map(q).join(', ')}) '
      'VALUES (${List.filled(names.length, '?').join(', ')})',
      args,
    );
  }

  /// The rows of [table] whose [uniqueColumn] equals [value]
  /// (ignoring upper/lower case), oldest first.
  static List<Map<String, Object?>> _groupRows(
    String table,
    String uniqueColumn,
    String value,
  ) {
    final result = _db.select(
      'SELECT rowid AS $ruleRowIdKey, * '
      'FROM ${DbService.quoteIdentifier(table)} '
      'WHERE ${DbService.quoteIdentifier(uniqueColumn)} = ? COLLATE NOCASE '
      'ORDER BY rowid',
      [value],
    );
    return [for (final r in result) Map<String, Object?>.from(r)];
  }

  /// Applies [numbers] / [dates] to the group of rows with the same
  /// [uniqueValue] (see [applyChanges] for the three cases). Without
  /// any row of that value a new row is inserted ([extra] = further
  /// column values for it).
  static void _upsertInGroup(
    String table,
    String uniqueColumn,
    String uniqueValue, {
    required Map<String, NumberChange> numbers,
    required Map<String, String> dates,
    Map<String, Object?> extra = const {},
    List<String> numberColumns = const [],
  }) {
    final rows = _groupRows(table, uniqueColumn, uniqueValue);

    // Nothing with this value yet: a completely new row.
    if (rows.isEmpty) {
      final values = <String, Object?>{
        ...extra,
        uniqueColumn: uniqueValue,
        ...dates,
      };
      numbers.forEach((c, n) => values[c] = n.value);
      _insertRow(table, values);
      return;
    }

    // Which existing row takes the numbers?
    Map<String, Object?>? target;
    if (dates.isEmpty) {
      target = rows.last; // no date given: the newest row
    } else {
      for (final r in rows) {
        final sameDates = dates.entries.every(
          (e) => (r[e.key]?.toString() ?? '').startsWith(e.value),
        );
        if (sameDates) {
          target = r;
          break;
        }
      }
    }
    if (target != null) {
      _updateRow(table, target[ruleRowIdKey] as int, numbers, const {});
      return;
    }

    // Same value, but another date: copy the newest row with the new
    // date(s) and the new numbers.
    final copy = <String, Object?>{
      for (final e in rows.last.entries)
        if (e.key != ruleRowIdKey) e.key: e.value,
    };
    for (final c in numberColumns) {
      if (copy.containsKey(c)) copy[c] = 0; // a new batch starts empty
    }
    numbers.forEach((c, n) => copy[c] = n.value);
    copy.addAll(dates);
    copy.addAll(extra);
    _insertRow(table, copy);
  }
}
