import 'package:dbmigrator/dbmigrator.dart';
import 'package:test/test.dart';

void main() {
  const String select1Checksum = '17db4fd369edb9244b9f91d9aeed145c3d04ad8ba6e95d06247f07a63527d11a';

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
    test('version and dir can be anywhere in the regex pattern', () {
      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'file_(?<version>[^_]+)_.(?<dir>up|down).run.sql')),
        returnsNormally,
      );
    });

    test('version and dir can be the whole regex pattern', () {
      expect(
        () => MigrationOptions(path: './', filesPattern: RegExp(r'(?<version>[^_]+).(?<dir>up|down).sql')),
        returnsNormally,
      );
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
      final versions = (await db.queryMigrationVersions('2.0.0', direction: MigrationDirection.down)).names();

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
        direction: MigrationDirection.down,
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
        direction: MigrationDirection.down,
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

      expect(versions['0.0.1']?.names(), containsAllInOrder(['0.0.1.up.sql']));
      expect(versions['0.0.1']?.firstOrNull?.checksum, select1Checksum);
      expect(versions['0.1.0']?.names(), containsAllInOrder(['0.1.0_test.up.sql']));
      expect(versions['1.0.0-pre']?.names(), containsAllInOrder(['1.0.0-pre_test.up.sql']));
      expect(versions['1.0.0']?.names(), containsAllInOrder(['1.0.0.up.sql']));
      expect(versions['1.1.0']?.names(), containsAllInOrder(['1.1.0_test.up.sql']));
      expect(versions['1.1.1']?.names(), containsAllInOrder(['1.1.1_test.up.sql']));
      expect(versions['1.2.0']?.names(), containsAllInOrder(['1.2.0_test.up.sql', '1.2.0_test2.up.sql']));
      expect(versions['2.0.0-rc1']?.names(), containsAllInOrder(['2.0.0-rc1.up.sql']));
      expect(versions['2.0.0']?.names(), containsAllInOrder(['2.0.0.up.sql']));
    });

    test('Returns the correct downgrade files per version', () async {
      final versions = await db.queryMigrationFiles(
        '1.0.0',
        current: (version: '2.0.0', checksum: ''),
        direction: MigrationDirection.down,
      );

      expect(versions.keys.toList(), containsAllInOrder(['2.0.0', '2.0.0-rc1', '1.2.0', '1.1.1', '1.1.0']));
      expect(versions['2.0.0']?.names(), containsAllInOrder(['2.0.0.down.sql']));
      expect(versions['1.2.0']?.names(), containsAllInOrder(['1.2.0_test.down.sql', '1.2.0_test2.down.sql']));
      expect(versions['1.1.1']?.names(), containsAllInOrder(['1.1.1_test.down.sql']));
      expect(versions['1.1.0']?.names(), containsAllInOrder(['1.1.0_test.down.sql']));
    });
  });

  group('queryMigrationFiles modes', () {
    final db = DummyDb(
      currentVersion: '',
      migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
    );

    test('none with a newer target behaves as up', () async {
      final v = await db.queryMigrationFiles(
        '1.0.0',
        current: (version: '0.1.0', checksum: ''),
        direction: MigrationDirection.none,
      );
      expect(v.keys.toList(), ['1.0.0-pre', '1.0.0']);
    });

    test('none with an older target behaves as down', () async {
      final v = await db.queryMigrationFiles(
        '1.0.0',
        current: (version: '1.1.0', checksum: ''),
        direction: MigrationDirection.none,
      );
      expect(v.keys.toList(), ['1.1.0']);
    });

    test('none with the same version returns empty', () async {
      final v = await db.queryMigrationFiles(
        '1.0.0',
        current: (version: '1.0.0', checksum: ''),
        direction: MigrationDirection.none,
      );
      expect(v, isEmpty);
    });

    test('up without target returns everything newer than current', () async {
      final v = await db.queryMigrationFiles('', current: (version: '1.2.0', checksum: ''));
      expect(v.keys.toList(), ['2.0.0-rc1', '2.0.0']);
    });

    test('down without target returns everything down to the oldest', () async {
      final v = await db.queryMigrationFiles(
        '',
        current: (version: '0.1.0', checksum: ''),
        direction: MigrationDirection.down,
      );
      expect(v.keys.toList(), ['0.1.0', '0.0.1']);
    });

    test('none without target lists all versions with up and down files', () async {
      final v = await db.queryMigrationFiles('', direction: MigrationDirection.none);
      expect(v.keys.first, '0.0.1');
      expect(v.keys.last, '2.0.0');
      expect(v['1.2.0']?.names(), containsAll(['1.2.0_test.up.sql', '1.2.0_test.down.sql']));
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
      final versions = await db.queryMigrationVersions('3.0.0', direction: MigrationDirection.down);

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
        direction: MigrationDirection.down,
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
        direction: MigrationDirection.down,
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

      expect(versions['0.0.1']?.names(), containsAllInOrder(['up.sql']));
      expect(versions['0.0.1']?.firstOrNull?.checksum, select1Checksum);
      expect(versions['0.1.0']?.names(), containsAllInOrder(['up.sql']));
      expect(versions['1.0.0']?.names(), containsAllInOrder(['up.sql']));
      expect(versions['1.1.0']?.names(), containsAllInOrder(['up.sql']));
      expect(versions['1.1.1']?.names(), containsAllInOrder(['a.up.sql', 'b.up.sql', 'c.up.sql']));
      expect(versions['1.2.0']?.names(), containsAllInOrder(['up.sql']));
      expect(versions['2.0.0']?.names(), containsAllInOrder(['up.sql']));
    });

    test('Returns the correct downgrade files per version', () async {
      final versions = await db.queryMigrationFiles(
        '1.0.0',
        current: (version: '2.0.0', checksum: ''),
        direction: MigrationDirection.down,
      );

      expect(versions.keys.toList(), containsAllInOrder(['2.0.0', '2.0.0-rc1', '1.2.0', '1.1.1']));
      expect(versions['2.0.0']?.names(), containsAllInOrder(['down.sql']));
      expect(versions['1.2.0']?.names(), containsAllInOrder(['down.sql']));
      expect(versions['1.1.1']?.names(), containsAllInOrder(['c.down.sql', 'b.down.sql', 'a.down.sql']));
      expect(versions['1.1.0']?.names(), containsAllInOrder(['down.sql']));
    });
  });

  group('File-based migrations execution', () {
    final db = DummyDb(
      currentVersion: '1.1.1',
      migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: true),
    );

    test('Executes the correct upgrade migration files', () async {
      final res = await db.migrate(version: '2.0.0');
      expect(res.direction, MigrationDirection.up);
      expect(
        res.files.names(),
        containsAllInOrder(['1.2.0_test.up.sql', '1.2.0_test2.up.sql', '2.0.0-rc1.up.sql', '2.0.0.up.sql']),
      );
    });

    test('Executes the correct downgrade migration files', () async {
      final res = await db.migrate(version: '0.0.1');
      expect(res.direction, MigrationDirection.down);
      expect(
        res.files.names(),
        containsAllInOrder(['1.1.0_test.down.sql', '1.0.0.down.sql', '1.0.0-pre_test.down.sql', '0.1.0_test.down.sql']),
      );
    });

    test('Calls saveVersion() before committing the transaction', () async {
      final db = DummyDb(
        currentVersion: '1.1.1',
        migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
        commitCallback: () => throw UnsupportedError('callback called'),
      );

      expect(() async => await db.migrate(version: '2.0.0'), throwsA(isA<UnsupportedError>()));
    });

    test('Does not call saveVersion() if targeting the current version', () async {
      final db = DummyDb(
        currentVersion: '1.1.1',
        migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
        commitCallback: () => throw UnsupportedError('callback called'),
      );

      expect(() async => await db.migrate(version: '1.1.1'), isA<Function>());
    });

    test('Returns the correct migration results', () async {
      final res = await db.migrate(version: '2.0.0');
      expect(res.fromVersion, '1.1.1');
      expect(res.toVersion, '2.0.0');
      expect(res.path, isNotEmpty);
      expect(res.checksum, select1Checksum);
    });
  });

  group('Directory-based migrations execution', () {
    final db = DummyDb(
      currentVersion: '1.1.1',
      migrationOptions: MigrationOptions(path: './test/migrations/dir-based', directoryBased: true, checksums: false),
    );

    test('Executes the correct upgrade migration files', () async {
      final res = await db.migrate(version: '2.0.0');
      expect(res.direction, MigrationDirection.up);
      expect(res.files.names(), containsAllInOrder(['1.2.0/up.sql', '2.0.0-rc1/up.sql', '2.0.0/up.sql']));
    });

    test('Executes the correct downgrade migration files', () async {
      final res = await db.migrate(version: '0.0.1');
      expect(res.direction, MigrationDirection.down);
      expect(
        res.files.names(),
        containsAllInOrder(['1.1.0/down.sql', '1.0.0/down.sql', '1.0.0-pre/down.sql', '0.1.0/down.sql']),
      );
    });
  });

  group('Same current/target version checks', () {
    test('Migrating to the same version returns none as direction', () async {
      final db = DummyDb(
        currentVersion: '1.1.1',
        migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
      );

      final res = await db.migrate(version: '1.1.1');
      expect(res.direction, MigrationDirection.none);
    });

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
        currentChecksum: select1Checksum,
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

  group('Strict target version', () {
    final db = DummyDb(
      currentVersion: '1.0.0',
      migrationOptions: MigrationOptions(path: './test/migrations/file-based', checksums: false),
    );

    test('Fails early when the target version does not exist', () async {
      expect(() => db.migrate(version: '9.9.9'), throwsA(isA<MigrationInvalidVersionError>()));
    });

    test('Fails when neither version nor latest is given', () async {
      expect(() => db.migrate(), throwsA(isA<MigrationInvalidVersionError>()));
    });

    test('Fails when both version and latest are given', () async {
      expect(() => db.migrate(version: '1.0.0', latest: true), throwsA(isA<MigrationInvalidVersionError>()));
    });

    test('latest migrates to the newest existing version and records it', () async {
      final res = await db.migrate(latest: true);
      expect(res.toVersion, '2.0.0');
      expect(res.direction, MigrationDirection.up);
    });

    test('Downgrade records the target version', () async {
      final res = await db.migrate(version: '0.1.0');
      expect(res.toVersion, '0.1.0');
      expect(res.direction, MigrationDirection.down);
    });
  });

  group('natural version sorting checks', () {
    test('identical strings are equal', () {
      expect(naturalCompare('1_init.up.sql', '1_init.up.sql'), 0);
      expect(naturalCompare('', ''), 0);
    });

    test('empty string sorts first', () {
      expect(naturalCompare('', 'a'), isNegative);
      expect(naturalCompare('a', ''), isPositive);
    });

    test('digit runs compare numerically', () {
      expect(naturalCompare('2_x', '10_x'), isNegative);
      expect(naturalCompare('10_x', '2_x'), isPositive);
      expect(naturalCompare('file9', 'file10'), isNegative);
    });

    test('very long digit runs do not overflow', () {
      expect(naturalCompare('99999999999999999999999', '100000000000000000000000'), isNegative);
      expect(naturalCompare('100000000000000000000000', '99999999999999999999999'), isPositive);
    });

    test('letters compare alphabetically', () {
      expect(naturalCompare('a_x', 'b_x'), isNegative);
      expect(naturalCompare('b_x', 'a_x'), isPositive);
    });

    test('letters compare case-insensitively first', () {
      expect(naturalCompare('A_x', 'b_x'), isNegative);
      expect(naturalCompare('b_x', 'A_x'), isPositive);
    });

    test('case-only differences are ordered deterministically, never equal', () {
      final c = naturalCompare('a', 'A');
      expect(c, isNot(0));
      expect(naturalCompare('A', 'a'), c.isNegative ? isPositive : isNegative);
    });

    test('leading zeros are numerically equal but ordered deterministically', () {
      expect(naturalCompare('01', '1'), isNot(0));
      expect(naturalCompare('01', '2'), isNegative);
      expect(naturalCompare('02', '10'), isNegative);
    });

    test('a prefix sorts before a longer string', () {
      expect(naturalCompare('a', 'a1'), isNegative);
      expect(naturalCompare('a1', 'a'), isPositive);
      expect(naturalCompare('1', '1_x'), isNegative);
    });

    test('digits and non-digits are compared as strings', () {
      expect(naturalCompare('1', 'a'), isNegative);
      expect(naturalCompare('a', '1'), isPositive);
      expect(naturalCompare('1', '-'), isPositive);
    });

    test('multiple digit runs are compared left to right', () {
      expect(naturalCompare('1.2.10', '1.2.9'), isPositive);
      expect(naturalCompare('1.10.0', '1.9.9'), isPositive);
      expect(naturalCompare('2.0.0', '10.0.0'), isNegative);
    });

    test('is antisymmetric', () {
      const samples = ['', 'a', 'A', 'a1', 'a01', 'a2', 'a10', '1', '01', '10', '_x', '1_x.up.sql'];
      for (final a in samples) {
        for (final b in samples) {
          expect(naturalCompare(a, b).sign, -naturalCompare(b, a).sign, reason: '$a vs $b');
        }
      }
    });

    test('sorts a mixed list in natural order', () {
      final list = ['10_x', '2_x', '1_x', 'b_x', 'a_x', '20_x', '3_x']..sort(naturalCompare);
      expect(list, ['1_x', '2_x', '3_x', '10_x', '20_x', 'a_x', 'b_x']);
    });

    test('sorts letter-prefixed names', () {
      final list = ['c_seed.up.sql', 'a_create.up.sql', 'b_index.up.sql']..sort(naturalCompare);
      expect(list, ['a_create.up.sql', 'b_index.up.sql', 'c_seed.up.sql']);
    });
  });
}

class DummyDb with Migratable {
  const DummyDb({
    required this.currentVersion,
    required this.migrationOptions,
    this.currentChecksum = '',
    this.commitCallback,
  });

  final String currentVersion;
  final String currentChecksum;
  final Function()? commitCallback;

  @override
  final MigrationOptions migrationOptions;

  @override
  Future<({String version, String checksum})> queryVersion() async =>
      (version: currentVersion, checksum: currentChecksum);

  @override
  Future<void> saveVersion({required MigrationResult result, ctx, String? comment, Function()? callback}) async {
    (callback ?? commitCallback)?.call();
  }

  @override
  Future<dynamic> execute(Object stmt, {ctx}) async {
    // do nothing
  }

  @override
  Future<void> transaction(Future<void> Function(dynamic ctx) fn) async {
    await fn(null);
  }
}
