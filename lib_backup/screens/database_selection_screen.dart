import 'package:flutter/material.dart';

import '../services/config_service.dart';
import '../services/db_service.dart';
import '../widgets/password_dialog.dart';
import 'setup_screen.dart';

/// Reached via the storage icon on the home screen. Shows the current
/// database and lets the user reopen it or close it (closing leads
/// back to the setup screen).
class DatabaseSelectionScreen extends StatefulWidget {
  const DatabaseSelectionScreen({super.key});

  @override
  State<DatabaseSelectionScreen> createState() =>
      _DatabaseSelectionScreenState();
}

class _DatabaseSelectionScreenState extends State<DatabaseSelectionScreen> {
  String? _error;

  Future<void> _reopen() async {
    final path = await ConfigService().getDatabasePath();
    if (path == null || !mounted) return;

    if (!DbService.databaseFileExists(path)) {
      setState(() => _error = 'Datei nicht gefunden:\n$path');
      return;
    }

    // Plain -> remembered password -> ask the user (shared logic).
    final opened = await openDatabaseWithPrompt(context, path);
    if (!mounted) return;

    if (opened) {
      // The home screen is still below this screen in the navigation
      // stack, so just go back to it (no duplicate home screens).
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _close() async {
    await DbService.instance.close();
    DbService.instance.forgetPassword(); // deliberately closed
    await ConfigService().clear();
    if (!mounted) return;
    // Remove the ENTIRE navigation stack (home screen etc.), so the
    // back button cannot lead into screens whose database is closed.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SetupScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = DbService.instance.path;
    return Scaffold(
      appBar: AppBar(title: const Text('Datenbank')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: colors.error)),
                  const SizedBox(height: 16),
                ],
                Icon(Icons.storage, size: 64, color: colors.primary),
                const SizedBox(height: 8),
                Text(
                  path ?? 'Keine Datenbank geöffnet',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _reopen,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Diese Datenbank öffnen'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _close,
                  icon: const Icon(Icons.lock),
                  label: const Text('Datenbank schließen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
