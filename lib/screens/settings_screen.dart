import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// Settings page: app colors, light/dark mode and more.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    // What the OS currently requests — shown under "Systemeinstellung"
    // so switching between System and Dunkel/Hell is never confusing.
    final systemIsDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Farbe', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Bestimmt die Grundfarbe der App (Buttons, Akzente etc.).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final option in settingsPalette)
                _ColorSwatch(
                  option: option,
                  selected: settings.seedColor.value == option.color.value,
                  onTap: () => settings.setSeedColor(option.color),
                ),
            ],
          ),
          const Divider(height: 32),
          Text(
            'Erscheinungsbild',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          // AnimatedBuilder rebuilds the list itself whenever the
          // settings change, so the selected option is always shown
          // immediately, independent of the rest of the app.
          AnimatedBuilder(
            animation: AppSettings.instance,
            builder: (context, _) {
              final settings = AppSettings.instance;
              return Column(
                children: [
                  for (final mode in ThemeMode.values)
                    ListTile(
                      leading: Icon(
                        settings.themeMode == mode
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(switch (mode) {
                        ThemeMode.system => 'Systemeinstellung',
                        ThemeMode.light => 'Hell',
                        ThemeMode.dark => 'Dunkel',
                      }),
                      subtitle: mode == ThemeMode.system
                          ? Text(
                              'Folgt dem Betriebssystem '
                              '(derzeit: ${systemIsDark ? 'dunkel' : 'hell'})',
                            )
                          : null,
                      onTap: () => settings.setThemeMode(mode),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 32),
          // Room for further settings:
          // ListTile(leading: Icon(Icons.info), title: Text('Über die App')),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ColorOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: option.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.transparent,
                width: 3,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white)
                : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          option.name,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}