import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'services/app_settings.dart';
import 'services/config_service.dart';
import 'services/db_service.dart';
import 'widgets/password_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // No database factory setup needed: package:sqlite3 v3.x loads its
  // native library automatically via Dart build hooks.

  // Load persisted visual settings (colors etc.) before first frame.
  await AppSettings.instance.load();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ListenableBuilder rebuilds the MaterialApp whenever the settings
    // change (replaces the manual addListener/setState).
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        final settings = AppSettings.instance;
        return MaterialApp(
          title: 'Little Helper',
          // The whole UI is German, so the built-in widgets (date
          // picker, dialogs, ...) should be German too.
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
      },
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
    try {
      final path = await ConfigService().getDatabasePath();

      // No saved path, or the file no longer exists -> setup screen.
      if (path == null || !DbService.databaseFileExists(path)) {
        return const SetupScreen();
      }
      if (!mounted) return const SizedBox.shrink();

      // Plain -> remembered password -> ask the user.
      final opened = await openDatabaseWithPrompt(context, path);
      if (opened) return const HomeScreen();

      return const SetupScreen(
        initialError: 'Die Datenbank ist passwortgeschützt.\n'
            'Bitte eine Datenbank öffnen und das Passwort eingeben.',
      );
    } catch (e) {
      // Without this, an unexpected error would leave the loading
      // spinner on screen forever.
      return SetupScreen(initialError: 'Unerwarteter Fehler:\n$e');
    }
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
