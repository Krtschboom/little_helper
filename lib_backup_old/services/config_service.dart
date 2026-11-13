import 'package:shared_preferences/shared_preferences.dart';

/// Stores app configuration. Only the database PATH is persisted.
/// The password is deliberately never written to disk: it lives in
/// memory (DbService) while the database is open and is wiped on close.
class ConfigService {
  static const _dbPathKey = 'database_path';
  // Legacy key from older versions; removed if present.
  static const _legacyDbPasswordKey = 'database_password';

  Future<String?> getDatabasePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_dbPathKey);
  }

  Future<void> setDatabase(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dbPathKey, path);
    // Clean up passwords stored by older app versions.
    await prefs.remove(_legacyDbPasswordKey);
  }

  /// Forget the saved database (used by a "change database" action).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dbPathKey);
    await prefs.remove(_legacyDbPasswordKey);
  }
}