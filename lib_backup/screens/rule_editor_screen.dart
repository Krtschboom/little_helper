import 'package:flutter/material.dart';

import '../services/rule_engine.dart';
import '../widgets/labeled_dropdown.dart';

/// What the rule editor hands back when the user saves.
typedef RuleEditorResult = ({String name, List<RuleSet> sources});

/// Editor for a rule based checklist: link tables, choose the title
/// column and build the rules (with UND / ODER) for each table.
/// Used for creating a checklist and for editing its rules later.
class RuleEditorScreen extends StatefulWidget {
  const RuleEditorScreen({
    super.key,
    this.initialName = '',
    this.initialSources = const [],
  });

  final String initialName;
  final List<RuleSet> initialSources;

  @override
  State<RuleEditorScreen> createState() => _RuleEditorScreenState();
}

/// Editable copy of a [RuleCondition].
class _CondDraft {
  _CondDraft({this.column, this.op});

  String? column;
  RuleOp? op;
  RuleConnector connector = RuleConnector.and;
  bool useOtherColumn = false;
  String? otherColumn;
  RuleUnit unit = RuleUnit.day;

  /// Number, amount of days/weeks or text - depending on the operator.
  final TextEditingController valueCtrl = TextEditingController();

  void dispose() => valueCtrl.dispose();
}

/// Editable copy of a [RuleSet].
class _SourceDraft {
  String? table;
  String? label;
  String? group;

  /// "Unique" column: rows with the same value become ONE entry.
  String? unique;
  final List<String> display = [];
  List<RuleColumn> columns = [];
  final List<_CondDraft> conds = [];
}

String _numText(num? n) {
  if (n == null) return '';
  return n == n.truncate() ? n.toInt().toString() : n.toString();
}

InputDecoration _dec(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );

class _RuleEditorScreenState extends State<RuleEditorScreen> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName);
  final List<_SourceDraft> _sources = [];

  /// Removed rules: their controllers are disposed with the screen.
  final List<_CondDraft> _retired = [];
  List<String> _tables = [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    try {
      _tables = RuleEngine.userTables();
    } catch (e) {
      _loadError = e.toString();
    }
    for (final set in widget.initialSources) {
      _sources.add(_draftFromSet(set));
    }
    if (_sources.isEmpty) _sources.add(_SourceDraft());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final s in _sources) {
      for (final c in s.conds) {
        c.dispose();
      }
    }
    for (final c in _retired) {
      c.dispose();
    }
    super.dispose();
  }

  // --- Conversion ---------------------------------------------

  _SourceDraft _draftFromSet(RuleSet set) {
    final src = _SourceDraft()
      ..table = set.table
      ..label = set.labelColumn
      ..group = set.groupColumn
      ..unique = set.uniqueColumn;
    src.display.addAll(set.displayColumns);
    try {
      src.columns = RuleEngine.columnsOf(set.table);
    } catch (_) {}
    for (final c in set.conditions) {
      final d = _CondDraft(column: c.column, op: c.op)
        ..connector = c.connector
        ..useOtherColumn = c.otherColumn != null
        ..otherColumn = c.otherColumn
        ..unit = c.unit;
      if (c.op.kind == RuleKind.number) {
        if (c.otherColumn == null) d.valueCtrl.text = _numText(c.number);
      } else if (c.op.usesAmount) {
        d.valueCtrl.text = c.amount.toString();
      } else if (c.op.usesText) {
        d.valueCtrl.text = c.text;
      }
      src.conds.add(d);
    }
    return src;
  }

  RuleCondition _toCondition(_CondDraft d) {
    final op = d.op!;
    final text = d.valueCtrl.text.trim();
    final isNumber = op.kind == RuleKind.number;
    return RuleCondition(
      column: d.column!,
      op: op,
      connector: d.connector,
      number: (isNumber && !d.useOtherColumn)
          ? num.tryParse(text.replaceAll(',', '.'))
          : null,
      otherColumn: (isNumber && d.useOtherColumn) ? d.otherColumn : null,
      amount: op.usesAmount ? (int.tryParse(text) ?? -1) : 1,
      unit: d.unit,
      text: op.usesText ? text : '',
    );
  }

  // --- Helpers ------------------------------------------------

  RuleKind _kindOf(_SourceDraft s, String? column) {
    for (final c in s.columns) {
      if (c.name == column) return c.kind;
    }
    return RuleKind.text;
  }

  Map<RuleOp, String> _opsFor(RuleKind kind) => {
        for (final o in RuleOp.values)
          if (o.kind == kind) o: o.label,
      };

  /// Picks [column] for a rule and resets what depends on it.
  void _setColumn(_SourceDraft s, _CondDraft d, String column) {
    final kind = _kindOf(s, column);
    d.column = column;
    if (d.op == null || d.op!.kind != kind) {
      d.op = RuleOp.values.firstWhere((o) => o.kind == kind);
    }
    d.useOtherColumn = false;
    d.otherColumn = null;
    d.valueCtrl.text = kind == RuleKind.date ? '7' : '';
  }

  _CondDraft _newCond(_SourceDraft s) {
    // Number and date columns are the most useful first rule.
    RuleColumn? pick;
    for (final c in s.columns) {
      if (c.kind == RuleKind.number || c.kind == RuleKind.date) {
        pick = c;
        break;
      }
    }
    pick ??= s.columns.isEmpty ? null : s.columns.first;
    final d = _CondDraft();
    if (pick != null) _setColumn(s, d, pick.name);
    return d;
  }

  void _setTable(_SourceDraft s, String table) {
    setState(() {
      s.table = table;
      try {
        s.columns = RuleEngine.columnsOf(table);
      } catch (_) {
        s.columns = [];
      }
      _retired.addAll(s.conds);
      s.conds.clear();

      // Suggest the first text column as title column.
      String? label;
      for (final c in s.columns) {
        if (c.kind == RuleKind.text) {
          label = c.name;
          break;
        }
      }
      s.label = label ?? (s.columns.isEmpty ? null : s.columns.first.name);
      s.group = null;
      s.unique = null;
      s.display.clear();
      if (s.columns.isNotEmpty) s.conds.add(_newCond(s));
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('Bitte einen Namen eingeben.');
      return;
    }

    final result = <RuleSet>[];
    final usedTables = <String>{};
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      final prefix = 'Tabelle ${i + 1}: ';
      final table = s.table;
      if (table == null) {
        _snack('${prefix}Bitte eine Tabelle wählen.');
        return;
      }
      if (!usedTables.add(table)) {
        _snack('Die Tabelle "$table" ist doppelt verknüpft. '
            'Mehrere Regeln für eine Tabelle verkettest du mit UND / ODER.');
        return;
      }
      if (s.conds.any((d) => d.column == null || d.op == null)) {
        _snack('${prefix}Bitte alle Regeln vervollständigen.');
        return;
      }
      final set = RuleSet(
        table: table,
        labelColumn: s.label,
        groupColumn: s.group,
        uniqueColumn: s.unique,
        displayColumns: List.of(s.display),
        conditions: [for (final d in s.conds) _toCondition(d)],
      );
      final error = RuleEngine.validate(set);
      if (error != null) {
        _snack('$prefix$error');
        return;
      }
      result.add(set);
    }
    Navigator.pop<RuleEditorResult>(context, (name: name, sources: result));
  }

  // --- UI -----------------------------------------------------

  Widget _buildCond(_SourceDraft s, _CondDraft d, int j) {
    final scheme = Theme.of(context).colorScheme;
    final kind = _kindOf(s, d.column);
    final op = d.op;
    final otherNumberColumns = {
      for (final c in s.columns)
        if (c.kind == RuleKind.number && c.name != d.column) c.name: c.name,
    };

    return Container(
      key: ObjectKey(d),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (j > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SegmentedButton<RuleConnector>(
                segments: const [
                  ButtonSegment<RuleConnector>(
                    value: RuleConnector.and,
                    label: Text('UND'),
                  ),
                  ButtonSegment<RuleConnector>(
                    value: RuleConnector.or,
                    label: Text('ODER'),
                  ),
                ],
                selected: {d.connector},
                onSelectionChanged: (v) => setState(() => d.connector = v.first),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: LabeledDropdown<String>(
                  label: 'Spalte',
                  value: d.column,
                  items: {for (final c in s.columns) c.name: c.name},
                  onChanged: (v) => setState(() => _setColumn(s, d, v)),
                ),
              ),
              IconButton(
                tooltip: 'Regel entfernen',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  s.conds.remove(d);
                  _retired.add(d);
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LabeledDropdown<RuleOp>(
            label: 'Bedingung',
            value: op,
            items: _opsFor(kind),
            onChanged: (v) => setState(() => d.op = v),
          ),
          if (op != null && op.kind == RuleKind.number) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(value: false, label: Text('Zahl')),
                ButtonSegment<bool>(value: true, label: Text('andere Spalte')),
              ],
              selected: {d.useOtherColumn},
              onSelectionChanged: (v) =>
                  setState(() => d.useOtherColumn = v.first),
            ),
            const SizedBox(height: 8),
            if (d.useOtherColumn)
              LabeledDropdown<String>(
                label: 'Vergleichsspalte',
                value: d.otherColumn,
                items: otherNumberColumns,
                onChanged: (v) => setState(() => d.otherColumn = v),
              )
            else
              TextField(
                controller: d.valueCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: _dec('Zahl'),
              ),
          ],
          if (op != null && op.usesAmount) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: d.valueCtrl,
                    keyboardType: TextInputType.number,
                    decoration: _dec('Anzahl'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: LabeledDropdown<RuleUnit>(
                    label: 'Einheit',
                    value: d.unit,
                    items: const {
                      RuleUnit.day: 'Tage',
                      RuleUnit.week: 'Wochen',
                    },
                    onChanged: (v) => setState(() => d.unit = v),
                  ),
                ),
              ],
            ),
          ],
          if (op != null && op.usesText) ...[
            const SizedBox(height: 8),
            TextField(controller: d.valueCtrl, decoration: _dec('Text')),
          ],
        ],
      ),
    );
  }

  Widget _buildSource(int i, _SourceDraft s) {
    final scheme = Theme.of(context).colorScheme;
    final tableMissing = s.table != null && !_tables.contains(s.table);

    return Card(
      key: ObjectKey(s),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Tabelle ${i + 1}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_sources.length > 1)
                  IconButton(
                    tooltip: 'Tabelle entfernen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() {
                      _retired.addAll(s.conds);
                      _sources.remove(s);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LabeledDropdown<String>(
              label: 'Tabelle',
              value: s.table,
              items: {for (final t in _tables) t: t},
              onChanged: (v) => _setTable(s, v),
            ),
            if (tableMissing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Die Tabelle "${s.table}" gibt es nicht mehr - bitte neu wählen.',
                  style: TextStyle(color: scheme.error),
                ),
              ),
            if (s.table != null && s.columns.isNotEmpty) ...[
              const SizedBox(height: 8),
              LabeledDropdown<String>(
                label: 'Titel-Spalte',
                value: s.label,
                items: {for (final c in s.columns) c.name: c.name},
                onChanged: (v) => setState(() {
                  s.label = v;
                  if (s.group == v) s.group = null;
                  s.display.remove(v);
                }),
              ),
              const SizedBox(height: 8),
              LabeledDropdown<String>(
                label: 'Gruppieren nach (Überschrift)',
                value: s.group ?? '',
                items: {
                  '': 'Keine Gruppierung',
                  for (final c in s.columns)
                    if (c.name != s.label) c.name: c.name,
                },
                onChanged: (v) => setState(() {
                  s.group = v.isEmpty ? null : v;
                  s.display.remove(s.group);
                }),
              ),
              const SizedBox(height: 8),
              LabeledDropdown<String>(
                label: 'Zusammenfassen nach (eindeutig)',
                value: s.unique ?? '',
                items: {
                  '': 'Nicht zusammenfassen',
                  for (final c in s.columns) c.name: c.name,
                },
                onChanged: (v) => setState(() => s.unique = v.isEmpty ? null : v),
              ),
              if (s.unique != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Zeilen mit gleichem "${s.unique}" sind ein einziger Eintrag. '
                    'Zahlen aus den Regeln werden addiert, bei Datums-Regeln '
                    'zählt das früheste Datum. Trägst du später ein anderes '
                    'Datum ein, wird eine Kopie der Zeile mit dem neuen Datum '
                    'angelegt.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                'Weitere angezeigte Spalten',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                'Erscheinen neben dem Titel, in der Reihenfolge der Auswahl. '
                'Ohne Auswahl werden die Spalten aus den Regeln gezeigt.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in s.columns)
                    if (c.name != s.label && c.name != s.group)
                      FilterChip(
                        label: Text(c.name),
                        selected: s.display.contains(c.name),
                        onSelected: (on) => setState(() {
                          if (on) {
                            s.display.add(c.name);
                          } else {
                            s.display.remove(c.name);
                          }
                        }),
                      ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Regeln', style: Theme.of(context).textTheme.titleSmall),
              Text(
                'Eine Zeile erscheint in der Checkliste, wenn die Regeln '
                'zutreffen. UND bindet stärker als ODER.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              for (var j = 0; j < s.conds.length; j++)
                _buildCond(s, s.conds[j], j),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => s.conds.add(_newCond(s))),
                  icon: const Icon(Icons.add),
                  label: const Text('Regel hinzufügen'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initialSources.isEmpty
              ? 'Neue regelbasierte Checkliste'
              : 'Regeln bearbeiten',
        ),
        actions: [
          IconButton(
            tooltip: 'Speichern',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _loadError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Name der Checkliste',
              hintText: 'z.B. Einkaufsliste',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _sources.length; i++) _buildSource(i, _sources[i]),
          OutlinedButton.icon(
            onPressed: () => setState(() => _sources.add(_SourceDraft())),
            icon: const Icon(Icons.add),
            label: const Text('Weitere Tabelle verknüpfen'),
          ),
        ],
      ),
    );
  }
}
