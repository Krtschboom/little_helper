import 'package:flutter/material.dart';

import '../services/note_service.dart';
import '../widgets/text_prompt_dialog.dart';
import 'note_editor_screen.dart';

/// Lists all notes. The plus button creates a new one and opens the
/// editor; a note is opened by tapping it.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Note> _notes = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() {
        _notes = NoteService.all();
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

  Future<void> _create() async {
    try {
      final id = NoteService.create();
      if (!mounted) return;
      await _openNote(id);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openNote(int id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: id)),
    );
    if (mounted) _load(); // title / preview may have changed
  }

  Future<void> _rename(Note note) async {
    final name = await showTextPrompt(
      context,
      title: 'Notiz umbenennen',
      label: 'Neuer Name',
      initial: note.title,
      confirmLabel: 'Umbenennen',
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      NoteService.rename(note.id, name);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Notiz "${note.title}" löschen?'),
        content: const Text('Die Notiz wird endgültig gelöscht.'),
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
    if (confirmed != true || !mounted) return;
    try {
      NoteService.delete(note.id);
      _load();
    } catch (e) {
      _showError(e);
    }
  }

  String _dateLabel(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}, '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        tooltip: 'Neue Notiz',
        child: const Icon(Icons.add),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            )
          : _notes.isEmpty
              ? const Center(child: Text('Noch keine Notizen vorhanden.'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _notes.length,
                  itemBuilder: (context, i) {
                    final note = _notes[i];
                    final preview = note.preview;
                    return ListTile(
                      leading: const Icon(Icons.note_outlined),
                      title: Text(
                        note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_dateLabel(note.updatedAt),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: preview.isNotEmpty,
                      onTap: () => _openNote(note.id),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (action) {
                          switch (action) {
                            case 'rename':
                              _rename(note);
                            case 'delete':
                              _delete(note);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Umbenennen'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Löschen'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}