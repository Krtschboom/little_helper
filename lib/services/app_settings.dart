import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide, persisted visual settings (theme color and mode).
/// MyApp listens to this and rebuilds when something changes.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _colorKey = 'theme_seed_color';
  static const _modeKey = 'theme_mode';

  Color _seedColor = const Color(0xFF00897B); // teal
  ThemeMode _themeMode = ThemeMode.system;

  Color get seedColor => _seedColor;
  ThemeMode get themeMode => _themeMode;

  /// Loads persisted settings at app start.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_colorKey);
    if (colorValue != null) _seedColor = Color(colorValue);
    final modeIndex = prefs.getInt(_modeKey);
    if (modeIndex != null &&
        modeIndex >= 0 &&
        modeIndex < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[modeIndex];
    }
    notifyListeners();
  }

  Future<void> setSeedColor(Color color) async {
    _seedColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_colorKey, color.value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_modeKey, ThemeMode.values.indexOf(mode));
  }
}

/// One entry of the color palette shown in the settings screen.
class ColorOption {
  final String name;
  final Color color;
  const ColorOption(this.name, this.color);
}

/// Preset palette; easy to extend with your own colors.
const settingsPalette = [
  ColorOption('Teal', Color(0xFF00897B)),
  ColorOption('Blau', Color(0xFF1565C0)),
  ColorOption('Indigo', Color(0xFF3F51B5)),
  ColorOption('Lila', Color(0xFF8E24AA)),
  ColorOption('Grün', Color(0xFF2E7D32)),
  ColorOption('Olive', Color(0xFF827717)),
  ColorOption('Orange', Color(0xFFEF6C00)),
  ColorOption('Rot', Color(0xFFC62828)),
  ColorOption('Pink', Color(0xFFC2185B)),
  ColorOption('Braun', Color(0xFF6D4C41)),
  ColorOption('Blau-Grau', Color(0xFF546E7A)),
];