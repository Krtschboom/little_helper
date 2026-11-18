import 'package:flutter/material.dart';

import '../services/db_service.dart';
import 'checklists_screen.dart';
import 'database_selection_screen.dart';
import 'inventory_screen.dart';
import 'settings_screen.dart';

/// Placeholder main screen shown once the database is connected.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Zur Datenbank-Auswahl',
          icon: const Icon(Icons.storage),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const DatabaseSelectionScreen(),
              ),
            );
          },
        ),
        title: const Text('Home'),
        actions: [
          IconButton(
            tooltip: 'Einstellungen',
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
              size: 64,
            ),
            const SizedBox(height: 12),
            Text(
              'Datenbank verbunden: ${DbService.instance.path}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const InventoryScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Inventory'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ChecklistsScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.checklist),
              label: const Text('Checklists'),
            ),
          ],
        ),
      ),
    );
  }
}
