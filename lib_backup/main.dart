import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'services/app_settings.dart';
import 'services/config_service.dart';
import 'services/db_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // No database factory setup needed: package:sqlite3 v3.x loads its
  // native library automatically via Dart build hooks.

  // Load persisted visual settings (colors etc.) before first frame.
  await AppSettings.instance.load();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return MaterialApp(
      title: 'Little Helper',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: settings.seedColor,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: settings.seedColor,
        brightness: Brightness.dark,
      ),
      themeMode: settings.themeMode,
      home: const GatekeeperScreen(),
    );
  }
}

/// Decides which screen to show: setup (no DB configured) or home.
class GatekeeperScreen extends StatefulWidget {
  const GatekeeperScreen({super.key});

  @override
  State<GatekeeperScreen> createState() => _GatekeeperScreenState();
}

class _GatekeeperScreenState extends State<GatekeeperScreen> {
  late Future<Widget> _future;

  @override
  void initState() {
    super.initState();
    _future = _decide();
  }

  Future<Widget> _decide() async {
    final config = ConfigService();
    final path = await config.getDatabasePath();

    // No saved path, or the file no longer exists -> setup screen.
    if (path == null || !DbService.databaseFileExists(path)) {
      return const SetupScreen();
    }

    try {
      // Try without a password first (plain database).
      await DbService.instance.open(path);
      return const HomeScreen();
    } catch (_) {
      // Maybe a remembered session password is still valid.
      final remembered = DbService.instance.rememberedPassword;
      if (remembered != null) {
        try {
          await DbService.instance.open(path, password: remembered);
          return const HomeScreen();
        } catch (_) {
          // No longer valid -> ask the user below.
        }
      }
      final result = await _promptPassword();
      if (result == null || result.password.isEmpty) {
        return const SetupScreen(
          initialError:
              'Die Datenbank ist passwortgeschützt.\n'
              'Bitte eine Datenbank öffnen und das Passwort eingeben.',
        );
      }
      try {
        await DbService.instance.open(
          path,
          password: result.password,
          remember: result.remember,
        );
        return const HomeScreen();
      } catch (e) {
        return SetupScreen(
          initialError: 'Falsches Passwort:\n$e',
        );
      }
    }
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
              child: const Text('Öffnen'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) return snapshot.data!;
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}