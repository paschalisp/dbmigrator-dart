A database-agnostic database migration framework for building file-based migration tools and solutions in Dart.

[![pub package](https://img.shields.io/pub/v/dbmigrator.svg)](https://pub.dev/packages/dbmigrator)
[![package publisher](https://img.shields.io/pub/publisher/dbmigrator.svg)](https://pub.dev/packages/dbmigrator/publisher)

This package provides the **core database migration orchestration logic** — current/target version resolution,
migration files, ordering, validating file checksums, upgrade/downgrade detection, and retry logic — leaving only
the database-specific command execution to derived packages or implementations.

> **This package is not intended to be used directly unless the migration logic requires high-level of customization.**
> 
> For database-specific migration tools in Dart, visit derived packages such as:
> - [dbmigrator_psql](https://pub.dev/packages/dbmigrator_psql) - Migrations for PostgreSQL databases.
> - [dbmigrator_mysql](https://pub.dev/packages/dbmigrator_mysql) - Migrations for MySQL databases.
> - [dbmigrator_mssql](https://pub.dev/packages/dbmigrator_mssql) - Migrations for Microsoft SQL Server databases.

## Out-of-the-box features

The `Migratable` mixin and `MigrationOptions` class orchestrate all database-independent migration logic:

- **Semantic version resolution** — migration versions are parsed, compared, and ordered using [pub_semver](https://pub.dev/packages/pub_semver),
  including full support for pre-release tags (e.g., `2.0.0-rc1`).
- **Automatic direction detection** — determines whether to upgrade or downgrade based on the current vs. target version.
- **Migration file discovery** — scans a migrations directory and resolves which files need to run, in the correct order.
- **Two migration file structure modes:**
  - **File-based** — `.[up|down].sql` files named with their version (e.g., `1.0.0.up.sql`, `1.2.0_add_users.up.sql`).
  - **Directory-based** — version-named subdirectories containing any number of `.[up|down].sql` files.
- Multiple files with the same version prefix are supported and executed in alphabetical order (e.g., `1.2.0_a_core_tables.up.sql`,
  `1.2.0_b_crm_tables.up.sql`), in both file-based and directory-based structures
  (however, single migration files are the recommended).
- **SHA-256 checksum verification** — optional integrity checks to detect migration files modified after applying the migration.
- **Custom file patterns** — configurable regex for non-standard file naming conventions.
- **Migration locks** — acquire and release migration locks to ensure no other migration can be performed at the same time
  (essential in clustered environments).
- **Transaction-safe execution** — provides the foundation to execute all migration files under a single transaction context.
- **Retry logic** — configurable retry attempts and timeouts for failed migration operations.
- **Custom file patterns** — allows custom regex patterns to match migration file names.
- **Structured result reporting** — every `migrate()` call returns a detailed `MigrationResult` record.
- **Standardized error types** — `MigrationError`, `MigrationInvalidVersionError`, and `MigrationChecksumMismatchError`.

## Migration directory organization 

### File-based (default)

Place all `.sql` files in a single directory. By default, when not a custom `Regex` is provided, each file name
**must start** with a valid semver version. An optional suffix separated by `_` is allowed.
Multiple files can share the same version prefix and will be executed in alphabetical order.

```
migrations/ (or a custom directory name)
    ├── 0.0.1.down.sql
    ├── 0.0.1.up.sql
    ├── 0.1.0_create_users.down.sql
    ├── 0.1.0_create_users.up.sql
    ├── 1.0.0.down.sql
    ├── 1.0.0.up.sql
    ├── 1.0.0-pre_experimental.down.sql
    ├── 1.0.0-pre_experimental.up.sql
    ├── 1.1.0_add_index.down.sql
    ├── 1.1.0_add_index.up.sql
    ├── 1.2.0_change.down.sql
    ├── 1.2.0_change.up.sql
    ├── 1.2.0_crm_tables.down.sql
    ├── 1.2.0_crm_tables.up.sql
    └── 2.0.0.down.sql
    └── 2.0.0.up.sql
```

### Directory-based

Each version gets its own subdirectory, and all `.[up|down].sql` files within it are executed in alphabetical order.

```
migrations/ (or a custom directory name)
    ├── 0.0.1/
    │   └── down.sql
    │   └── up.sql
    ├── 1.0.0/
    │   └── schema_changes.down.sql
    │   └── schema_changes.up.sql
    ├── 1.1.1/
    │   ├── a_create_tables.down.sql
    │   ├── a_create_tables.up.sql
    │   ├── b_add_indexes.down.sql
    │   ├── b_add_indexes.up.sql
    │   └── c_seed_data.down.sql
    │   └── c_seed_data.up.sql
    └── 2.0.0/
        └── upgrade.down.sql
        └── upgrade.up.sql
```


## Migration behavior

### Direction detection

| Condition                        | Action                                                                          |
|----------------------------------|---------------------------------------------------------------------------------|
| Current version < target version | **Upgrade** — executes migration files from current → target.                   |
| Current version > target version | **Downgrade** — executes migration files from current → target (reverse order). |
| Current version = target version | **No-op** — verifies checksums (if enabled) and returns.                        |

### Checksum verification

When `checksums: true`, the migrator computes an SHA-256 hash of each migration file's contents.
If the current and target versions are the same, the stored checksum is compared against the calculated one.
A mismatch raises `MigrationChecksumMismatchError`.


## Migration Options

The `MigrationOptions` class accepts the following parameters:

| Parameter        | Type       | Default        | Description                                                                                                                             |
|------------------|------------|----------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| `path`           | `String`   | **(required)** | Path to the migrations directory.                                                                                                       |
| `directoryBased` | `bool`     | `false`        | Use version-named directories instead of version-prefixed files.                                                                        |
| `checksums`      | `bool`     | `true`         | Enable SHA-256 checksum calculation and verification.                                                                                   |
| `filesPattern`   | `RegExp?`  | `null`         | Custom regex for matching migration files. Must contain a `(?<version>[^_]+)` named group in file-based mode.                           |
| `encoding`       | `Encoding` | `utf8`         | The encoding used to read migration files.                                                                                              |
| `schema`         | `String`   | `''`           | Database schema name, for use by concrete implementations.                                                                              |
| `versionTable`   | `String`   | `'_version'`   | Name of the version-tracking table, for use by concrete implementations.                                                                |
| `retries`        | `int`      | `3`            | Number of retry attempts, for use by concrete implementations.                                                                          |
| `retryDelay`     | `Duration` | `5 seconds`    | Duration to delay before retrying to execute a statement or migration operation.                                                        |
| `timeout`        | `Duration` | `15 seconds`   | Maximum duration for executing single statements, such as such as querying/saving versions and lock/unlocking.                          |
| `lockKey`        | `String?`  | `null`         | The key used by the `acquireLock()` and `releaseLock()`. Will be auto-generated to `migration:<schema>.<versionTable>` if not provided. |


## Usage (for implementation packages)

### 1. Implement the `Migratable` mixin

Apply the `Migratable` mixin to your database class and implement the required members:
- [migrationOptions] – Configuration for migration behavior
- [queryVersion] – Retrieve the current database version and checksum
- [saveVersion] – Store the new version status to the database's history table
- [transaction] – Execute operations within a database transaction
- [execute] – Execute a command or statement against the database

Optionally, and highly recommended for databases supporting transactions, also override:
- [isRetryable] – Determine if an error should trigger a retry
- [acquireLock] – Acquire a migration lock for clustered environments
- [releaseLock] – Release the migration lock

Example:

```dart
import 'dart:io';

import 'package:dbmigrator/dbmigrator.dart';

class MyDatabase with Migratable {
  MyDatabase({required this.migrationOptions});

  // Some database connection your app or package uses
  // Needs to be instantiated somewhere beforehand
  final Connection? _conn = null;

  @override
  final MigrationOptions migrationOptions;

  @override
  Future<void> acquireLock() async {
    // Acquire a migration lock
  }

  @override
  Future<void> releaseLock() async {
    // Release the lock acquired earlier
  }

  @override
  Future<void> transaction(Future<void> Function(dynamic ctx) fn) async {
    // Create transaction context, then execute the fn inside it and wait for completion
    await _conn.runTx(fn);
  }

  @override
  Future<dynamic> execute(Object stmt, {dynamic ctx}) async {
    // Execute the statement or query against the database
    return await ctx.execute(stmt);
  }

  @override
  Future<({String version, String checksum})?> queryVersion() async {
    // Query version (plus checksum, if enabled) from the database
    final sql = 'SELECT version, checksum FROM _version ORDER BY id DESC LIMIT 1';
    final result = await _conn.execute(sql);
    if (result.isEmpty) return null;

    final row = result.first.toColumnMap();

    return (version: row['version'] as String? ?? '', checksum: row['checksum'] as String? ?? '');
  }

  @override
  Future<void> saveVersion({required MigrationResult result, ctx, String? comment}) async {
    // Store the new version to the migrations history
    final sql = 'INSERT INTO _version (version, checksum, comment) VALUES (?, ?, ?)';
    await _conn.execute(sql);
  }
}
```

### 2. Running migrations
```dart
void main() async {
  final db = MyDatabase();

  // Migrate to a target version
  // - current version is queried automatically (if not explicitly provided)
  // - direction is detected automatically
  final result = await db.migrate(version: '2.0.0');
  print(result.message); // "Migrated from 1.0.0 ➡ 2.0.0 in 3 seconds."
}
```

## Additional information

### Contributing

Please file feature requests and bugs at the [issue tracker][tracker].

### License

Licensed under the BSD-3-Clause License.

[tracker]: https://github.com/paschalisp/dbmigrator-dart/issues/new