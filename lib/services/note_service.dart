import 'package:sqlite3/sqlite3.dart' show Database;

import 'db_service.dart';

// ===============================================================
// Note storage. Everything lives inside the (encrypted) SQLite file
// in one internal table (`_app_notes`, so the Inventory screen does
// not list it):
//
//   _app_notes   one row per note (title, markdown body)
// ===============================================================

/// A note as stored in `_app_notes`.
class Note {
  Note({
    required this.id,
    required this.title,
    required this.body,
    required this.updatedAt,
    required this.createdAt,
  });

  final int id;
  String title;
  String body;
  final int createdAt;

  /// Milliseconds since epoch of the last change.
  int updatedAt;

  /// First non-empty line of the body with markdown markers stripped,
  /// for use as a list subtitle.
  String get preview {
    for (final raw in body.split('\n')) {
      final line = raw
          .trim()
          .replaceAll(RegExp(r'^#{1,6}\s*'), '')
          .replaceAll(RegExp(r'^>\s*'), '')
          .replaceAll(RegExp(r'^[-*+]\s*(\[[ xX]\]\s*)?'), '')
          .replaceAll(RegExp(r'\*\*|__|~~|`'), '')
          .trim();
      if (line.isNotEmpty) return line;
    }
    return '';
  }
}

class NoteService {
  NoteService._();

  static Database? _readyDb;

  /// The open database; creates the internal table the first time it
  /// is used for a database.
  static Database get _db {
    final db = DbService.instance.database;
    if (!identical(_readyDb, db)) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS _app_notes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      _readyDb = db;
    }
    return db;
  }

  // --- Notes ---------------------------------------------------

  static Note _fromRow(Map<String, Object?> r) => Note(
        id: r['id'] as int,
        title: r['title'] as String,
        body: r['body'] as String,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
      );

  /// All notes, newest change first.
  static List<Note> all() {
    final rows = _db.select(
      'SELECT id, title, body, created_at, updated_at FROM _app_notes '
      'ORDER BY updated_at DESC, id DESC',
    );
    return [for (final r in rows) _fromRow(r)];
  }

  static Note? byId(int id) {
    final rows = _db.select(
      'SELECT id, title, body, created_at, updated_at FROM _app_notes '
      'WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Creates a new empty note and returns its id.
  static int create([String title = 'Neue Notiz']) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO _app_notes (title, body, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      [title, '', now, now],
    );
    return _db.lastInsertRowId;
  }

  /// Saves title and body of [id]. Also called on every change while
  /// the note is open, so a crash never loses more than a few keys.
  static void update(int id, String title, String body) {
    _db.execute(
      'UPDATE _app_notes SET title = ?, body = ?, updated_at = ? WHERE id = ?',
      [title, body, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  static void rename(int id, String title) {
    _db.execute(
      'UPDATE _app_notes SET title = ?, updated_at = ? WHERE id = ?',
      [title, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  static void delete(int id) {
    _db.execute('DELETE FROM _app_notes WHERE id = ?', [id]);
  }
}