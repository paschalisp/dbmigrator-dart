import 'dart:io';

import 'package:dbmigrator_base/dbmigrator_base.dart';

class MyDatabase with Migratable {
  MyDatabase({required this.migrationsOptions});

  // Some database connection pool your app or package uses
  // Needs to be instantiated somewhere beforehand
  final Pool? _pool;

  @override
  final MigrationOptions migrationsOptions;

  @override
  Future<void> acquireLock() async {
    // Acquire a migration lock
  }

  @override
  Future<void> releaseLock() async {
    // Release the lock acquired earlier
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

  @override
  Future<void> transaction(Future<void> Function(dynamic ctx) fn) async {
    // Create transaction context, then execute the fn inside it and wait for completion
    await _pool.runTx(fn);
  }

  @override
  Future<void> execute(String file, {ctx}) async {
    // Read file's SQL statement contents and execute them
    final sql = await File('${migrationsOptions.path}/$file').readAsString();
    await ctx.execute(sql);
  }
}
