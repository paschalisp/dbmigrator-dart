A database-agnostic foundation for building structured, version-controlled database migration tools in Dart.

[![pub package](https://img.shields.io/pub/v/dbmigrator_base.svg)](https://pub.dev/packages/dbmigrator_base)
[![package publisher](https://img.shields.io/pub/publisher/dbmigrator_base.svg)](https://pub.dev/packages/dbmigrator_base/publisher)

This package provides the **core migration orchestration logic** — version resolution, file discovery, ordering, checksum validation,
direction detection, and retry logic — leaving only the database-specific command execution to derived packages.

> **This package is not intended to be used directly by end-users.**
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
  - **File-based** — `.sql` files named with their version (e.g., `1.0.0.sql`, `1.2.0_add_users.sql`).
  - **Directory-based** — version-named subdirectories containing any number of `.sql` files.
- Multiple files with the same version prefix are supported and executed in alphabetical order (e.g., `1.2.0_a_core_tables.sql`,
  `1.2.0_b_crm_tables.sql`), in both file-based and directory-based structures
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
    ├── 0.0.1.sql
    ├── 0.1.0_create_users.sql
    ├── 1.0.0.sql
    ├── 1.0.0-pre_experimental.sql
    ├── 1.1.0_add_index.sql
    ├── 1.2.0_change.sql
    ├── 1.2.0_crm_tables.sql
    └── 2.0.0.sql
```

### Directory-based

Each version gets its own subdirectory, and all `.sql` files within it are executed in alphabetical order.

```
migrations/ (or a custom directory name)
    ├── 0.0.1/
    │   └── init.sql
    ├── 1.0.0/
    │   └── schema.sql
    ├── 1.1.1/
    │   ├── a_create_tables.sql
    │   ├── b_add_indexes.sql
    │   └── c_seed_data.sql
    └── 2.0.0/
        └── upgrade.sql
```


## Migration behavior

### Direction detection

| Condition                        | Action                                                        |
| -------------------------------- | ------------------------------------------------------------- |
| Current version < target version | **Upgrade** — executes migration files from current → target. |
| Current version > target version | **Downgrade** — executes migration files from current → target (reverse order). |
| Current version = target version | **No-op** — verifies checksums (if enabled) and returns.      |

### Checksum verification

When `checksums: true`, the migrator computes an SHA-256 hash of each migration file's contents.
If the current and target versions are the same, the stored checksum is compared against the calculated one.
A mismatch raises `MigrationChecksumMismatchError`.


## Migration Options

The `MigrationOptions` class accepts the following parameters:

| Parameter        | Type       | Default        | Description                                                                                                   |
|------------------|------------|----------------|---------------------------------------------------------------------------------------------------------------|
| `path`           | `String`   | **(required)** | Path to the migrations directory.                                                                             |
| `directoryBased` | `bool`     | `false`        | Use version-named directories instead of version-prefixed files.                                              |
| `checksums`      | `bool`     | `true`         | Enable SHA-256 checksum calculation and verification.                                                         |
| `filesPattern`   | `RegExp?`  | `null`         | Custom regex for matching migration files. Must contain a `(?<version>[^_]+)` named group in file-based mode. |
| `encoding`       | `Encoding` | `utf8`         | The encoding used to read migration files.                                                                    |
| `schema`         | `String`   | `''`           | Database schema name, for use by concrete implementations.                                                    |
| `versionTable`   | `String`   | `'_version'`   | Name of the version-tracking table, for use by concrete implementations.                                      |
| `retries`        | `int`      | `3`            | Number of retry attempts, for use by concrete implementations.                                                |
| `timeout`        | `Duration` | `15 seconds`   | Maximum duration for operations, for use by concrete implementations.                                         |
| `lockKey`        | `String?`  | `null`         | The key used by the `acquireLock()` and `releaseLock()` methods                                               |


## Usage (for implementation packages)

### 1. Implement the `Migratable` mixin

Apply the `Migratable` mixin to your database class and implement the required members:

```dart
import 'dart:io';

import 'package:dbmigrator_base/dbmigrator_base.dart';

class MyDatabase with Migratable {
  MyDatabase({required this.migrationOptions});

  // Some database connection pool your app or package uses
  // Needs to be instantiated somewhere beforehand
  final Pool? _pool;

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
    await _pool.runTx(fn);
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
    final result = await _pool.execute(sql);
    if (result.isEmpty) return null;

    final row = result.first.toColumnMap();

    return (version: row['version'] as String? ?? '', checksum: row['checksum'] as String? ?? '');
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
  print(result.message); // "Migrated from 2.0.0 ➡ 3.0.0-alpha in 3 seconds."
}
```

## Additional information

### Contributing

Please file feature requests and bugs at the [issue tracker][tracker].

### License

Licensed under the BSD-3-Clause License.

[tracker]: https://github.com/paschalisp/dbmigrator-dart/issues/new