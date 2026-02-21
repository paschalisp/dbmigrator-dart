import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
/// - [files] - A list of migration files that were successfully executed, each containing:
///   - `name` - The file name (with relative path from the migrations directory)
///   - `checksum` - The SHA-256 checksum of the file contents (if checksums are enabled)
///
/// **Example:**
/// ```dart
/// final result = await db.migrate(version: '2.0.0');
/// print('Migration ${result.upgrade ? "upgraded" : "downgraded"} from ${result.fromVersion} to ${result.toVersion}');
/// print('Executed files: ${result.files.map((f) => f.name).join(", ")}');
/// print('Duration: ${result.completed.difference(result.started).inSeconds} seconds');
/// ```
typedef MigrationResult = ({
  DateTime started,
  DateTime completed,
  String message,
  bool upgrade,
  String path,
  String fromVersion,
  String toVersion,
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
/// - [migrationsOptions] - Configuration for migration behavior
/// - [queryVersion] - Retrieve current database version and checksum
/// - [transaction] - Execute operations within a database transaction
/// - [execute] - Execute a single migration file
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
  MigrationOptions get migrationsOptions;

  // region Querying methods
  /// Queries and returns the current database version and checksum.
  ///
  /// Returns a version/checksum strings record representing the current version
  /// in semantic versioning format (e.g., "1.2.3").
  ///
  /// Returns a record of empty strings if no version has been set.
  Future<({String version, String checksum})?> queryVersion();

  /// Returns a list of available migration versions found in the migrations directory
  /// that are older or newer than the provided [targetVersions], along with each version's checksum (if enabled).
  ///
  /// [targetVersions] - The target version to check migrations from
  /// [upgradable] - If true, will return versions that are older than the target version (upgradable);
  ///   otherwise will return versions that are newer (downgradable) than the target version.
  ///
  /// Returns a list of available migration versions and their checksums (if enabled),
  /// sorted either from oldest to newest (upgradable) or newest to oldest (downgradable), empty if none found.
  Future<List<({String name, String checksum})>> queryMigrationVersions(
    String targetVersions, {
    ({String version, String checksum})? current,
    bool upgradable = true,
  }) async {
    final versions = (await queryMigrationFiles(targetVersions, current: current, upgradable: upgradable));

    return versions.keys.map((v) => (name: v, checksum: versions[v]!.checksum())).toList();
  }

  /// Returns a list of available migrations found in the migrations directory
  /// that are newer or older than the provided [targetVersion].
  ///
  /// - [targetVersion] - The target version to check upgrades from
  /// - [upgradable] - If true, will return migration files that are older than the target version (upgradable);
  ///   otherwise will return migration versions that are newer (downgradable) than the target version.
  ///
  /// Returns a map of available migration files with the key containing their version, empty if none found.
  /// Keys (versions) are sorted either from oldest to newest (upgradable) or newest to oldest (downgradable).
  Future<Map<String, List<({String name, String checksum})>>> queryMigrationFiles(
    String targetVersion, {
    ({String version, String checksum})? current,
    bool upgradable = true,
  }) async {
    // Check if migrations directory exists
    final dir = Directory(migrationsOptions.path);
    if (!await dir.exists()) return {};

    // Check if target version is valid
    late final Version? currVer;
    late final Version targVer;

    current = current ?? await queryVersion();
    try {
      currVer = (current?.version ?? '').isNotEmpty ? Version.parse(current!.version) : null;
    } catch (_) {
      throw MigrationInvalidVersionError(
        message: 'Current version "${current!.version}" has not a valid version format.',
      );
    }
    try {
      targVer = targetVersion.isNotEmpty ? Version.parse(targetVersion) : Version.parse('-1');
    } catch (_) {
      throw MigrationInvalidVersionError(message: 'Target version "$targetVersion" has not a valid version format.');
    }

    if (upgradable) {
      // Return empty if current already newer than target
      if (currVer != null && targVer <= currVer) return {};
    } else {
      // Return empty if current already older than target
      if (currVer == null || targVer >= currVer) return {};
    }

    final versions = <Version, List<({String name, String checksum})>>{};

    // Iterate through all files/dirs in the migrations directory
    if (migrationsOptions.directoryBased) {
      await for (final file in dir.list()) {
        // We're only looking for versioned directories; ignore files
        if (file is! Directory) continue;
        final versionStr = file.path.split('/').last;

        try {
          final ver = Version.parse(versionStr);
          if (upgradable) {
            // Not interested in versions older than the current, neither newer than the target
            if ((currVer != null && ver <= currVer) || ver > targVer) continue;
          } else {
            // Not interested in versions newer than the current, neither older than the target
            if (currVer == null || ver >= currVer || ver < targVer) continue;
          }

          final files = <({String name, String checksum})>[];

          await for (final item in file.list()) {
            // We're only looking for files; ignore directories
            if (item is! File) continue;
            final name = item.path.split('/').last;

            // Check file's name and extract its version info
            final match = migrationsOptions.regex.firstMatch(name);
            if (match == null) continue;

            String checksum = '';
            if (migrationsOptions.checksums) {
              checksum = sha256.convert(await item.readAsBytes()).toString();
            }

            files.add((name: name, checksum: checksum));
          }

          versions[ver] = (versions[ver] ?? [])
            ..addAll(files)
            ..sort((a, b) => a.name.compareTo(b.name));
        } catch (_) {}
      }
    } else {
      await for (final file in dir.list()) {
        // We're only looking for files; ignore directories
        if (file is! File) continue;
        final name = file.path.split('/').last;

        // Check file's name and extract its version info
        final match = migrationsOptions.regex.firstMatch(name);
        if (match == null) continue;

        final versionStr = match.namedGroup('version');
        if (versionStr == null) continue;

        try {
          final ver = Version.parse(versionStr);
          if (upgradable) {
            // Not interested in versions older than the current, neither newer than the target
            if ((currVer != null && ver <= currVer) || ver > targVer) continue;
          } else {
            // Not interested in versions newer than the current, neither older than the target
            if (currVer == null || ver >= currVer || ver < targVer) continue;
          }

          String checksum = '';
          if (migrationsOptions.checksums) {
            checksum = sha256.convert(await file.readAsBytes()).toString();
          }

          versions[ver] = (versions[ver] ?? [])
            ..add((name: name, checksum: checksum))
            ..sort((a, b) => a.name.compareTo(b.name));
        } catch (_) {}
      }
    }

    final sortFn = (upgradable) ? (a, b) => a.compareTo(b) : (a, b) => b.compareTo(a);

    // Return properly sorted map entries
    return Map.fromEntries(
      (versions.entries.toList()..sort((a, b) => sortFn(a.key, b.key))).map((e) => MapEntry(e.key.toString(), e.value)),
    );
  }
  // endregion

  // region Migration execution methods
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

  /// Executes a migration file within the context of a database transaction.
  ///
  /// **Parameters:**
  /// - [file] - The path or name of the migration file to execute
  /// - [ctx] - Optional transaction context
  ///
  /// **Throws:**
  /// May throw exceptions if the migration file cannot be executed or contains
  /// invalid SQL statements.
  Future<void> execute(String file, {dynamic ctx});

  /// Performs database migration to the specified target version.
  ///
  /// This method handles both upgrade (migrating to a newer version) and downgrade
  /// (reverting to an older version) operations by comparing the current database
  /// version with the target version and executing the appropriate migration files.
  ///
  /// **Parameters:**
  /// - [version] - The target version to migrate to. Defaults to an empty string.
  /// - [current] - Optional current database version and checksum. If not provided,
  ///   will be queried using [queryVersion].
  /// - [ctx] - The database transaction context in which all migration executions will run through.
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
  ///
  /// **Throws:**
  /// - [MigrationInvalidVersionError] if current or target version format is invalid
  /// - [MigrationError] if any migration file execution fails
  ///
  /// **Example:**
  /// ```dart
  /// final result = await migrate(version: '2.0.0');
  /// print(result.message); // "Migrated 5 files in 3 seconds."
  /// ```
  Future<MigrationResult> migrate({
    required String version,
    ({String version, String checksum})? current,
    dynamic ctx,
  }) async {
    await acquireLock();
    try {
      return await _migrate(version: version, current: current, ctx: ctx);
    } finally {
      try {
        await releaseLock();
      } catch (_) {}
    }
  }

  Future<MigrationResult> _migrate({
    required String version,
    ({String version, String checksum})? current,
    dynamic ctx,
  }) async {
    late final Version? currVer;
    late final Version targVer;

    // region Identify migration's direction and versions
    current = current ?? await queryVersion();
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
      throw MigrationInvalidVersionError(message: 'Invalid target version "$targVer": $e');
    }
    // endregion

    // region Extract all files to be processed, in the correct order
    late final Map<String, List<({String name, String checksum})>> files;

    if (currVer == null || currVer < targVer) {
      files = await queryMigrationFiles(version, current: current, upgradable: true);
    } else if (currVer > targVer) {
      files = await queryMigrationFiles(version, current: current, upgradable: false);
    } else {
      if (migrationsOptions.checksums) {
        // Query the list of migration versions from start till the target version
        final files = await queryMigrationFiles(
          version,
          current: (version: '0.0.1-pre+9999', checksum: ''),
          upgradable: true,
        );
        if (files.isNotEmpty) {
          final checksum = files[files.keys.last]!.checksum();
          if (current!.checksum != checksum) {
            throw MigrationChecksumMismatchError(
              message: 'Migration version checksum failed',
              calculated: checksum,
              queried: current.checksum,
            );
          }
        }
      }

      files = {};
    }

    final path = Directory(migrationsOptions.path).path.split('/').last;
    final started = DateTime.now();
    if (files.isEmpty) {
      return (
        upgrade: true,
        fromVersion: currVer?.toString() ?? '',
        toVersion: targVer.toString(),
        message: 'No migration files found to process',
        started: started,
        completed: DateTime.now(),
        path: path,
        files: <({String name, String checksum})>[],
      );
    }
    // endregion

    final executed = <({String name, String checksum})>[];

    String lastVersion = '';
    await transaction((ctx) async {
      for (final version in files.keys) {
        for (var file in files[version]!) {
          if (migrationsOptions.directoryBased) file = (name: '$version/${file.name}', checksum: file.checksum);
          try {
            await execute(file.name, ctx: ctx);
            executed.add(file);
            lastVersion = version;
          } catch (e) {
            throw MigrationError(message: e.toString(), failedFile: file.name);
          }
        }
      }
    });

    final completed = DateTime.now();

    return (
      upgrade: currVer == null || targVer > currVer,
      fromVersion: currVer?.toString() ?? '',
      toVersion: lastVersion,
      started: started,
      completed: completed,
      message: 'Migrated from $currVer ➡ $targVer in ${completed.difference(started).inSeconds} seconds.',
      path: path,
      files: executed,
    );
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
    this.timeout = const Duration(seconds: 15),
    this.checksums = true,
  }) : assert(
         filesPattern == null || directoryBased || filesPattern.pattern.contains('(?<version>[^_]+)'),
         'filesPattern, when in file-based versioning mode, must contain a <version> variable in the regex pattern',
       );

  // region Properties
  /// The full path to the directory containing migration files or versioned subdirectories.
  final String path;

  /// Optional custom regex pattern for matching migration file names.
  final RegExp? filesPattern;

  /// Whether migrations are organized in version-named subdirectories (true) or as versioned files (false).
  final bool directoryBased;

  /// Number of retry attempts for failed migration operations.
  final int retries;

  /// Maximum duration allowed for migration operations before timing out.
  final Duration timeout;

  /// The database schema name where migrations should be applied.
  final String schema;

  /// The name of the table used to store version information.
  final String versionTable;

  /// Whether to calculate and verify checksums for migration files.
  final bool checksums;
  // endregion

  /// Pattern to match migration file names based on semantic versioning.
  /// For directory-based migrations, the pattern matches the containing file names.
  ///
  /// If [filesPattern] is provided, it will be returned as the regex, otherwise the default pattern will be used.
  ///
  /// Default pattern:
  /// For file-based migrations, the pattern expects versioned `.sql` files with optional suffixes
  /// (e.g., "1.0.0.sql", "1.2.0_test.sql", "0.1.0-pre_test.sql", "0.1.0-pre-test.sql").
  ///
  /// For directory-based migrations, the pattern expects any `.sql` files.
  RegExp get regex =>
      filesPattern ??
      RegExp(directoryBased ? r'[^.]+\.sql' : r'(?<version>[^_]+)([_\-][^.]+)?\.sql', caseSensitive: false);

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
    Duration? timeout,
    bool? checksums,
  }) {
    return MigrationOptions(
      path: path ?? this.path,
      filesPattern: filesPattern ?? this.filesPattern,
      directoryBased: directoryBased ?? this.directoryBased,
      schema: schema ?? this.schema,
      versionTable: versionTable ?? this.versionTable,
      retries: retries ?? this.retries,
      timeout: timeout ?? this.timeout,
      checksums: checksums ?? this.checksums,
    );
  }
}

extension NameChecksumListExtensions on List<({String name, String checksum})> {
  /// Calculates and returns a combined SHA-256 checksum of all version checksums in the list.
  String checksum() {
    final bytes = utf8.encode(map((e) => e.name).join('\n'));
    return sha256.convert(bytes).toString();
  }

  /// Returns a list with all the names found in the list of name/checksum records.
  List<String> names() => map((v) => v.name).toList();
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
