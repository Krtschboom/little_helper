import 'package:flutter/material.dart';

import '../services/checklist_service.dart';
import '../services/rule_engine.dart';
import '../widgets/labeled_dropdown.dart';
import 'rule_editor_screen.dart';

/// A rule based checklist: shows the rows of the linked tables for
/// which the rules apply. Tick what you have done/bought, then
/// "Zur Tabelle hinzufügen" writes the new numbers/dates into the tables.
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

/// One line of the list: a table header, a row, or a message.
class _Entry {
  const _Entry.header(this.source)
      : row = null,
        message = null,
        isError = false;
  const _Entry.item(this.source, this.row)
      : message = null,
        isError = false;
  const _Entry.message(this.source, this.message, {this.isError = false})
      : row = null;

  final _SourceResult source;
  final Map<String, Object?>? row;
  final String? message;
  final bool isError;
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
    final inputs = <_AddInput>[
      for (final r in _results)
        if (r.checked.isNotEmpty && r.error == null)
          _AddInput(r.set, r.checked.length),
    ];
    if (inputs.isEmpty) return;

    final changes = await showDialog<List<_SourceChanges>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddToTableDialog(inputs: inputs),
    );
    if (changes == null || !mounted) return;

    try {
      var updated = 0;
      for (final change in changes) {
        final result = _results.firstWhere((r) => r.set.table == change.table);
        final ids = result.checked.toList();
        updated += RuleEngine.applyChanges(
          change.table,
          ids,
          numbers: change.numbers,
          dates: change.dates,
        );
        // Done: take the ticks away. Rows that still match the rules
        // simply show up again, unticked.
        ChecklistService.clearChecks(widget.checklistId, change.table, ids);
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

  /// Small grey text under an entry: the values the rules looked at.
  String _details(_SourceResult r, Map<String, Object?> row) {
    return [
      for (final c in r.set.usedColumns)
        if (c != r.set.labelColumn) '$c: ${row[c] ?? '–'}',
    ].join('  ·  ');
  }

  Widget _buildEntry(_Entry e) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final r = e.source;

    final row = e.row;
    if (row != null) {
      final id = row[ruleRowIdKey] as int;
      final details = _details(r, row);
      return CheckboxListTile(
        controlAffinity: ListTileControlAffinity.leading,
        value: r.checked.contains(id),
        onChanged: (v) => _toggle(r, id, v ?? false),
        title: Text(row[r.set.labelColumn]?.toString() ?? '(leer)'),
        subtitle: details.isEmpty ? null : Text(details),
      );
    }

    final message = e.message;
    if (message != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          message,
          style: TextStyle(color: e.isError ? scheme.error : null),
        ),
      );
    }

    // Table header
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

    final entries = <_Entry>[];
    for (final r in _results) {
      entries.add(_Entry.header(r));
      if (r.error != null) {
        entries.add(_Entry.message(r, r.error!, isError: true));
      } else if (r.rows.isEmpty) {
        entries.add(_Entry.message(r, 'Nichts zu tun - keine Regel trifft zu.'));
      } else {
        for (final row in r.rows) {
          entries.add(_Entry.item(r, row));
        }
      }
    }
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
// "Zur Tabelle hinzufügen"
// ---------------------------------------------------------------

/// What the dialog needs to know about one table with ticked rows.
class _AddInput {
  _AddInput(this.set, this.count) {
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
  final int count;
  final List<String> numberColumns = [];
  final List<String> dateColumns = [];
}

/// The new values for the ticked rows of one table.
class _SourceChanges {
  const _SourceChanges(this.table, this.numbers, this.dates);

  final String table;
  final Map<String, NumberChange> numbers;
  final Map<String, String> dates; // column -> ISO date
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

class _AddToTableDialog extends StatefulWidget {
  const _AddToTableDialog({required this.inputs});

  final List<_AddInput> inputs;

  @override
  State<_AddToTableDialog> createState() => _AddToTableDialogState();
}

class _AddToTableDialogState extends State<_AddToTableDialog> {
  late final List<Map<String, _NumDraft>> _nums = [
    for (final inp in widget.inputs)
      {for (final c in inp.numberColumns) c: _NumDraft()},
  ];
  late final List<Map<String, _DateDraft>> _dates = [
    for (final inp in widget.inputs)
      {for (final c in inp.dateColumns) c: _DateDraft()},
  ];
  String? _error;

  @override
  void dispose() {
    for (final m in _nums) {
      for (final d in m.values) {
        d.ctrl.dispose();
      }
    }
    for (final m in _dates) {
      for (final d in m.values) {
        d.amountCtrl.dispose();
      }
    }
    super.dispose();
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

  void _submit() {
    final out = <_SourceChanges>[];
    for (var i = 0; i < widget.inputs.length; i++) {
      final inp = widget.inputs[i];
      final numbers = <String, NumberChange>{};
      final dates = <String, String>{};

      for (final e in _nums[i].entries) {
        final text = e.value.ctrl.text.trim();
        if (text.isEmpty) continue; // empty = leave unchanged
        final value = num.tryParse(text.replaceAll(',', '.'));
        if (value == null) {
          setState(() => _error = '"$text" ist keine Zahl (${e.key}).');
          return;
        }
        numbers[e.key] = NumberChange(add: e.value.add, value: value);
      }

      for (final e in _dates[i].entries) {
        final d = e.value;
        if (d.mode == 1) {
          final fixed = d.fixed;
          if (fixed == null) {
            setState(() => _error = 'Bitte ein Datum wählen (${e.key}).');
            return;
          }
          dates[e.key] = formatIsoDate(fixed);
        } else if (d.mode == 2) {
          final amount = int.tryParse(d.amountCtrl.text.trim());
          if (amount == null || amount < 0) {
            setState(() => _error = 'Bitte eine Anzahl eingeben (${e.key}).');
            return;
          }
          final now = DateTime.now();
          final days = amount * (d.unit == RuleUnit.week ? 7 : 1);
          dates[e.key] = formatIsoDate(DateTime(now.year, now.month, now.day + days));
        }
      }

      if (numbers.isNotEmpty || dates.isNotEmpty) {
        out.add(_SourceChanges(inp.set.table, numbers, dates));
      }
    }

    if (out.isEmpty) {
      setState(() => _error = 'Bitte mindestens einen neuen Wert angeben.');
      return;
    }
    Navigator.pop(context, out);
  }

  Widget _numberField(int i, String column) {
    final d = _nums[i][column]!;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(column, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: LabeledDropdown<bool>(
                  label: 'Art',
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
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Wert',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dateField(int i, String column) {
    final d = _dates[i][column]!;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(column, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          LabeledDropdown<int>(
            label: 'Neues Datum',
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

  Widget _buildSource(int i) {
    final inp = widget.inputs[i];
    final hasFields = inp.numberColumns.isNotEmpty || inp.dateColumns.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Text(
          '${inp.set.table} · ${inp.count} '
          '${inp.count == 1 ? 'Eintrag' : 'Einträge'}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (!hasFields)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'In den Regeln gibt es keine Zahlen- oder Datumsspalte, '
              'die geändert werden könnte.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final c in inp.numberColumns) _numberField(i, c),
        for (final c in inp.dateColumns) _dateField(i, c),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Zur Tabelle hinzufügen'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Die neuen Werte werden bei allen abgehakten Einträgen in die '
                'Tabelle geschrieben. Leere Felder bleiben unverändert.',
              ),
              for (var i = 0; i < widget.inputs.length; i++) _buildSource(i),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          child: const Text('Eintragen'),
        ),
      ],
    );
  }
}
