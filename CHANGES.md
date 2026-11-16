# Little Helper - changes

Copy the contents of `lib/` over your project's `lib/` folder
(keep the same sub-folders: screens, services, widgets).

(flutter_localizations is already in your pubspec.yaml - nothing to add.)

## New file
- lib/widgets/password_dialog.dart - ONE password dialog + ONE
  "open database (plain -> remembered password -> ask)" function that
  main.dart, setup_screen.dart and database_selection_screen.dart now share.

## Bug fixes
- db_service.dart: wrong password is now detected when opening
  (reads sqlite_master instead of PRAGMA cipher_version).
- table_editor_screen.dart: column types are read case-insensitively
  (a column declared `integer` is now parsed as a number).
- inventory_screen.dart: the table list hid tables like "mapping" or
  "happy" because `_` is a wildcard in LIKE -> escaped.
- inventory_screen.dart: CSV export now writes real UTF-8 (umlauts!)
  and uses a StringBuffer (fast for big tables).
- inventory_screen.dart: renaming/dropping a table now also moves/removes
  its saved DATUM/BOOLEAN types.
- app_settings.dart / settings_screen.dart: Color.value -> toARGB32().
- database_selection_screen.dart: reopening no longer stacks a second
  home screen; it just goes back.
- main.dart: no endless spinner on unexpected errors; mounted checks.
- Table/column names with a `"` in them no longer break SQL (quoteIdentifier).
- New database: file name is validated (no paths), `.db` added if missing.

## Performance (search/sort)
- Filter + sort result is cached and only recomputed when needed
  (it used to run twice per build).
- Search text and sort keys are precomputed; search is debounced (250 ms).
- DataTable replaced by a lazy ListView with a pinned header
  (columns have a fixed width: `_colWidth` in table_editor_screen.dart).
- Editing/deleting a row updates it in memory instead of reloading the table.
- Column types are loaded with one query instead of one per cell.

## UI
- German locale for built-in widgets (date picker etc.).
- Theme: hard-coded teal/red replaced by the theme's primary/error colors.
- Settings: ListenableBuilder + SegmentedButton for light/dark/system.
- Dialogs with text fields are their own widgets (controllers are
  disposed safely).

## Round 2
- NEW: +/- counter columns. When you pick INTEGER (new table, new column
  in the column editor, or CSV import) a checkbox "Plus-/Minus-Buttons in
  der Tabelle" appears. Such a column is shown as  [-]  value  [+]  in the
  table editor; tapping the value still lets you type a number.
  In the column editor you can also switch the buttons on/off for
  EXISTING integer columns. Stored as app type 'COUNTER' (SQLite: INTEGER).
  The +/- buttons update only that row and do not re-sort the list.
- Inventory dialogs (new table, column editor, rename table, CSV import)
  are now their own widgets that dispose their controllers safely.
- Fixed: removing a column in the "new table" dialog could show the wrong
  type in the dropdowns (rows now have keys).
- Column editor is all-or-nothing now (one transaction).
- db_service.create(): with a password it now checks that SQLCipher is
  really linked in (PRAGMA cipher_version) and refuses otherwise.
