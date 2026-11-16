import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// Settings page: app colors, light/dark mode and more.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // What the OS currently requests - shown next to "System" so
    // switching between System and Hell/Dunkel is never confusing.
    final systemIsDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      // ListenableBuilder rebuilds the whole list whenever a setting
      // changes, so the selected color and mode are always up to date.
      body: ListenableBuilder(
        listenable: AppSettings.instance,
        builder: (context, _) {
          final settings = AppSettings.instance;
          return ListView(
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
                      selected: settings.seedColor.toARGB32() ==
                          option.color.toARGB32(),
                      onTap: () => settings.setSeedColor(option.color),
                    ),
                ],
              ),
              const Divider(height: 32),
              Text(
                'Erscheinungsbild',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto),
                    label: Text('System'),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode),
                    label: Text('Hell'),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode),
                    label: Text('Dunkel'),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (selection) =>
                    settings.setThemeMode(selection.first),
              ),
              if (settings.themeMode == ThemeMode.system)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Folgt dem Betriebssystem '
                    '(derzeit: ${systemIsDark ? 'dunkel' : 'hell'})',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const Divider(height: 32),
              // Room for further settings:
              // ListTile(leading: Icon(Icons.info), title: Text('Über die App')),
            ],
          );
        },
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
