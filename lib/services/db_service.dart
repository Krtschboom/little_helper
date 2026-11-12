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
      ensureAppTypesTable();
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
      ensureAppTypesTable();
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

  /// Escapes a password for use inside a PRAGMA string literal.
  static String _escape(String s) => s.replaceAll("'", "''");

  /// Opens an existing (encrypted or plain) database file.
  /// If [password] is null/empty the file is opened unencrypted.
  /// If [remember] is true, the password is kept in memory for this
  /// app session so the database can be reopened without asking again.
  Future<void> open(String path,
      {String? password, bool remember = false}) async {
    await close();
    final db = sqlite3.open(path);
    try {
      if (password != null && password.isNotEmpty) {
        db.execute("PRAGMA key = '${_escape(password)}'");
        db.select('SELECT count(*) FROM sqlite_master'); // throws on wrong key
      } else {
        db.select('SELECT count(*) FROM sqlite_master');
      }

      // if (password != null && password.isNotEmpty) {
      //   db.execute("PRAGMA key = '${_escape(password)}'");
      //   // Throws SqliteException when the key is wrong.
      //   db.select('PRAGMA cipher_version');
      // } else {
      //   // Plain file: accessing the schema throws if it is actually
      //   // encrypted ("file is not a database").
      //   db.select('PRAGMA schema_version');
      // }
    } catch (e) {
      db.close();
      rethrow;
    }
    _db = db;
    _path = path;
    _password = (password != null && password.isNotEmpty) ? password : null;
    if (remember && _password != null) {
      _rememberedPassword = _password;
    }
  }

  /// Creates a new database at [path] (encrypted if [password] is
  /// given, plain otherwise) and initializes the base schema.
  Future<void> create({
    required String directory,
    required String fileName,
    String? password,
  }) async {
    await close();
    final path = p.join(directory, fileName);
    if (File(path).existsSync()) {
      throw StateError('Datei existiert bereits: $fileName');
    }

    final db = sqlite3.open(path);
    try {
      final encrypted = password != null && password.isNotEmpty;
      if (encrypted) {
        db.execute("PRAGMA key = '${_escape(password)}'");
        db.select('PRAGMA cipher_version'); // verify encryption works
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
      db.close();
      File(path).deleteSync(); // clean up broken file
      rethrow;
    }
    _db = db;
    _path = path;
    _password = (password != null && password.isNotEmpty) ? password : null;
  }

  Future<void> close() async {
    _db?.close();
    _db = null;
    _path = null;
    _password = null; // wipe the open-database password
    // _rememberedPassword deliberately survives close() so the user
    // can reopen the same database in this session.
  }
}