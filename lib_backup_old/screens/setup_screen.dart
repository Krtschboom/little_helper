
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/config_service.dart';
import '../services/db_service.dart';
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
      final result = await FilePicker.platform.pickFiles(
        // IMPORTANT: FileType.custom with allowedExtensions is broken
        // on Linux (the picker returns null / never resolves after a
        // file is chosen). FileType.any works on all platforms; the
        // extension is checked manually below.
        type: FileType.any,
        withData: false,
      );
      if (result == null) {
        // User closed the picker without choosing anything.
        return;
      }
      if (result.files.isEmpty || result.files.single.path == null) {
        _showError('Es konnte kein Dateipfad ermittelt werden.\n'
            'Bitte die Datei erneut auswählen.');
        return;
      }

      final path = result.files.single.path!;

      final password = await _askPasswordIfNeeded(path);
      if (password == null && _pickerCancelled) return; // user cancelled
      if (DbService.instance.path == null) return; // open failed

      await ConfigService().setDatabase(path);
      if (mounted) _goHome();
    } catch (e) {
      _showError('Öffnen fehlgeschlagen:\n$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _pickerCancelled = false;

  /// Returns the password to use (null for a plain file); null also
  /// means "user cancelled".
  Future<String?> _askPasswordIfNeeded(String path) async {
    _pickerCancelled = false;
    try {
      // Unencrypted open attempt.
      await DbService.instance.open(path);
      return null;
    } catch (_) {
      // Encrypted (or unreadable) -> ask for password.
      final result = await _promptPassword(
        title: 'Passwort erforderlich',
        hint: 'Diese Datei ist verschlüsselt',
      );
      if (result == null || result.password.isEmpty) {
        _pickerCancelled = true;
        return null;
      }
      try {
        await DbService.instance.open(
          path,
          password: result.password,
          remember: result.remember,
        );
        return result.password;
      } catch (_) {
        if (mounted) {
          _showError('Falsches Passwort oder ungültige Datei.');
        }
        return null;
      }
    }
  }

  Future<void> _createNew() async {
    final fields = await _promptNewDatabase();
    if (fields == null) return;

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

  Future<({String password, bool remember})?> _promptPassword({
    String title = 'Passwort',
    String hint = 'Passwort',
  }) {
    final controller = TextEditingController();
    bool remember = true;
    return showDialog<({String password, bool remember})>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                decoration: InputDecoration(hintText: hint),
              ),
              CheckboxListTile(
                value: remember,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('In dieser Sitzung merken'),
                subtitle: const Text(
                  'Nur im Arbeitsspeicher, bis die App beendet wird',
                ),
                onChanged: (v) =>
                    setDialogState(() => remember = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                (password: controller.text, remember: remember),
              ),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  Future<({String fileName, String password})?> _promptNewDatabase() {
    final nameCtrl = TextEditingController(text: 'mydata.db');
    final pwCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<({String fileName, String password})>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Neue Datenbank erstellen'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Dateiname',
                    hintText: 'mydata.db',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Erforderlich' : null,
                ),
                TextFormField(
                  controller: pwCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Passwort (optional)',
                    helperText: 'Leer lassen für eine unverschlüsselte Datenbank',
                  ),
                ),
                TextFormField(
                  controller: confirmCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Passwort bestätigen',
                  ),
                  validator: (v) =>
                      v != pwCtrl.text ? 'Passwörter stimmen nicht überein' : null,
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
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, (
                  fileName: nameCtrl.text.trim(),
                  password: pwCtrl.text,
                ));
              }
            },
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  Text(error, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                ],
                Icon(Icons.storage, size: 64, color: Colors.teal.shade400),
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