import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/config_service.dart';
import '../services/db_service.dart';
import '../widgets/password_dialog.dart';
import 'home_screen.dart';

/// First-run screen shown when no database is configured yet.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, this.initialError});

  /// Error message from a previous failed open attempt, if any.
  final String? initialError;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _busy = false;

  Future<void> _openExisting() async {
    setState(() => _busy = true);
    try {
            // IMPORTANT: FileType.custom with allowedExtensions is broken
      // on Linux (the picker returns null / never resolves after a
      // file is chosen). FileType.any works on all platforms.
      final files = await FilePicker.pickFiles(
        type: FileType.any,
      );

      // User closed the picker without choosing anything
      // (v13 returns an empty list instead of null).
      if (files.isEmpty) {
        return;
      }

      final path = files.first.path;
      if (path == null) {
        _showError('Es konnte kein Dateipfad ermittelt werden.\n'
            'Bitte die Datei erneut auswählen.');
        return;
      }

      if (!mounted) return;
      // final result = await FilePicker.platform.pickFiles(
      //   // IMPORTANT: FileType.custom with allowedExtensions is broken
      //   // on Linux (the picker returns null / never resolves after a
      //   // file is chosen). FileType.any works on all platforms.
      //   type: FileType.any,
      //   withData: false,
      // );
      // if (result == null) {
      //   // User closed the picker without choosing anything.
      //   return;
      // }
      // final path = result.files.isEmpty ? null : result.files.first.path;
      // if (path == null) {
      //   _showError('Es konnte kein Dateipfad ermittelt werden.\n'
      //       'Bitte die Datei erneut auswählen.');
      //   return;
      // }
      // if (!mounted) return;

      // Plain -> remembered password -> ask the user (shared logic).
      // Returns false if the user cancelled.
      final opened = await openDatabaseWithPrompt(context, path);
      if (!opened) return;

      await ConfigService().setDatabase(path);
      if (mounted) _goHome();
    } catch (e) {
      _showError('Öffnen fehlgeschlagen:\n$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createNew() async {
    final fields = await showDialog<({String fileName, String password})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _NewDatabaseDialog(),
    );
    if (fields == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      await DbService.instance.create(
        directory: dir.path,
        fileName: fields.fileName,
        password: fields.password,
      );
      await ConfigService().setDatabase(DbService.instance.path!);
      if (mounted) _goHome();
    } catch (e) {
      _showError('Erstellen fehlgeschlagen:\n$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fehler'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final error = widget.initialError;
    return Scaffold(
      appBar: AppBar(title: const Text('Datenbank einrichten')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null) ...[
                  Text(error, style: TextStyle(color: colors.error)),
                  const SizedBox(height: 16),
                ],
                Icon(Icons.storage, size: 64, color: colors.primary),
                const SizedBox(height: 8),
                Text(
                  'Keine Datenbank vorhanden.\nBitte eine bestehende öffnen oder eine neue erstellen.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _busy ? null : _openExisting,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Bestehende Datenbank öffnen'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _createNew,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Neue Datenbank erstellen'),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Create new database" dialog. It is its own widget so it owns and
/// disposes its text controllers safely.
class _NewDatabaseDialog extends StatefulWidget {
  const _NewDatabaseDialog();

  @override
  State<_NewDatabaseDialog> createState() => _NewDatabaseDialogState();
}

class _NewDatabaseDialogState extends State<_NewDatabaseDialog> {
  final _nameCtrl = TextEditingController(text: 'mydata.db');
  final _pwCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, (
      fileName: _nameCtrl.text.trim(),
      password: _pwCtrl.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Neue Datenbank erstellen'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dateiname',
                  hintText: 'mydata.db',
                ),
                validator: (v) {
                  final name = v?.trim() ?? '';
                  if (name.isEmpty) return 'Erforderlich';
                  if (name.contains('/') || name.contains('\\')) {
                    return 'Nur ein Dateiname, kein Pfad';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _pwCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passwort (optional)',
                  helperText: 'Leer lassen für eine unverschlüsselte Datenbank',
                ),
              ),
              TextFormField(
                controller: _confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passwort bestätigen',
                ),
                validator: (v) =>
                    v != _pwCtrl.text ? 'Passwörter stimmen nicht überein' : null,
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
          child: const Text('Erstellen'),
        ),
      ],
    );
  }
}
