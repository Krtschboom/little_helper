import 'package:flutter/material.dart';

import '../services/config_service.dart';
import '../services/db_service.dart';
import 'home_screen.dart';
import 'setup_screen.dart';

/// Reached via the back arrow on the home screen. Shows the current
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
    if (path == null) return;

    try {
      // Try with the remembered session password first.
      await DbService.instance.open(
        path,
        password: DbService.instance.rememberedPassword,
      );
      _toHome();
    } catch (_) {
      // Encrypted and no valid remembered password -> ask.
      final result = await _promptPassword();
      if (result == null || result.password.isEmpty) return;
      try {
        await DbService.instance.open(
          path,
          password: result.password,
          remember: result.remember,
        );
        _toHome();
      } catch (e) {
        setState(() => _error = 'Falsches Passwort:\n$e');
      }
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

  void _toHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  Future<({String password, bool remember})?> _promptPassword() {
    final controller = TextEditingController();
    bool remember = true;
    return showDialog<({String password, bool remember})>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Passwort erforderlich'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'Datenbank-Passwort',
                ),
              ),
              CheckboxListTile(
                value: remember,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('In dieser Sitzung merken'),
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
              child: const Text('Öffnen'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                ],
                Icon(Icons.storage, size: 64, color: Colors.teal.shade400),
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