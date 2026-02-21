import 'package:dbmigrator_base/dbmigrator_base.dart';
import 'package:test/test.dart';

void main() {
  const String select1Checksum = '17db4fd369edb9244b9f91d9aeed145c3d04ad8ba6e95d06247f07a63527d11a';
  const String v111Checksum = '6c024c2720d15a453119b89c9f5a68b60084b7a7ad3aadcb17a079d822b060cd';

  group('Migration options model checks', () {
    test('Default lockKey is correct when no schema is given', () {
      final options = MigrationOptions(path: './');
      expect(options.lockKey, 'migration:${options.versionTable}');
    });
    test('Default lockKey is correct when a custom schema and version table is given', () {
      final options = MigrationOptions(path: './', schema: 'public', versionTable: '_test');
      expect(options.lockKey, 'migration:public._test');
    });
  });

  group('Migration file pattern checks', () {
    test('version can be anywhere in the regex pattern', () {
      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'file_(?<version>[^_]+)_run.sql')),
        returnsNormally,
      );

      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'file_(?<version>[^_]+)_run.sql')),
        returnsNormally,
      );
    });

    test('version can be the whole regex pattern', () {
      expect(() => MigrationOptions(path: './', filesPattern: RegExp(r'(?<version>[^_]+)')), returnsNormally);
    });

    test('invalid version pattern in regex raises exception', () {
      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'<version>.sql')),
        throwsA(isA<AssertionError>()),
        reason: 'Regex pattern must contain (?<version>[^_]+)',
      );
      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'(?<version>.+).sql')),
        throwsA(isA<AssertionError>()),
        reason: 'Regex pattern must contain (?<version>[^_]+)',
      );
      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'invalid.sql')),
        throwsA(isA<AssertionError>()),
        reason: 'Regex pattern must contain (?<version>[^_]+)',
      );
    });
  });

  group('File-based migration version checks', () {
    final db = DummyDb(
      currentVersion: '',
      migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
    );

    test('Empty current version returns all migration upgrades found', () async {
      final versions = (await db.queryMigrationVersions('9.9.9')).names();

      expect(
        versions,
        containsAllInOrder(['0.0.1', '0.1.0', '1.0.0-pre', '1.0.0', '1.1.0', '1.1.1', '1.2.0', '2.0.0-rc1', '2.0.0']),
      );
    });

    test('Empty current version returns no migration downgrades', () async {
      final versions = (await db.queryMigrationVersions('2.0.0', upgradable: false)).names();

      expect(versions, isEmpty);
    });

    test('Current version newer than target returns no migration upgrades', () async {
      final versions = await db.queryMigrationVersions('1.0.0', current: (version: '1.1.1', checksum: ''));

      expect(versions, isEmpty);
    });

    test('Current version older than target returns no migration downgrades', () async {
      final versions = await db.queryMigrationVersions(
        '1.0.0',
        current: (version: '0.1.0', checksum: ''),
        upgradable: false,
      );

      expect(versions, isEmpty);
    });

    test('Returns the correct version upgrades', () async {
      final versions = (await db.queryMigrationVersions('2.0.0')).names();

      expect(versions, containsAllInOrder(['1.2.0', '2.0.0']));
    });

    test('Returns the correct version downgrades', () async {
      final versions = (await db.queryMigrationVersions(
        '0.0.0',
        current: (version: '1.1.1', checksum: ''),
        upgradable: false,
      )).names();

      expect(versions, containsAllInOrder(['1.1.0', '1.0.0', '1.0.0-pre', '0.1.0', '0.0.1']));
    });

    test('Throws exception on invalid current version', () async {
      expect(
        () async => await db.queryMigrationVersions('2.0.0', current: (version: 'invalid', checksum: '')),
        throwsA(isA<MigrationInvalidVersionError>()),
      );
    });

    test('Throws exception on invalid target version', () async {
      expect(() async => await db.queryMigrationVersions('invalid'), throwsA(isA<MigrationInvalidVersionError>()));
    });
  });

  group('File-based migration file checks', () {
    final db = DummyDb(
      currentVersion: '',
      migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: true),
    );

    test('Empty current version returns all migration upgrades found', () async {
      final versions = (await db.queryMigrationVersions('3.0.0')).names();

      expect(versions, containsAllInOrder(['0.0.1', '0.1.0', '1.0.0', '1.1.0', '1.1.1', '1.2.0', '2.0.0']));
    });

    test('Returns the correct migration files and checksums per version', () async {
      final versions = await db.queryMigrationFiles('3.0.0');

      expect(versions['0.0.1']?.names(), containsAllInOrder(['0.0.1.sql']));
      expect(versions['0.0.1']?.firstOrNull?.checksum, select1Checksum);
      expect(versions['0.1.0']?.names(), containsAllInOrder(['0.1.0_test.sql']));
      expect(versions['1.0.0-pre']?.names(), containsAllInOrder(['1.0.0-pre_test.sql']));
      expect(versions['1.0.0']?.names(), containsAllInOrder(['1.0.0.sql']));
      expect(versions['1.1.0']?.names(), containsAllInOrder(['1.1.0_test.sql']));
      expect(versions['1.1.1']?.names(), containsAllInOrder(['1.1.1_test.sql']));
      expect(versions['1.2.0']?.names(), containsAllInOrder(['1.2.0_test.sql', '1.2.0_test2.sql']));
      expect(versions['2.0.0-rc1']?.names(), containsAllInOrder(['2.0.0-rc1.sql']));
      expect(versions['2.0.0']?.names(), containsAllInOrder(['2.0.0.sql']));
    });
  });

  group('Directory-based migration version checks', () {
    final db = DummyDb(
      currentVersion: '',
      migrationOptions: MigrationOptions(path: './test/migrations/dir-based', directoryBased: true, checksums: false),
    );

    // Same as file-based version tests

    test('Empty current version returns all migration upgrades found', () async {
      final versions = (await db.queryMigrationVersions('3.0.0')).names();

      expect(
        versions,
        containsAllInOrder(['0.0.1', '0.1.0', '1.0.0-pre', '1.0.0', '1.1.0', '1.1.1', '1.2.0', '2.0.0-rc1', '2.0.0']),
      );
    });

    test('Empty current version returns no migration downgrades', () async {
      final versions = await db.queryMigrationVersions('3.0.0', upgradable: false);

      expect(versions, isEmpty);
    });

    test('Current version newer than target returns no migration upgrades', () async {
      final versions = await db.queryMigrationVersions('1.0.0', current: (version: '1.1.1', checksum: ''));

      expect(versions, isEmpty);
    });

    test('Current version older than target returns no migration downgrades', () async {
      final versions = await db.queryMigrationVersions(
        '1.0.0',
        current: (version: '0.1.0', checksum: ''),
        upgradable: false,
      );

      expect(versions, isEmpty);
    });

    test('Returns the correct version upgrades', () async {
      final versions = (await db.queryMigrationVersions('3.0.0')).names();

      expect(versions, containsAllInOrder(['1.2.0', '2.0.0-rc1', '2.0.0']));
    });

    test('Returns the correct version downgrades', () async {
      final versions = (await db.queryMigrationVersions(
        '0.0.0',
        current: (version: '1.1.1', checksum: ''),
        upgradable: false,
      )).names();

      expect(versions, containsAllInOrder(['1.1.0', '1.0.0', '0.1.0', '0.0.1']));
    });

    test('Throws exception on invalid current version', () async {
      expect(
        () async => await db.queryMigrationVersions('3.0.0', current: (version: 'invalid', checksum: '')),
        throwsA(isA<MigrationInvalidVersionError>()),
      );
    });

    test('Throws exception on invalid target version', () async {
      expect(() async => await db.queryMigrationVersions('invalid'), throwsA(isA<MigrationInvalidVersionError>()));
    });
  });

  group('Directory-based migration file checks', () {
    final db = DummyDb(
      currentVersion: '',
      migrationOptions: MigrationOptions(path: './test/migrations/dir-based', directoryBased: true, checksums: true),
    );

    test('Empty current version returns all migration upgrades found', () async {
      final versions = (await db.queryMigrationVersions('3.0.0')).names();

      expect(versions, containsAllInOrder(['0.0.1', '0.1.0', '1.0.0', '1.1.0', '1.1.1', '1.2.0', '2.0.0']));
    });

    test('Returns the correct migration files per version', () async {
      final versions = await db.queryMigrationFiles('3.0.0');

      expect(versions['0.0.1']?.names(), containsAllInOrder(['empty.sql']));
      expect(versions['0.0.1']?.firstOrNull?.checksum, select1Checksum);
      expect(versions['0.1.0']?.names(), containsAllInOrder(['empty.sql']));
      expect(versions['1.0.0']?.names(), containsAllInOrder(['empty.sql']));
      expect(versions['1.1.0']?.names(), containsAllInOrder(['empty.sql']));
      expect(versions['1.1.1']?.names(), containsAllInOrder(['a.sql', 'b.sql', 'c.sql']));
      expect(versions['1.2.0']?.names(), containsAllInOrder(['empty.sql']));
      expect(versions['2.0.0']?.names(), containsAllInOrder(['empty.sql']));
    });
  });

  group('File-based migrations execution', () {
    final db = DummyDb(
      currentVersion: '1.1.1',
      migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
    );

    test('Executes the correct upgrade migration files', () async {
      final res = await db.migrate(version: '2.0.0');
      expect(res.upgrade, isTrue);
      expect(
        res.files.names(),
        containsAllInOrder(['1.2.0_test.sql', '1.2.0_test2.sql', '2.0.0-rc1.sql', '2.0.0.sql']),
      );
    });

    test('Executes the correct downgrade migration files', () async {
      final res = await db.migrate(version: '0.0.0');
      expect(res.upgrade, isFalse);
      expect(
        res.files.names(),
        containsAllInOrder(['1.1.0_test.sql', '1.0.0.sql', '1.0.0-pre_test.sql', '0.1.0_test.sql', '0.0.1.sql']),
      );
    });
  });

  group('Directory-based migrations execution', () {
    final db = DummyDb(
      currentVersion: '1.1.1',
      migrationOptions: MigrationOptions(path: './test/migrations/dir-based', directoryBased: true, checksums: false),
    );

    test('Executes the correct upgrade migration files', () async {
      final res = await db.migrate(version: '2.0.0');
      expect(res.upgrade, isTrue);
      expect(res.files.names(), containsAllInOrder(['1.2.0/empty.sql', '2.0.0-rc1/empty.sql', '2.0.0/empty.sql']));
    });

    test('Executes the correct downgrade migration files', () async {
      final res = await db.migrate(version: '0.0.0');
      expect(res.upgrade, isFalse);
      expect(
        res.files.names(),
        containsAllInOrder([
          '1.1.0/empty.sql',
          '1.0.0/empty.sql',
          '1.0.0-pre/empty.sql',
          '0.1.0/empty.sql',
          '0.0.1/empty.sql',
        ]),
      );
    });
  });

  group('Same local/db version checks', () {
    test('Migrating to the same version with checksums disabled returns successfully with empty migrations', () async {
      final db = DummyDb(
        currentVersion: '1.1.1',
        migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
      );

      final res = await db.migrate(version: '1.1.1');
      expect(res.files, isEmpty);
    });

    test('Migrating to the same version with matching checksums returns successfully with empty migrations', () async {
      final db = DummyDb(
        currentVersion: '1.1.1',
        currentChecksum: v111Checksum,
        migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: true),
      );

      final res = await db.migrate(version: '1.1.1');
      expect(res.files, isEmpty);
    });

    test(
      'Migrating to the same version with non-matching checksums throws exception when checksums are enabled',
      () async {
        final db = DummyDb(
          currentVersion: '1.1.1',
          currentChecksum: 'invalid',
          migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: true),
        );

        expect(() async => await db.migrate(version: '1.1.1'), throwsA(isA<MigrationChecksumMismatchError>()));
      },
    );
  });
}

class DummyDb with Migratable {
  const DummyDb({required this.currentVersion, required this.migrationOptions, this.currentChecksum = ''});

  final String currentVersion;
  final String currentChecksum;

  @override
  final MigrationOptions migrationOptions;

  @override
  Future<({String version, String checksum})> queryVersion() async =>
      (version: currentVersion, checksum: currentChecksum);

  @override
  Future<dynamic> execute(Object stmt, {ctx}) async {
    // do nothing
  }

  @override
  Future<void> transaction(Future<void> Function(dynamic ctx) fn) async {
    await fn(null);
  }
}
