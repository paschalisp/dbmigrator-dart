import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// The result record returned after executing a database migration.
///
/// **Properties:**
/// - [started] - The [DateTime] when the migration process began execution
/// - [completed] - The [DateTime] when the migration process finished execution
/// - [message] - A human-readable description of the migration result, including
///   duration and version transition (e.g., "Migrated from 1.0.0 ➡ 2.0.0 in 3 seconds.")
/// - [upgrade] - `true` if the migration was an upgrade (moving to a newer version),
///   `false` if it was a downgrade (reverting to an older version)
/// - [path] - The name of the migrations directory that was processed
/// - [fromVersion] - The database version before migration started (empty string if no prior version)
/// - [toVersion] - The database version after migration completed
/// - [files] - The complete list of all the migration files that were successfully executed, each containing:
///   - `name` - The file name (with relative path from the migrations directory)
///   - `checksum` - The SHA-256 checksum of the file contents (if checksums are enabled)
/// - [checksum] - The migration files' checksum of the target database version ([toVersion]). Empty if checksums are not enabled.
///
/// **Example:**
/// ```dart
/// final result = await db.migrate(version: '2.0.0');
/// print('Migrated from ${result.fromVersion} to ${result.toVersion} (${result.direction.name})');
/// print('Executed files: ${result.files.map((f) => f.name).join(", ")}');
/// print('Duration: ${result.completed.difference(result.started).inSeconds} seconds');
/// ```
typedef MigrationResult = ({
  DateTime started,
  DateTime completed,
  String message,
  MigrationDirection direction,
  String path,
  String fromVersion,
  String toVersion,
  String checksum,
  List<({String name, String checksum})> files,
});

/// A mixin that provides database migration functionality with support for semantic versioning.
///
/// This mixin enables database migration capabilities for any class that implements the required
/// abstract methods. It supports both upgrade and downgrade operations, version tracking with
/// optional checksums, and two organizational modes for migration files.
///
/// **Migration Organization:**
/// - **File-based**: Migration files named with semantic versions (e.g., `1.0.0.sql`, `1.2.0-beta_schema.sql`)
/// - **Directory-based**: Migrations organized in version-named directories (e.g., `migrations/1.0.0/init.sql`)
///
/// **Key Features:**
/// - Semantic versioning support using the [pub_semver](https://pub.dev/packages/pub_semver) package
/// - Automatic detection of upgrade/downgrade paths based on current and target versions
/// - Optional SHA-256 checksum verification for migration integrity
/// - Transaction-based execution to ensure atomicity
/// - Configurable retry logic and timeouts
/// - Support for custom file naming patterns via regex
///
/// **Implementation Requirements:**
/// Classes using this mixin must implement:
/// - [migrationOptions] - Configuration for migration behavior
/// - [queryVersion] - Retrieve current database version and checksum
/// - [saveVersion] - Store the new migration history status to the database
/// - [transaction] - Execute operations within a database transaction
/// - [execute] - Execute a command or statement against the database
///
/// Classes using this mixin can optionally override:
/// - [isRetryable] - Determine if an error should trigger a retry
/// - [acquireLock] - Acquire a migration lock for clustered environments
/// - [releaseLock] - Release the migration lock
///
/// **Important:** Lock/unlock, version queries, and migration execution
/// must all run on the **same database connection** (session). Using a
/// connection pool may cause advisory locks or session state to be lost
/// between calls. Implementors should ensure a dedicated connection is
/// used for the entire migration lifecycle.
///
/// **Example:**
/// ```dart
/// class MyDatabase with Migratable {
///   @override
///   final MigrationOptions migrationsOptions = MigrationOptions(
///     path: './migrations',
///     directoryBased: false,
///     checksums: true,
///   );
///
///   @override
///   Future<({String version, String checksum})> queryVersion() async {
///     // Query version from your database
///     return (version: '1.0.0', checksum: 'abc123...');
///   }
///
///   @override
///   Future<void> transaction(Future<void> Function(dynamic ctx) fn) async {
///     // Begin transaction, execute fn, commit or rollback
///   }
///
///   @override
///   Future<void> execute(String file, {ctx}) async {
///     // Execute migration file SQL statements
///   }
/// }
///
/// // Usage
/// final db = MyDatabase();
/// final result = await db.migrate(version: '2.0.0');
/// print(result.message); // "Migrated 5 files in 3 seconds."
/// ```
///
/// **Version Comparison:**
/// - Current version < Target version → Executes upgrade migrations
/// - Current version > Target version → Executes downgrade migrations
/// - Current version = Target version → Verifies checksums (if enabled) and skips migration
///
/// **Error Handling:**
/// - Throws [MigrationInvalidVersionError] for invalid version formats
/// - Throws [MigrationChecksumMismatchError] when checksums don't match
/// - Throws [MigrationError] when migration file execution fails
/// - Automatically rolls back transactions on failure
///
/// See also:
/// - [MigrationOptions] for configuration details
/// - [MigrationResult] for migration execution results
mixin Migratable {
  static const minVersion = '0.0.1-alpha+0';

  /// Gets the configuration options for database migrations.
  MigrationOptions get migrationOptions;

  // region Overridable methods
  /// Whether the given error is transient and the migration should be retried.
  ///
  /// Implementors should return `true` for recoverable errors such as
  /// connection failures, lock timeouts, and deadlocks.
  ///
  /// Defaults to `false` (no retry).
  bool isRetryable(Object error) => false;

  /// Queries and returns the current database version and checksum.
  ///
  /// Returns a version/checksum strings record representing the current version
  /// in semantic versioning format (e.g., "1.2.3").
  ///
  /// Returns a record of empty strings if no version has been set.
  Future<({String version, String checksum})?> queryVersion();

  /// Commits the new database migration version to the migration history table.
  ///
  /// This method persists the current migration state to the database by recording
  /// the version and checksum (if enabled) in the version tracking table. It is
  /// executed within the same transaction as the migration file statements, just
  /// before the transaction is committed.
  ///
  /// **Parameters:**
  /// - [result] - The migration result with important information about the migration, such as the the applied target version and its checksum.
  /// - [ctx] - The transaction context in which to execute the version update in the migration history table.
  ///
  /// **Implementation Notes:**
  /// Implementors should:
  /// - Insert or update the version record in the configured [MigrationOptions.versionTable]
  /// - Store the current migration version and checksum (if checksums are enabled)
  /// - Use the provided transaction context to ensure atomic execution
  ///
  /// **Throws:**
  /// May throw database-specific exceptions if the version update fails.
  ///
  /// **Example:**
  /// ```dart
  /// @override
  /// Future<void> saveVersion({dynamic ctx}) async {
  ///   await execute(
  ///     'UPDATE ${migrationOptions.versionTable} SET version = ?, checksum = ?',
  ///     ctx: ctx,
  ///   );
  /// }
  /// ```
  Future<void> saveVersion({required MigrationResult result, dynamic ctx, String? comment});

  /// Executes a command or statement within a transaction context.
  ///
  /// Implementors should execute the provided statement against the database.
  ///
  /// **Parameters:**
  /// - [sql] - The SQL command string to execute
  /// - [ctx] - Optional transaction context
  ///
  /// **Throws:**
  /// May throw database-specific exceptions on execution failure.
  Future<dynamic> execute(Object cmd, {dynamic ctx});

  // region Locking/transaction methods
  /// Acquires a migration lock to prevent concurrent migration execution
  /// in clustered environments.
  ///
  /// The lock should be held for the duration of the migration and released
  /// by [releaseLock]. If locking is not needed, simply leave the default
  /// no-op implementation.
  ///
  /// **Throws:** if the lock cannot be acquired within the configured timeout.
  Future<void> acquireLock() async {}

  /// Releases the migration lock acquired by [acquireLock].
  ///
  /// This is called in a `finally` block, so it will execute even if the
  /// migration fails.
  Future<void> releaseLock() async {}

  /// Executes a function within a database transaction context.
  ///
  /// This method wraps the provided function in a database transaction, ensuring
  /// that all operations within the function are executed atomically. If the function
  /// completes successfully, the transaction is committed. If an error occurs, the
  /// transaction is automatically rolled back.
  ///
  /// **Parameters:**
  /// - [fn] - An asynchronous function that receives a transaction context object
  ///   and performs database operations within the transaction scope.
  ///
  /// **Behavior:**
  /// - Begins a new database transaction
  /// - Executes the provided function with the transaction context
  /// - Commits the transaction if the function completes successfully
  /// - Rolls back the transaction if an exception occurs
  ///
  /// **Throws:**
  /// May throw exceptions from the provided function or underlying database
  /// transaction operations.
  /// ```
  Future<void> transaction(Future<void> Function(dynamic ctx) fn);
  // endregion
  // endregion

  // region Migration directory querying methods
  /// Returns a list of available migration versions found in the migrations directory,
  /// along with each version's checksum (if enabled). See [queryMigrationFiles] for the meaning of the parameters.
  ///
  /// Returns a list of available migration versions and their checksums (if enabled),
  /// sorted from oldest to newest, or newest to oldest if downgrading. Empty if none found.
  Future<List<({String name, String checksum})>> queryMigrationVersions(
    String targetVersions, {
    ({String version, String checksum})? current,
    MigrationDirection direction = MigrationDirection.up,
  }) async {
    final versions = (await queryMigrationFiles(targetVersions, current: current, direction: direction));

    return versions.keys.map((v) => (name: v, checksum: versions[v]!.checksum())).toList();
  }

  /// Returns the available migration files found in the migrations directory, grouped by version.
  ///
  /// - [targetVersion] - The version to migrate to. If empty, there is no target boundary.
  /// - [current] - The current database version. If not provided, it is queried using [queryVersion].
  /// - [direction]:
  ///   - [MigrationDirection.up]: `up` files with `current < version <= target`
  ///     (or every version newer than current if [targetVersion] is empty).
  ///   - [MigrationDirection.down]: `down` files with `target < version <= current`
  ///     (or every version down to the oldest if [targetVersion] is empty).
  ///   - [MigrationDirection.none] with a [targetVersion]: auto-mode; behaves as `up` if the target is newer than
  ///     current, as `down` if older, and returns an empty map if equal.
  ///   - [MigrationDirection.none] without a [targetVersion]: lists every version, with both `up` and `down`
  ///     files, without checksums, and ignoring [current].
  ///
  /// Returns a map of migration files with the version as key, empty if none found.
  /// Keys (versions) are sorted from oldest to newest, or newest to oldest for downgrades;
  /// files within a version are sorted in natural order.
  Future<Map<String, List<({String name, String checksum})>>> queryMigrationFiles(
    String targetVersion, {
    ({String version, String checksum})? current,
    MigrationDirection direction = MigrationDirection.up,
    List<String>? skipped,
  }) async {
    // Check if migrations directory exists
    final dir = Directory(migrationOptions.path);
    if (!await dir.exists()) return {};

    Version? currVer;
    Version? targVer;

    // No target with [MigrationDirection.none] lists all versions, of any direction
    final listAll = direction == MigrationDirection.none && targetVersion.isEmpty;

    if (!listAll) {
      current = current ?? await _retry(() => queryVersion());
      try {
        currVer = (current?.version ?? '').isNotEmpty ? Version.parse(current!.version) : null;
      } catch (_) {
        throw MigrationInvalidVersionError(
          message: 'Current version "${current!.version}" has not a valid version format.',
        );
      }
      if (targetVersion.isNotEmpty) {
        try {
          targVer = Version.parse(targetVersion);
        } catch (_) {
          throw MigrationInvalidVersionError(message: 'Target version "$targetVersion" has not a valid version format.');
        }
      }
    }

    // Auto-mode: identify the direction by comparing the current and target versions
    if (direction == MigrationDirection.none && targVer != null) {
      if (currVer != null && currVer == targVer) return {};
      direction = (currVer == null || currVer < targVer) ? MigrationDirection.up : MigrationDirection.down;
    }

    if (direction == MigrationDirection.down && currVer == null) return {};
    if (direction == MigrationDirection.up && targVer != null && currVer != null && targVer <= currVer) return {};
    if (direction == MigrationDirection.down && targVer != null && targVer >= currVer!) return {};

    // Whether a version lies within the requested range
    bool inRange(Version ver) {
      if (listAll) return true;
      if (direction == MigrationDirection.up) {
        return (currVer == null || ver > currVer) && (targVer == null || ver <= targVer);
      }
      return ver <= currVer! && (targVer == null || ver > targVer);
    }

    final versions = <Version, List<({String name, String checksum})>>{};

    // Iterate through all files/dirs in the migrations directory
    if (migrationOptions.directoryBased) {
      await for (final file in dir.list()) {
        // We're only looking for versioned directories; ignore files
        if (file is! Directory) continue;
        final versionStr = p.basename(file.path);

        final Version ver;
        try {
          ver = Version.parse(versionStr);
        } on FormatException {
          if (_looksLikeVersion(versionStr)) skipped?.add(versionStr);
          continue;
        }

        if (!inRange(ver)) continue;

        final files = <({String name, String checksum})>[];

        await for (final item in file.list()) {
          // We're only looking for files; ignore directories
          if (item is! File) continue;
          final name = p.basename(item.path);

          // Check file's name and extract its version info
          final match = migrationOptions.regex.firstMatch(name);
          if (match == null) continue;

          final dir = match.namedGroup('dir');
          if (!_matchesDirection(dir, direction, listAll)) continue;

          String checksum = '';
          if (migrationOptions.checksums && !listAll) {
            checksum = await _fileChecksum(item);
          }

          files.add((name: name, checksum: checksum));
        }

        // Versions without any matching file don't exist
        if (files.isEmpty) continue;

        versions[ver] = (versions[ver] ?? [])
          ..addAll(files)
          ..sort(
            direction == MigrationDirection.down
                ? (a, b) => naturalCompare(b.name, a.name)
                : (a, b) => naturalCompare(a.name, b.name),
          );
      }
    } else {
      await for (final file in dir.list()) {
        // We're only looking for files; ignore directories
        if (file is! File) continue;
        final name = p.basename(file.path);

        // Check file's name and extract its version info
        final match = migrationOptions.regex.firstMatch(name);
        if (match == null) continue;

        final versionStr = match.namedGroup('version');
        if (versionStr == null) continue;

        if (!_matchesDirection(match.namedGroup('dir'), direction, listAll)) continue;

        final Version ver;
        try {
          ver = Version.parse(versionStr);
        } on FormatException {
          skipped?.add(name);
          continue;
        }

        if (!inRange(ver)) continue;

        String checksum = '';
        if (migrationOptions.checksums && !listAll) {
          checksum = await _fileChecksum(file);
        }

        versions[ver] = (versions[ver] ?? [])
          ..add((name: name, checksum: checksum))
          ..sort((a, b) => naturalCompare(a.name, b.name));
      }
    }

    final sortFn = (direction == MigrationDirection.down) ? (a, b) => b.compareTo(a) : (a, b) => a.compareTo(b);

    // Return properly sorted map entries
    return Map.fromEntries(
      (versions.entries.toList()..sort((a, b) => sortFn(a.key, b.key))).map((e) => MapEntry(e.key.toString(), e.value)),
    );
  }
  // endregion

  // region Migration execution methods
  /// Performs database migration to the specified target version.
  ///
  /// This method handles both upgrade (migrating to a newer version) and downgrade
  /// (reverting to an older version) operations by comparing the current database
  /// version with the target version and executing the appropriate migration files.
  ///
  /// **Parameters:**
  /// - [version] - The target version to migrate to. It must be an existing version, i.e. one having
  ///   at least one migration file (`up` or `down`), otherwise [MigrationInvalidVersionError] is thrown
  ///   before anything is executed.
  /// - [latest] - If `true`, migrates to the newest existing version. [version] must then be left empty.
  /// - [current] - Optional current database version and checksum. If not provided,
  ///   will be queried using [queryVersion].
  /// - [ctx] - The database transaction context in which all migration executions will run through.
  /// - [comment] - A comment to optionally add to the migration history table.
  ///
  /// **Returns:**
  /// A record containing:
  /// - `upgrade` - Whether the the target version was newer (true) or older (false) than the current
  /// - `message` - A descriptive message about the migration result
  /// - `started` - The DateTime when the migration process started
  /// - `completed` - The DateTime when the migration process completed
  /// - `files` - The migration file names that were actually parsed and executed
  ///    (with relative path, starting from inside the migration directory)
  ///
  /// **Behavior:**
  /// - Acquires a lock before querying for the current version
  /// - Compares current version with target version to determine migration direction
  /// - Queries appropriate migration files based on version comparison
  /// - Executes migration files within a transaction context
  /// - Automatically rolls back on failure and throws [MigrationError]
  /// - Releases the lock acquired when starting the migration process
  /// - Returns early if no migration files are found
  /// - Retries command executions as dictated by the [MigrationOptions.retries] and
  ///   [MigrationOptions.retryDelay] options
  ///
  /// **Throws:**
  /// - [MigrationInvalidVersionError] if current or target version format is invalid, or the target version doesn't exist
  /// - [MigrationError] if any migration file execution fails
  ///
  /// **Example:**
  /// ```dart
  /// final result = await migrate(version: '2.0.0');
  /// print(result.message); // "Migrated 5 files in 3 seconds."
  /// ```
  Future<MigrationResult> migrate({
    String version = '',
    bool latest = false,
    ({String version, String checksum})? current,
    dynamic ctx,
    String? comment,
  }) async {
    // Fail early, before locking, if the target version doesn't exist
    final target = (await queryMigrationFiles('', direction: MigrationDirection.none)).resolveTarget(
      version,
      latest: latest,
    );

    await _retry(() => acquireLock());
    try {
      return await _migrate(version: target, current: current, ctx: ctx, comment: comment);
    } finally {
      try {
        await _retry(() => releaseLock());
      } catch (_) {}
    }
  }
  // endregion

  // region Internal methods
  Future<MigrationResult> _migrate({
    required String version,
    ({String version, String checksum})? current,
    dynamic ctx,
    String? comment,
  }) async {
    late final Version? currVer;
    late final Version targVer;

    // region Identify migration's direction and versions
    current = current ?? await _retry(() => queryVersion());
    if ((current?.version ?? '').isNotEmpty) {
      try {
        currVer = Version.parse(current!.version);
      } catch (e) {
        throw MigrationInvalidVersionError(message: 'Invalid current version ${current!.version}: $e');
      }
    } else {
      currVer = null;
    }

    try {
      targVer = Version.parse(version);
    } catch (e) {
      throw MigrationInvalidVersionError(message: 'Invalid target version "$version": $e');
    }

    final direction = MigrationDirection.fromVersions(currVer, targVer);
    // endregion

    // region Extract all files to be processed, in the correct order
    late final Map<String, List<({String name, String checksum})>> files;
    final skipped = <String>[];

    if (currVer == null || currVer < targVer) {
      // Upgrade database
      files = await queryMigrationFiles(version, current: current, direction: MigrationDirection.up, skipped: skipped);
    } else if (currVer > targVer) {
      // Downgrade database
      files = await queryMigrationFiles(
        version,
        current: current,
        direction: MigrationDirection.down,
        skipped: skipped,
      );
    } else {
      // region If checksums are enabled, validate file checksums against the database
      if (migrationOptions.checksums) {
        // Query the list of migration files that belong to the target version
        final files = await queryMigrationFiles(version, current: (version: '', checksum: ''));
        final targetFiles = files[targVer.toString()];
        if (targetFiles != null) {
          final checksum = targetFiles.checksum();
          if (current!.checksum != checksum) {
            throw MigrationChecksumMismatchError(
              message: 'Migration version checksum failed',
              calculated: checksum,
              queried: current.checksum,
            );
          }
        }
      }
      // endregion

      files = {};
    }

    final path = p.basename(Directory(migrationOptions.path).path);
    final started = DateTime.now();
    final skippedNote = skipped.isEmpty
        ? ''
        : ' Skipped ${skipped.length} item(s) with invalid semantic version: ${skipped.join(', ')}.';
    if (files.isEmpty) {
      return (
        direction: direction,
        fromVersion: currVer?.toString() ?? '',
        toVersion: targVer.toString(),
        message: 'No migration files found to process.$skippedNote',
        started: started,
        completed: DateTime.now(),
        path: path,
        files: <({String name, String checksum})>[],
        checksum: '',
      );
    }
    // endregion

    final executed = <({String name, String checksum})>[];

    // The checksum of the target version's (up) files
    var targetChecksum = '';
    if (migrationOptions.checksums) {
      final upFiles = await queryMigrationFiles(version, current: (version: '', checksum: ''));
      targetChecksum = upFiles[targVer.toString()]?.checksum() ?? '';
    }
    late final MigrationResult result;

    Future<void> run(dynamic ctx) async {
      for (final version in files.keys) {
        for (var file in files[version]!) {
          if (migrationOptions.directoryBased) file = (name: '$version/${file.name}', checksum: file.checksum);
          try {
            await _processFile(file.name, ctx: ctx);
            executed.add(file);
          } catch (e) {
            throw MigrationError(message: e.toString(), failedFile: file.name);
          }
        }
      }

      final completed = DateTime.now();
      result = (
        direction: MigrationDirection.fromVersions(currVer, targVer),
        fromVersion: currVer?.toString() ?? '',
        toVersion: targVer.toString(),
        started: started,
        completed: completed,
        message:
            'Migrated from ${currVer ?? ''} ➡ $targVer in ${completed.difference(started).inSeconds} seconds.$skippedNote',
        path: path,
        files: executed,
        checksum: targetChecksum,
      );

      // Save the new version to the migration history table
      await saveVersion(result: result, ctx: ctx, comment: comment);
    }

    // Use the caller's context when provided, otherwise open a new transaction
    if (ctx != null) {
      await run(ctx);
    } else {
      await transaction(run);
    }

    return result;
  }

  /// Whether a file's `dir` group (`up`/`down`) is wanted for the given [direction].
  /// With [listAll] any valid direction matches.
  static bool _matchesDirection(String? dir, MigrationDirection direction, bool listAll) {
    if (dir == null) return false;
    final code = MigrationDirection.fromCode(dir);
    if (listAll) return code != MigrationDirection.none;
    return code == direction;
  }

  static bool _looksLikeVersion(String s) => RegExp(r'^v?\d').hasMatch(s);

  /// SHA-256 of the file's content, ignoring BOM and line-ending differences.
  Future<String> _fileChecksum(File f) async {
    var text = utf8.decode(await f.readAsBytes(), allowMalformed: true).replaceAll('\r\n', '\n');
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return sha256.convert(utf8.encode(text)).toString();
  }

  /// Processes (executes all statements in) a migration file within the context
  /// of a database transaction.
  ///
  /// **Parameters:**
  /// - [file] - The path or name of the migration file to execute
  /// - [ctx] - Optional transaction context
  ///
  /// **Throws:**
  /// May throw exceptions if the migration file cannot be executed or contains
  /// failing SQL statements.
  Future<void> _processFile(String file, {dynamic ctx}) async {
    final path = '${migrationOptions.path}/$file';
    final content = await File(path).readAsString(encoding: migrationOptions.encoding);
    if (content.trim().isEmpty) return;

    await _retry(() async => await execute(content, ctx: ctx));
  }

  /// Executes an async operation with retry logic for transient failures.
  ///
  /// Retries the operation up to [MigrationOptions.retries] times with a
  /// [MigrationOptions.retryDelay] delay between attempts when [isRetryable]
  /// returns true for the caught error.
  Future<T> _retry<T>(Future<T> Function() fn) async {
    for (var attempt = 1; attempt <= migrationOptions.retries; attempt++) {
      try {
        return await fn();
      } catch (e) {
        if (!isRetryable(e) || attempt == migrationOptions.retries) {
          rethrow;
        }
        await Future.delayed(migrationOptions.retryDelay);
      }
    }

    // for type safety
    throw StateError('Unreachable');
  }

  // endregion
}

/// Configuration options for database migrations.
///
/// This class defines how migrations are structured, located, and executed.
/// It supports two organizational modes:
/// - **File-based**: Migration files are named with semantic versions
///   (e.g., `1.0.0.sql`, `1.2.0-alpha_added_users_table.sql`)
/// - **Directory-based**: Migrations are organized in version-named directories
///   (e.g., `migrations/1.0.0/init.sql`, `migrations/1.2.0/core_schema.sql`, `migrations/1.2.0/crm_tables.sql`)
///
/// **Note**: For file-based versioning, the default regex pattern expects files to:
/// - start with the version number
/// - end with the `.sql` file extension
/// - if there is additional text in the file name, the version part has to be
///   separated by underscode (`_`) (e.g. `1.0.0_any_additional_text.sql` or `1.0.0-alpha_any_additional_text.sql`).
///
/// **Example:**
/// ```dart
/// // File-based migrations
/// final options = MigrationOptions(
///   path: './migrations',
///   directoryBased: false,
///   versionTable: '_version',
/// );
///
/// // Directory-based migrations
/// final options = MigrationOptions(
///   path: './migrations',
///   directoryBased: true,
///   checksums: true,
/// );
/// ```
class MigrationOptions {
  MigrationOptions({
    required this.path,
    this.filesPattern,
    this.directoryBased = false,
    this.schema = '',
    this.versionTable = '_version',
    this.retries = 3,
    this.retryDelay = const Duration(seconds: 5),
    this.timeout = const Duration(seconds: 15),
    this.checksums = true,
    this.encoding = utf8,
    String? lockKey,
  }) : lockKey = lockKey ?? 'migration:${schema.isNotEmpty ? '$schema.$versionTable' : versionTable}',
       assert(retries >= 1, 'retries must be at least 1'),
       assert(
         filesPattern == null || directoryBased || RegExp(r'\(\?<version>').hasMatch(filesPattern.pattern),
         'filesPattern, when in file-based versioning mode, must contain a <version> variable in the regex pattern',
       ),
       assert(
         filesPattern == null || RegExp(r'\(\?<dir>').hasMatch(filesPattern.pattern),
         'filesPattern must contain a <dir> variable in the regex pattern matching either "up" or "down"',
       );

  // region Properties
  /// The full path to the directory containing migration files or versioned subdirectories.
  final String path;

  /// Optional custom regex pattern for matching migration file names.
  final RegExp? filesPattern;

  /// Whether migrations are organized in version-named subdirectories (true) or as versioned files (false).
  final bool directoryBased;

  /// Number of retry attempts for failed statement executions or migration operations,
  /// due to connection or lock acquisition reasons.
  final int retries;

  /// Duration to delay before retrying to execute a statement or migration operation,
  /// due to failure for connection or lock acquisition reasons.
  final Duration retryDelay;

  /// Duration to timeout the execution of single statements,
  /// such as querying/saving versions in history and lock/unlocking.
  ///
  /// **Note:** The actual timeout logic must be implemented by the class
  /// that extends the [Migratable] mixin.
  final Duration timeout;

  /// The database schema name where migrations should be applied.
  final String schema;

  /// The name of the table used to store version information.
  final String versionTable;

  /// Whether to calculate and verify checksums for migration files.
  final bool checksums;

  /// The encoding used to read migration files.
  ///
  /// Defaults to [utf8], which covers the vast majority of use cases.
  final Encoding encoding;

  /// The key used by [acquireLock] / [releaseLock] to prevent concurrent migration execution in clustered environments.
  ///
  /// Defaults to `'migration_<schema>.<versionTable>'`.
  final String lockKey;
  // endregion

  /// Pattern to match migration file names based on semantic versioning.
  /// For directory-based migrations, the pattern matches the containing file names.
  ///
  /// If [filesPattern] is provided, it will be returned as the regex, otherwise the default pattern will be used.
  ///
  /// Default pattern:
  /// For file-based migrations, the pattern expects versioned `.sql` files with optional suffixes
  /// (e.g., "1.0.0.up.sql", "1.2.0_test.up.sql", "0.1.0-pre_test.up.sql", "0.1.0-pre-test.up.sql").
  ///
  /// For directory-based migrations, the pattern expects any `.sql` files.
  RegExp get regex =>
      filesPattern ??
      RegExp(
        directoryBased
            ? r'^([^.]+\.)?(?<dir>up|down)\.sql$'
            : r'^(?<version>[^_]+)([_\-][^.]+)?\.(?<dir>up|down)\.sql$',
        caseSensitive: false,
      );

  /// Creates a copy of this MigrationOptions instance with specified properties replaced.
  ///
  /// Returns a new [MigrationOptions] instance with the same values as this instance,
  /// except for any properties explicitly provided as parameters.
  ///
  /// **Example:**
  /// ```dart
  /// final options = MigrationOptions(path: './migrations');
  /// final newOptions = options.copyWith(checksums: false, retries: 5);
  /// ```
  MigrationOptions copyWith({
    String? path,
    RegExp? filesPattern,
    bool? directoryBased,
    String? schema,
    String? versionTable,
    int? retries,
    Duration? retryDelay,
    Duration? timeout,
    bool? checksums,
    Encoding? encoding,
    String? lockKey,
  }) {
    return MigrationOptions(
      path: path ?? this.path,
      filesPattern: filesPattern ?? this.filesPattern,
      directoryBased: directoryBased ?? this.directoryBased,
      schema: schema ?? this.schema,
      versionTable: versionTable ?? this.versionTable,
      retries: retries ?? this.retries,
      retryDelay: retryDelay ?? this.retryDelay,
      timeout: timeout ?? this.timeout,
      checksums: checksums ?? this.checksums,
      encoding: encoding ?? this.encoding,
      lockKey: lockKey ?? this.lockKey,
    );
  }
}

extension MigrationFilesMapExtensions on Map<String, List<({String name, String checksum})>> {
  /// Resolves the migration target against the existing versions (the map keys).
  ///
  /// Returns [version] if it exists, or the newest existing version if [latest] is `true`.
  ///
  /// Throws [MigrationInvalidVersionError] if both or neither of [version] and [latest] are given,
  /// if [version] is not a valid semantic version, or if the target doesn't exist.
  String resolveTarget(String version, {bool latest = false}) {
    if (latest && version.isNotEmpty) {
      throw MigrationInvalidVersionError(message: 'Provide either a target version or latest: true, not both.');
    }
    if (!latest && version.isEmpty) {
      throw MigrationInvalidVersionError(message: 'Target version "$version" has not a valid version format.');
    }

    final existing = keys.map(Version.parse).toList()..sort();
    if (latest) {
      if (existing.isEmpty) throw MigrationInvalidVersionError(message: 'No migration versions found.');
      return existing.last.toString();
    }

    final Version parsed;
    try {
      parsed = Version.parse(version);
    } catch (e) {
      throw MigrationInvalidVersionError(message: 'Invalid target version "$version": $e');
    }
    if (!existing.contains(parsed)) {
      throw MigrationInvalidVersionError(
        message:
            'Target version "$version" not found. Available versions: ${existing.isEmpty ? 'none' : existing.join(', ')}.',
      );
    }
    return version;
  }
}

extension NameChecksumListExtensions on List<({String name, String checksum})> {
  /// Calculates and returns a combined SHA-256 checksum of all version checksums in the list.
  String checksum() {
    // If the list contains only one file, return the file's checksum
    if (length == 1) return first.checksum;

    // Combine both the names and the content checksums of all files
    final bytes = utf8.encode(map((e) => '${e.name}:${e.checksum}').join('\n'));
    return sha256.convert(bytes).toString();
  }

  /// Returns a list with all the names found in the list of name/checksum records.
  List<String> names() => map((v) => v.name).toList();
}

/// Compares two strings in natural order: digit runs are compared numerically
/// (`2_x` < `10_x`) and everything else case-insensitively (`a_` < `b_`).
int naturalCompare(String a, String b) {
  // Splits a string into tokens: either a whole run of digits, or a single non-digit character
  final re = RegExp(r'\d+|\D');

  // Tokens of the first string (lower-cased, so letters compare case-insensitively)
  final x = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();

  // Tokens of the second string (lower-cased)
  final y = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();

  // Whether a token is a digit run (its first character is a digit '0'-'9')
  bool isNum(String s) => s.codeUnitAt(0) >= 48 && s.codeUnitAt(0) <= 57;

  // Compare token by token, up to the length of the shorter token list
  for (var i = 0; i < x.length && i < y.length; i++) {
    // Comparison result of the current token pair: numeric if both are digit runs
    // (BigInt avoids overflow on long runs), otherwise plain string comparison
    final c = (isNum(x[i]) && isNum(y[i])) ? BigInt.parse(x[i]).compareTo(BigInt.parse(y[i])) : x[i].compareTo(y[i]);
    // The first differing token decides the order
    if (c != 0) return c;
  }

  // All shared tokens are equal: the string with fewer tokens sorts first
  final c = x.length.compareTo(y.length);

  // If still equal, fall back to the original strings to keep the order deterministic (e.g. case differences)
  return c != 0 ? c : a.compareTo(b);
}

class MigrationError extends Error {
  final String message;
  final String? failedFile;
  MigrationError({this.message = '', this.failedFile});

  @override
  String toString() {
    var message = this.message;
    return '$runtimeType${message.isNotEmpty ? ': $message' : ''}${(failedFile ?? '').isNotEmpty ? '. Failed file: $failedFile' : ''}';
  }
}

class MigrationInvalidVersionError extends MigrationError {
  MigrationInvalidVersionError({super.message = ''});
}

class MigrationChecksumMismatchError extends MigrationError {
  final String queried;
  final String calculated;

  MigrationChecksumMismatchError({super.message = '', this.queried = '', this.calculated = ''});

  @override
  String toString() => '$message. Queried checksum: [$queried]. Calculated checksum: [$calculated]';
}

/// Represents the direction of a database migration operation.
///
/// Migration direction indicates whether the database schema is moving forward
/// to a newer version ([up], upgrade) or backward to an older version ([down], downgrade).
///
/// **Example:**
/// ```dart
/// final direction = MigrationDirection.fromVersions(
///   Version.parse('1.0.0'),
///   Version.parse('2.0.0'),
/// );
/// print(direction); // MigrationDirection.up
/// ```
enum MigrationDirection {
  /// Indicates an upgrade migration to a newer version.
  up,

  /// Indicates a downgrade migration to an older version.
  down,

  /// Indicates no migration due to source/target version match.
  none;

  /// Creates a [MigrationDirection] by comparing two versions.
  ///
  /// Returns [down] if [from] is greater than [to] (downgrade),
  /// otherwise returns [up] (upgrade).
  ///
  /// **Parameters:**
  /// - [from] - The current/starting version
  /// - [to] - The target/destination version
  factory MigrationDirection.fromVersions(Version? from, Version to) {
    final fromVersion = from ?? Version.parse(Migratable.minVersion);
    if (fromVersion == to) return none;

    return fromVersion < to ? up : down;
  }

  /// Creates a [MigrationDirection] from a string code ('up', 'down', or 'none').
  ///
  /// Returns [none] if the provided code doesn't match any valid direction.
  ///
  /// **Parameters:**
  /// - [code] - The string representation of the migration direction
  factory MigrationDirection.fromCode(String code) {
    return MigrationDirection.values.firstWhere((e) => e.name == code, orElse: () => MigrationDirection.none);
  }
}
