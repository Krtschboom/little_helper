import 'package:flutter/material.dart';

import '../services/checklist_service.dart';
import '../services/rule_engine.dart';
import '../widgets/labeled_dropdown.dart';
import 'rule_editor_screen.dart';

/// A rule based checklist: shows the rows of the linked tables for
/// which the rules apply, optionally grouped under headers (e.g. per
/// supermarket). Tick what you have done/bought, then
/// "Zur Tabelle hinzufügen" lets you enter new numbers/dates for each
/// ticked item and writes them into the tables.
class RuleChecklistScreen extends StatefulWidget {
  const RuleChecklistScreen({super.key, required this.checklistId});

  final int checklistId;

  @override
  State<RuleChecklistScreen> createState() => _RuleChecklistScreenState();
}

/// What one linked table currently contributes to the list.
class _SourceResult {
  _SourceResult(this.set);

  final RuleSet set;
  List<Map<String, Object?>> rows = [];

  /// Row ids (rowid) the user has ticked.
  Set<int> checked = {};
  String? error;
}

enum _EntryKind { header, columns, group, item, message }

/// One line of the list.
class _Entry {
  _Entry(this.kind, this.source, {this.row, this.text, this.isError = false});

  final _EntryKind kind;
  final _SourceResult source;
  final Map<String, Object?>? row;
  final String? text;
  final bool isError;
}

String _labelOf(RuleSet set, Map<String, Object?> row) {
  final v = row[set.labelColumn]?.toString() ?? '';
  return v.isEmpty ? '(leer)' : v;
}

class _RuleChecklistScreenState extends State<RuleChecklistScreen> {
  Checklist? _list;
  List<_SourceResult> _results = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Evaluates all rules again. Rows whose data changed (e.g. in the
  /// table editor) appear or disappear automatically.
  void _load() {
    try {
      final list = ChecklistService.byId(widget.checklistId);
      if (list == null) {
        setState(() => _error = 'Checkliste nicht gefunden.');
        return;
      }
      final results = <_SourceResult>[];
      for (final set in list.sources) {
        final r = _SourceResult(set);
        final problem = RuleEngine.validate(set);
        if (problem != null) {
          r.error = problem;
        } else {
          try {
            r.rows = RuleEngine.matchingRows(set);
            final ids = {for (final row in r.rows) row[ruleRowIdKey] as int};
            r.checked = ChecklistService.syncChecks(list.id, set.table, ids);
          } catch (e) {
            r.error = e.toString();
          }
        }
        results.add(r);
      }
      setState(() {
        _list = list;
        _results = results;
        _error = null;
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

  void _toggle(_SourceResult r, int rowId, bool checked) {
    try {
      ChecklistService.setRowChecked(
        widget.checklistId,
        r.set.table,
        rowId,
        checked,
      );
      setState(() {
        if (checked) {
          r.checked.add(rowId);
        } else {
          r.checked.remove(rowId);
        }
      });
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _editRules() async {
    final list = _list;
    if (list == null) return;
    final result = await Navigator.of(context).push<RuleEditorResult>(
      MaterialPageRoute(
        builder: (_) => RuleEditorScreen(
          initialName: list.name,
          initialSources: list.sources,
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      ChecklistService.rename(list.id, result.name);
      ChecklistService.updateRuleSources(list.id, result.sources);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _addToTable() async {
    final inputs = <_AddInput>[];
    for (final r in _results) {
      if (r.checked.isEmpty || r.error != null) continue;
      final items = <_AddItem>[];
      for (final row in r.rows) {
        final id = row[ruleRowIdKey] as int;
        if (!r.checked.contains(id)) continue;
        final g = r.set.groupColumn;
        items.add(_AddItem(
          rowId: id,
          label: _labelOf(r.set, row),
          group: g == null ? null : row[g]?.toString(),
        ));
      }
      inputs.add(_AddInput(r.set, items));
    }
    if (inputs.isEmpty) return;

    final changes = await Navigator.of(context).push<List<_SourceChanges>>(
      MaterialPageRoute(builder: (_) => _AddToTableScreen(inputs: inputs)),
    );
    if (changes == null || !mounted) return;

    try {
      var updated = 0;
      for (final change in changes) {
        updated += RuleEngine.applyChanges(change.table, change.rows);
        // Done: take the ticks away from the rows that were updated.
        // Rows that still match the rules show up again, unticked.
        ChecklistService.clearChecks(
          widget.checklistId,
          change.table,
          [for (final c in change.rows) c.rowId],
        );
      }
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$updated Einträge in den Tabellen aktualisiert')),
        );
      }
    } catch (e) {
      _showError(e);
    }
  }

  String _rulesText(RuleSet set) {
    final sb = StringBuffer();
    for (var i = 0; i < set.conditions.length; i++) {
      final c = set.conditions[i];
      if (i > 0) sb.write(c.connector == RuleConnector.or ? '  ODER  ' : '  UND  ');
      sb.write(c.describe());
    }
    return sb.toString();
  }

  // --- Building the list --------------------------------------

  List<_Entry> _buildEntries() {
    final entries = <_Entry>[];
    for (final r in _results) {
      entries.add(_Entry(_EntryKind.header, r));
      if (r.error != null) {
        entries.add(_Entry(_EntryKind.message, r, text: r.error, isError: true));
        continue;
      }
      if (r.rows.isEmpty) {
        entries.add(_Entry(
          _EntryKind.message,
          r,
          text: 'Nichts zu tun - keine Regel trifft zu.',
        ));
        continue;
      }
      if (r.set.shownColumns.isNotEmpty) {
        entries.add(_Entry(_EntryKind.columns, r));
      }
      final g = r.set.groupColumn;
      String? lastGroup;
      var first = true;
      for (final row in r.rows) {
        if (g != null) {
          final key = row[g]?.toString() ?? '';
          if (first || key != lastGroup) {
            entries.add(_Entry(
              _EntryKind.group,
              r,
              text: key.isEmpty ? '(ohne $g)' : key,
            ));
            lastGroup = key;
            first = false;
          }
        }
        entries.add(_Entry(_EntryKind.item, r, row: row));
      }
    }
    return entries;
  }

  /// Shared layout of header and item rows: [checkbox] title | columns.
  Widget _columnsRow(
    _SourceResult r, {
    required Widget leading,
    required Widget Function(String column) cell,
    required Widget title,
  }) {
    return Row(
      children: [
        SizedBox(width: 56, child: leading),
        Expanded(flex: 3, child: title),
        for (final c in r.set.shownColumns) Expanded(flex: 2, child: cell(c)),
      ],
    );
  }

  Widget _buildEntry(_Entry e) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final r = e.source;

    switch (e.kind) {
      case _EntryKind.header:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.table_chart_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(r.set.table, style: textTheme.titleSmall),
                  ),
                  if (r.error == null) Text('${r.rows.length}'),
                ],
              ),
              const SizedBox(height: 2),
              Text(_rulesText(r.set), style: textTheme.bodySmall),
            ],
          ),
        );

      case _EntryKind.message:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            e.text ?? '',
            style: TextStyle(color: e.isError ? scheme.error : null),
          ),
        );

      case _EntryKind.columns:
        // Column names above the items: title | extra columns
        final style = textTheme.labelMedium
            ?.copyWith(color: scheme.onSurfaceVariant);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: _columnsRow(
            r,
            leading: const SizedBox.shrink(),
            title: Text(r.set.labelColumn ?? '', style: style),
            cell: (c) => Text(c, style: style, overflow: TextOverflow.ellipsis),
          ),
        );

      case _EntryKind.group:
        // "# Supermarkt eins" with a line below
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.text ?? '',
                style: textTheme.titleMedium?.copyWith(color: scheme.primary),
              ),
              const Divider(height: 8),
            ],
          ),
        );

      case _EntryKind.item:
        final row = e.row!;
        final id = row[ruleRowIdKey] as int;
        final checked = r.checked.contains(id);
        return InkWell(
          onTap: () => _toggle(r, id, !checked),
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 16),
            child: _columnsRow(
              r,
              leading: Checkbox(
                value: checked,
                onChanged: (v) => _toggle(r, id, v ?? false),
              ),
              title: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(_labelOf(r.set, row)),
              ),
              cell: (c) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  row[c]?.toString() ?? '–',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (_error != null || list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Checkliste')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error ?? 'Lädt ...',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      );
    }

    final entries = _buildEntries();
    final checkedCount = _results.fold<int>(0, (n, r) => n + r.checked.length);

    return Scaffold(
      appBar: AppBar(
        title: Text(list.name),
        actions: [
          IconButton(
            tooltip: 'Neu berechnen',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Regeln bearbeiten',
            icon: const Icon(Icons.tune),
            onPressed: _editRules,
          ),
        ],
      ),
      floatingActionButton: checkedCount > 0
          ? FloatingActionButton.extended(
              onPressed: _addToTable,
              icon: const Icon(Icons.playlist_add),
              label: Text('Zur Tabelle hinzufügen ($checkedCount)'),
            )
          : null,
      body: entries.isEmpty
          ? const Center(child: Text('Keine Tabellen verknüpft.'))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: entries.length,
              itemBuilder: (context, i) => _buildEntry(entries[i]),
            ),
    );
  }
}

// ---------------------------------------------------------------
// "Zur Tabelle hinzufügen": new values for EACH ticked item
// ---------------------------------------------------------------

/// One ticked row.
class _AddItem {
  const _AddItem({required this.rowId, required this.label, this.group});

  final int rowId;
  final String label;
  final String? group;
}

/// A table with its ticked rows.
class _AddInput {
  _AddInput(this.set, this.items) {
    // Only columns the rules look at can be changed: numbers (e.g. the
    // stock) and dates (e.g. the best-before date).
    for (final c in set.conditions) {
      if (c.op.kind == RuleKind.number && !numberColumns.contains(c.column)) {
        numberColumns.add(c.column);
      }
      if (c.op.kind == RuleKind.date && !dateColumns.contains(c.column)) {
        dateColumns.add(c.column);
      }
    }
  }

  final RuleSet set;
  final List<_AddItem> items;
  final List<String> numberColumns = [];
  final List<String> dateColumns = [];

  bool get hasFields => numberColumns.isNotEmpty || dateColumns.isNotEmpty;
}

/// The new values for the ticked rows of one table.
class _SourceChanges {
  const _SourceChanges(this.table, this.rows);

  final String table;
  final List<RowChange> rows;
}

class _NumDraft {
  bool add = true; // true = increase by, false = set to
  final TextEditingController ctrl = TextEditingController();
}

class _DateDraft {
  int mode = 0; // 0 = unchanged, 1 = fixed date, 2 = today + amount
  DateTime? fixed;
  final TextEditingController amountCtrl = TextEditingController(text: '1');
  RuleUnit unit = RuleUnit.week;
}

class _AddToTableScreen extends StatefulWidget {
  const _AddToTableScreen({required this.inputs});

  final List<_AddInput> inputs;

  @override
  State<_AddToTableScreen> createState() => _AddToTableScreenState();
}

class _AddToTableScreenState extends State<_AddToTableScreen> {
  // [source][item][column] -> what the user entered
  late final List<List<Map<String, _NumDraft>>> _nums = [
    for (final inp in widget.inputs)
      [
        for (final _ in inp.items)
          {for (final c in inp.numberColumns) c: _NumDraft()},
      ],
  ];
  late final List<List<Map<String, _DateDraft>>> _dates = [
    for (final inp in widget.inputs)
      [
        for (final _ in inp.items)
          {for (final c in inp.dateColumns) c: _DateDraft()},
      ],
  ];

  @override
  void dispose() {
    for (final source in _nums) {
      for (final item in source) {
        for (final d in item.values) {
          d.ctrl.dispose();
        }
      }
    }
    for (final source in _dates) {
      for (final item in source) {
        for (final d in item.values) {
          d.amountCtrl.dispose();
        }
      }
    }
    super.dispose();
  }

  void _fail(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickDate(_DateDraft d) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: d.fixed ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => d.fixed = picked);
  }

  /// Copies what was entered for the first item to all other items
  /// of the same table (a shortcut when many items get the same values).
  void _copyFirstToAll(int i) {
    setState(() {
      final nums = _nums[i];
      final dates = _dates[i];
      for (var k = 1; k < nums.length; k++) {
        nums[0].forEach((col, first) {
          nums[k][col]!
            ..add = first.add
            ..ctrl.text = first.ctrl.text;
        });
        dates[0].forEach((col, first) {
          dates[k][col]!
            ..mode = first.mode
            ..fixed = first.fixed
            ..amountCtrl.text = first.amountCtrl.text
            ..unit = first.unit;
        });
      }
    });
  }

  void _submit() {
    final out = <_SourceChanges>[];
    for (var i = 0; i < widget.inputs.length; i++) {
      final inp = widget.inputs[i];
      final rows = <RowChange>[];

      for (var k = 0; k < inp.items.length; k++) {
        final item = inp.items[k];
        final numbers = <String, NumberChange>{};
        final dates = <String, String>{};

        for (final e in _nums[i][k].entries) {
          final text = e.value.ctrl.text.trim();
          if (text.isEmpty) continue; // empty = leave unchanged
          final value = num.tryParse(text.replaceAll(',', '.'));
          if (value == null) {
            _fail('"$text" ist keine Zahl (${item.label}, ${e.key}).');
            return;
          }
          numbers[e.key] = NumberChange(add: e.value.add, value: value);
        }

        for (final e in _dates[i][k].entries) {
          final d = e.value;
          if (d.mode == 1) {
            final fixed = d.fixed;
            if (fixed == null) {
              _fail('Bitte ein Datum wählen (${item.label}, ${e.key}).');
              return;
            }
            dates[e.key] = formatIsoDate(fixed);
          } else if (d.mode == 2) {
            final amount = int.tryParse(d.amountCtrl.text.trim());
            if (amount == null || amount < 0) {
              _fail('Bitte eine Anzahl eingeben (${item.label}, ${e.key}).');
              return;
            }
            final now = DateTime.now();
            final days = amount * (d.unit == RuleUnit.week ? 7 : 1);
            dates[e.key] =
                formatIsoDate(DateTime(now.year, now.month, now.day + days));
          }
        }

        final change = RowChange(
          rowId: item.rowId,
          numbers: numbers,
          dates: dates,
        );
        if (!change.isEmpty) rows.add(change);
      }
      if (rows.isNotEmpty) out.add(_SourceChanges(inp.set.table, rows));
    }

    if (out.isEmpty) {
      _fail('Bitte für mindestens einen Eintrag einen neuen Wert angeben.');
      return;
    }
    Navigator.pop(context, out);
  }

  Widget _numberField(int i, int k, String column) {
    final d = _nums[i][k][column]!;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: LabeledDropdown<bool>(
              label: '$column - Art',
              value: d.add,
              items: const {true: 'Erhöhen um', false: 'Setzen auf'},
              onChanged: (v) => setState(() => d.add = v),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: d.ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Wert',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateField(int i, int k, String column) {
    final d = _dates[i][k][column]!;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledDropdown<int>(
            label: '$column - neues Datum',
            value: d.mode,
            items: const {
              0: 'Unverändert lassen',
              1: 'Festes Datum wählen',
              2: 'Heute plus …',
            },
            onChanged: (v) => setState(() => d.mode = v),
          ),
          if (d.mode == 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: () => _pickDate(d),
                icon: const Icon(Icons.calendar_month),
                label: Text(
                  d.fixed == null ? 'Datum wählen' : formatIsoDate(d.fixed!),
                ),
              ),
            ),
          if (d.mode == 2)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: d.amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Anzahl',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
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
            ),
        ],
      ),
    );
  }

  Widget _buildItem(int i, int k) {
    final inp = widget.inputs[i];
    final item = inp.items[k];
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.label, style: textTheme.titleSmall),
            if (item.group != null && item.group!.isNotEmpty)
              Text(item.group!, style: textTheme.bodySmall),
            for (final c in inp.numberColumns) _numberField(i, k, c),
            for (final c in inp.dateColumns) _dateField(i, k, c),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zur Tabelle hinzufügen'),
        actions: [
          TextButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.check),
            label: const Text('Eintragen'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Gib für jeden abgehakten Eintrag die neuen Werte an. '
            'Leere Felder bleiben unverändert; Einträge ohne neuen Wert '
            'werden übersprungen und bleiben abgehakt.',
          ),
          for (var i = 0; i < widget.inputs.length; i++) ...[
            const SizedBox(height: 20),
            Text(
              '${widget.inputs[i].set.table} · ${widget.inputs[i].items.length} '
              '${widget.inputs[i].items.length == 1 ? 'Eintrag' : 'Einträge'}',
              style: textTheme.titleMedium,
            ),
            if (!widget.inputs[i].hasFields)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'In den Regeln gibt es keine Zahlen- oder Datumsspalte, '
                  'die geändert werden könnte.',
                  style: textTheme.bodySmall,
                ),
              )
            else if (widget.inputs[i].items.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _copyFirstToAll(i),
                  icon: const Icon(Icons.copy_all),
                  label: const Text('Werte vom ersten Eintrag für alle übernehmen'),
                ),
              ),
            if (widget.inputs[i].hasFields)
              for (var k = 0; k < widget.inputs[i].items.length; k++)
                _buildItem(i, k),
          ],
        ],
      ),
    );
  }
}
