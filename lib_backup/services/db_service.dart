import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Thin wrapper around package:sqlite3 with SQLCipher support.
class DbService {
  DbService._();
  static final DbService instance = DbService._();

  Database? _db;
  String? _path;

  /// The database password, kept in memory only while the database is
  /// open. Never persisted to disk; wiped by [close].
  String? _password;

  /// Password the user asked to remember for this app session.
  /// Survives [close] (so the DB can be reopened without re-asking),
  /// lives only in RAM and disappears when the app process ends.
  String? _rememberedPassword;

  String? get rememberedPassword => _rememberedPassword;

  /// Forgets the session password (e.g. when the user closes the
  /// database deliberately).
  void forgetPassword() => _rememberedPassword = null;

  Database get database {
    final db = _db;
    if (db == null) {
      throw StateError('Database not opened yet');
    }
    return db;
  }

  /// Path of the currently open database (null if none).
  String? get path => _path;

  static bool databaseFileExists(String path) => File(path).existsSync();

  /// Quotes a table or column name for use inside SQL. A `"` inside
  /// the name is doubled, so odd names cannot break the statement.
  static String quoteIdentifier(String name) =>
      '"${name.replaceAll('"', '""')}"';

  // --- App column type metadata -------------------------------
  // SQLite has no native DATUM/BOOLEAN types, so the app remembers
  // which display type each column was given at table creation time.

  void ensureAppTypesTable() {
    _db?.execute('''
      CREATE TABLE IF NOT EXISTS _app_column_types (
        table_name TEXT NOT NULL,
        column_name TEXT NOT NULL,
        type TEXT NOT NULL,
        PRIMARY KEY (table_name, column_name)
      )
    ''');
  }

  void recordColumnType(String table, String column, String type) {
    ensureAppTypesTable();
    database.execute(
      'INSERT OR REPLACE INTO _app_column_types '
      '(table_name, column_name, type) VALUES (?, ?, ?)',
      [table, column, type],
    );
  }

  void deleteColumnType(String table, String column) {
    try {
      database.execute(
        'DELETE FROM _app_column_types '
        'WHERE table_name = ? AND column_name = ?',
        [table, column],
      );
    } catch (_) {
      // Metadata is optional; ignore cleanup errors.
    }
  }

  /// Returns the app display type ('DATUM', 'BOOLEAN', 'TEXT', ...)
  /// or null if nothing was recorded.
  String? columnType(String table, String column) {
    try {
      final result = database.select(
        'SELECT type FROM _app_column_types '
        'WHERE table_name = ? AND column_name = ?',
        [table, column],
      );
      return result.isEmpty ? null : result.first['type'] as String;
    } catch (_) {
      return null;
    }
  }

  /// All recorded app types of one table in a single query
  /// (column name -> type). Empty if nothing was recorded.
  Map<String, String> columnTypesFor(String table) {
    try {
      final result = database.select(
        'SELECT column_name, type FROM _app_column_types '
        'WHERE table_name = ?',
        [table],
      );
      return {
        for (final r in result) r['column_name'] as String: r['type'] as String,
      };
    } catch (_) {
      return {};
    }
  }

  /// Moves the recorded column types along when a table is renamed.
  void renameTableTypes(String oldName, String newName) {
    try {
      database.execute(
        'UPDATE _app_column_types SET table_name = ? WHERE table_name = ?',
        [newName, oldName],
      );
    } catch (_) {
      // Metadata is optional; ignore errors.
    }
  }

  /// Removes the recorded column types of a dropped table.
  void deleteTableTypes(String table) {
    try {
      database.execute(
        'DELETE FROM _app_column_types WHERE table_name = ?',
        [table],
      );
    } catch (_) {
      // Metadata is optional; ignore errors.
    }
  }

  /// Escapes a password for use inside a PRAGMA string literal.
  static String _escape(String s) => s.replaceAll("'", "''");

  /// Opens an existing (encrypted or plain) database file.
  /// If [password] is null/empty the file is opened unencrypted.
  /// If [remember] is true, the password is kept in memory for this
  /// app session so the database can be reopened without asking again.
  ///
  /// Throws if the file cannot be read with the given password.
  Future<void> open(String path,
      {String? password, bool remember = false}) async {
    await close();
    final db = sqlite3.open(path);
    try {
      if (password != null && password.isNotEmpty) {
        db.execute("PRAGMA key = '${_escape(password)}'");
      }
      // Actually read from the file. This is what fails with
      // "file is not a database" when the key is wrong (or missing
      // for an encrypted file). PRAGMA cipher_version would NOT fail,
      // because it never touches the file.
      db.select('SELECT count(*) FROM sqlite_master');
    } catch (e) {
      db.dispose();
      rethrow;
    }
    _db = db;
    _path = path;
    _password = (password != null && password.isNotEmpty) ? password : null;
    if (remember && _password != null) {
      _rememberedPassword = _password;
    }
    _tryEnsureAppTypesTable();
  }

  /// Creates a new database in [directory] (encrypted if [password]
  /// is given, plain otherwise) and initializes the base schema.
  /// [fileName] gets a ".db" extension if it has none.
  Future<void> create({
    required String directory,
    required String fileName,
    String? password,
  }) async {
    await close();
    var name = fileName.trim();
    if (name.isEmpty || p.basename(name) != name) {
      throw StateError('Ungültiger Dateiname: $fileName');
    }
    if (p.extension(name).isEmpty) name = '$name.db';

    final path = p.join(directory, name);
    if (File(path).existsSync()) {
      throw StateError('Datei existiert bereits: $name');
    }

    final db = sqlite3.open(path);
    try {
      final encrypted = password != null && password.isNotEmpty;
      if (encrypted) {
        db.execute("PRAGMA key = '${_escape(password)}'");
        // Verify that SQLCipher is really linked in. With plain SQLite
        // PRAGMA key is silently ignored and the file would NOT be
        // encrypted although the user typed a password.
        final version = db.select('PRAGMA cipher_version');
        if (version.isEmpty ||
            (version.first.values.first as String?)?.isNotEmpty != true) {
          throw StateError(
            'Verschlüsselung nicht verfügbar: SQLCipher ist nicht '
            'eingebunden (siehe hooks/user_defines in der pubspec.yaml).',
          );
        }
      }

      // --- your initial schema goes here ---
      db.execute('''
        CREATE TABLE notes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
    } catch (e) {
      db.dispose();
      File(path).deleteSync(); // clean up broken file
      rethrow;
    }
    _db = db;
    _path = path;
    _password = (password != null && password.isNotEmpty) ? password : null;
    _tryEnsureAppTypesTable();
  }

  /// Creates the metadata table once per open database, so the
  /// getters above do not have to do it on every call. Failing (e.g.
  /// read-only file) is fine: metadata is optional.
  void _tryEnsureAppTypesTable() {
    try {
      ensureAppTypesTable();
    } catch (_) {}
  }

  Future<void> close() async {
    _db?.dispose();
    _db = null;
    _path = null;
    _password = null; // wipe the open-database password
    // _rememberedPassword deliberately survives close() so the user
    // can reopen the same database in this session.
  }
}
