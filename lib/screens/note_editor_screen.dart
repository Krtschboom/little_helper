import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/note_service.dart';

/// Opens [noteId] for editing and previewing. Changes are saved to the
/// database immediately on every change, so nothing is lost when the
/// app is closed unexpectedly.
///
/// The button in the app bar switches between edit mode (markdown
/// source with a formatting toolbar) and view mode (rendered preview).
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.noteId});

  final int noteId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  Note? _note;
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  bool _editMode = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    try {
      final note = NoteService.byId(widget.noteId);
      if (note == null) {
        throw StateError('Notiz ${widget.noteId} existiert nicht (mehr).');
      }
      _note = note;
      _titleCtrl.text = note.title;
      _bodyCtrl.text = note.body;
      _titleCtrl.addListener(_save);
      _bodyCtrl.addListener(_save);
    } catch (e) {
      _error = e.toString();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final note = _note;
    if (note == null) return;
    NoteService.update(note.id, _titleCtrl.text, _bodyCtrl.text);
    note.title = _titleCtrl.text;
    note.body = _bodyCtrl.text;
  }

  // --- Markdown toolbar ----------------------------------------

  /// Wraps the current selection with [prefix] and [suffix]; with
  /// nothing selected, the markers are inserted at the cursor and stay
  /// selected, so typing replaces them directly.
  void _wrapSelection(String prefix, String suffix) {
    final text = _bodyCtrl.text;
    final sel = _bodyCtrl.selection;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final selected = start <= end ? text.substring(start, end) : '';
    _bodyCtrl.value = TextEditingValue(
      text: text.replaceRange(start, end, '$prefix$selected$suffix'),
      selection: TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selected.length,
      ),
    );
  }

  /// Inserts [prefix] at the beginning of the current line (for
  /// headings, lists, quotes). Repeated presses add another level.
  void _insertLinePrefix(String prefix) {
    final text = _bodyCtrl.text;
    final sel = _bodyCtrl.selection;
    final pos = sel.start < 0 ? text.length : sel.start;
    final lineStart = text.lastIndexOf('\n', pos - 1) + 1;
    _bodyCtrl.value = TextEditingValue(
      text: text.replaceRange(lineStart, lineStart, prefix),
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
  }

  /// Empties the marker in front of the cursor again: typing the same
  /// format button twice turns the format off.
  void _toggleLinePrefix(String prefix) {
    final text = _bodyCtrl.text;
    final sel = _bodyCtrl.selection;
    final pos = sel.start < 0 ? text.length : sel.start;
    final lineStart = text.lastIndexOf('\n', pos - 1) + 1;
    if (text.startsWith(prefix, lineStart)) {
      _bodyCtrl.value = TextEditingValue(
        text: text.replaceRange(lineStart, lineStart + prefix.length, ''),
        selection: TextSelection.collapsed(offset: pos - prefix.length),
      );
    } else {
      _insertLinePrefix(prefix);
    }
  }

  Widget _toolbarButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }

  List<Widget> get _toolbarActions => [
        _toolbarButton(
          Icons.format_bold,
          'Fett',
          () => _wrapSelection('**', '**'),
        ),
        _toolbarButton(
          Icons.format_italic,
          'Kursiv',
          () => _wrapSelection('*', '*'),
        ),
        _toolbarButton(
          Icons.strikethrough_s,
          'Durchgestrichen',
          () => _wrapSelection('~~', '~~'),
        ),
        _toolbarButton(
          Icons.code,
          'Code',
          () => _wrapSelection('`', '`'),
        ),
        const VerticalDivider(width: 8, indent: 8, endIndent: 8),
        _toolbarButton(
          Icons.looks_one,
          'Überschrift',
          () => _toggleLinePrefix('# '),
        ),
        _toolbarButton(
          Icons.format_list_bulleted,
          'Aufzählung',
          () => _toggleLinePrefix('- '),
        ),
        _toolbarButton(
          Icons.check_box_outlined,
          'Aufgabe',
          () => _toggleLinePrefix('- [ ] '),
        ),
        _toolbarButton(
          Icons.format_quote,
          'Zitat',
          () => _toggleLinePrefix('> '),
        ),
        const VerticalDivider(width: 8, indent: 8, endIndent: 8),
        _toolbarButton(
          Icons.link,
          'Link',
          () => _wrapSelection('[Text](', ')'),
        ),
        _toolbarButton(
          Icons.table_chart_outlined,
          'Tabelle',
          () => _insertLinePrefix('| A | B |\n| --- | --- |\n|  |  |\n'),
        ),
      ];

  // --- Build ----------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _editMode = !_editMode),
        tooltip: _editMode ? 'Vorschau' : 'Bearbeiten',
        child: Icon(
            _editMode ? Icons.visibility_outlined : Icons.edit_outlined,
          ),
      ),
      appBar: AppBar(
        title: _error != null || _note == null
            ? const Text('Notiz')
            : Text(
                _titleCtrl.text.isEmpty ? 'Notiz' : _titleCtrl.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        actions: [
          if (_error == null && _note != null)
            IconButton(
              tooltip: _editMode ? 'Vorschau' : 'Bearbeiten',
              icon: Icon(
                _editMode ? Icons.visibility_outlined : Icons.edit_outlined,
              ),
              onPressed: () => setState(() => _editMode = !_editMode),
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _titleCtrl,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(
              hintText: 'Titel',
              border: InputBorder.none,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _editMode ? _buildEditor() : _buildPreview(context),
        ),
        if (_editMode)
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: _toolbarActions),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _bodyCtrl,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontFamily: 'monospace', height: 1.4),
        decoration: const InputDecoration(
          hintText: 'Notiz schreiben (Markdown wird unterstützt …)',
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final body = _bodyCtrl.text.trim();
    if (body.isEmpty) {
      return const Center(child: Text('Diese Notiz ist noch leer.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MarkdownBody(
          data: body,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
      ],
    );
  }
}