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
  Future<void> saveVersion({required MigrationResult result, ctx}) async {
    // Store the new version to the migrations history
    final sql = 'INSERT INTO _version (version, checksum) VALUES (?, ?)';
    await _conn.execute(sql);
  }
}
