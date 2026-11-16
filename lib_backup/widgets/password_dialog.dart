import 'package:flutter/material.dart';

import '../services/db_service.dart';

/// What the user entered in the password dialog.
typedef PasswordResult = ({String password, bool remember});

/// Asks the user for a database password.
/// Returns null if the dialog was cancelled.
Future<PasswordResult?> showPasswordDialog(
  BuildContext context, {
  String title = 'Passwort erforderlich',
  String hint = 'Datenbank-Passwort',
}) {
  return showDialog<PasswordResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PasswordDialog(title: title, hint: hint),
  );
}

/// Opens the database at [path] in the way the whole app needs it:
///   1. without a password (plain database),
///   2. with the password remembered for this session (if any),
///   3. by asking the user (again and again after a wrong password,
///      until it works or the user cancels).
///
/// Returns true if the database is open afterwards, false if the user
/// cancelled. This replaces the three copies of this logic that used
/// to live in main.dart, setup_screen.dart and
/// database_selection_screen.dart.
Future<bool> openDatabaseWithPrompt(BuildContext context, String path) async {
  final db = DbService.instance;

  try {
    await db.open(path);
    return true;
  } catch (_) {
    // Probably encrypted -> try the next option.
  }

  final remembered = db.rememberedPassword;
  if (remembered != null) {
    try {
      await db.open(path, password: remembered);
      return true;
    } catch (_) {
      // Remembered password does not fit this file -> ask the user.
    }
  }

  var wrongPassword = false;
  while (context.mounted) {
    final result = await showPasswordDialog(
      context,
      title: wrongPassword
          ? 'Falsches Passwort - nochmal versuchen'
          : 'Passwort erforderlich',
    );
    if (result == null || result.password.isEmpty) return false;
    try {
      await db.open(
        path,
        password: result.password,
        remember: result.remember,
      );
      return true;
    } catch (_) {
      wrongPassword = true;
    }
  }
  return false;
}

/// The dialog is its own widget so that it owns (and disposes) its
/// TextEditingController safely.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();
  bool _remember = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, (password: _controller.text, remember: _remember));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => _submit(),
          ),
          CheckboxListTile(
            value: _remember,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('In dieser Sitzung merken'),
            subtitle: const Text(
              'Nur im Arbeitsspeicher, bis die App beendet wird',
            ),
            onChanged: (v) => setState(() => _remember = v ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Öffnen'),
        ),
      ],
    );
  }
}
