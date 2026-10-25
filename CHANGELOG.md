## 0.2.0

> ⚠️ **BREAKING:** The checksum algorithm changed: a version's checksum is now calculated from the names and contents of **all** of
> the version's files (previously, multi-file versions hashed only the file names), ignoring BOM and CRLF/LF
> differences. So **checksums already stored in your version table won't match the ones this
> version calculates**. If the database is already at the target version, `migrate()` throws
> `MigrationChecksumMismatchError`. If it is behind, the migration runs properly and the new checksum replaces the old.
>
> Choose one of:
>
> - **Update the stored checksum** of your current version to the new value (from `queryMigrationVersions()`)
>   before running `migrate()` with the new package version.
> - **Upgrade to this package version together with your next new migration version.** That migration runs and stores the
> checksum calculated the new way.
>
> Databases with no stored checksum are not affected.

**Breaking changes**

- `migrate()` now requires the target version to exist (at least one `up` or `down` file for it); otherwise it throws
  `MigrationInvalidVersionError` before locking. Previously any version was accepted as an upper bound.
- `migrate()`'s `version` is now optional; use the new `latest: true` flag to migrate to the newest existing version.
- The recorded `toVersion` is now always the target version (it was the last executed file's version).
- **Checksums changed, stored checksums will mismatch (see the warning above).** Multi-file
  version checksums now include file contents, and checksums ignore BOM and CRLF/LF differences. The stored result
  checksum is now the checksum of the target version's `up` files.
- Default file regexes are anchored (`^...$`); empty target versions are rejected explicitly.

- `queryMigrationFiles()` / `queryMigrationVersions()` changes:
  - `MigrationDirection.none` with a version is now auto-mode: it resolves to `up` or `down` by comparing the current
    and target versions, and returns an empty map when they are equal (it used to return the target version's files).
  - An empty target version no longer throws: with `up` it returns everything newer than current, with `down`
    everything down to the oldest version, and with `none` all versions' files (both `up` and `down`, no checksums).
  - Files within a version are sorted in natural order.

**Fixes**

- `migrate()` passes `comment` through and uses the caller's `ctx` instead of always opening a transaction.
- Fixed the target-version error message, `copyWith` dropping `lockKey`, and `filesPattern` validation (now checks named groups).
- Directory scan no longer swallows I/O errors; invalid semver names are reported in the result message.
- Natural file ordering (`2_x` before `10_x`), empty SQL files skipped, `retries >= 1` asserted.
- Platform-independent paths: migration directory and file names are now read with `package:path` instead of splitting on `/`, so Windows paths work.
- Add more tests against common and edge cases.

## 0.1.2

- Downgrade migration fixes.

## 0.1.1

- Added `MigrationDirection` enum for specifying the migration direction more precisely.

## 0.1.0

- Initial version.
