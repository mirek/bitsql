-- DATABASEPROPERTYEX on a user database and the system databases: values
-- and base types; unknown databases/properties are NULL; names are
-- case-insensitive. (A database of its own: the harness runs cases in
-- master on the emulator and in a fresh database on the oracle.)
-- @step setup
DROP DATABASE IF EXISTS bitsql_prop_db;
CREATE DATABASE bitsql_prop_db;
-- @step batch
SELECT p, DATABASEPROPERTYEX('bitsql_prop_db', p) AS u, DATABASEPROPERTYEX('master', p) AS m,
       SQL_VARIANT_PROPERTY(DATABASEPROPERTYEX('bitsql_prop_db', p), 'BaseType') AS bt,
       SQL_VARIANT_PROPERTY(DATABASEPROPERTYEX('bitsql_prop_db', p), 'MaxLength') AS ml
FROM (VALUES ('Collation'), ('ComparisonStyle'), ('Edition'), ('IsAnsiNullDefault'), ('IsAnsiNullsEnabled'),
  ('IsAnsiPaddingEnabled'), ('IsAnsiWarningsEnabled'), ('IsArithmeticAbortEnabled'), ('IsAutoClose'),
  ('IsAutoCreateStatistics'), ('IsAutoCreateStatisticsIncremental'), ('IsAutoShrink'), ('IsAutoUpdateStatistics'),
  ('IsClone'), ('IsCloseCursorsOnCommitEnabled'), ('IsDatabaseSuspendedForSnapshotBackup'), ('IsFulltextEnabled'),
  ('IsInStandBy'), ('IsLocalCursorsDefault'), ('IsMemoryOptimizedElevateToSnapshotEnabled'), ('IsMergePublished'),
  ('IsNullConcat'), ('IsNumericRoundAbortEnabled'), ('IsParameterizationForced'), ('IsQuotedIdentifiersEnabled'),
  ('IsPublished'), ('IsRecursiveTriggersEnabled'), ('IsSubscribed'), ('IsSyncWithBackup'), ('IsTornPageDetectionEnabled'),
  ('IsVerifiedClone'), ('IsXTPSupported'), ('LastGoodCheckDbTime'), ('LCID'), ('MaxSizeInBytes'), ('Recovery'),
  ('ServiceObjective'), ('ServiceObjectiveId'), ('SQLSortOrder'), ('Status'), ('Updateability'), ('UserAccess'),
  ('Version'), ('ReplicaID'), ('IsReadCommittedSnapshotOn'), ('Bogus'), ('status')) AS x(p);
SELECT DATABASEPROPERTYEX('nosuchdb', 'Status') AS a, DATABASEPROPERTYEX(NULL, 'Status') AS b,
       DATABASEPROPERTYEX('master', NULL) AS c, DATABASEPROPERTYEX(N'MASTER', 'Collation') AS d,
       DATABASEPROPERTYEX('[master]', 'Status') AS e, DATABASEPROPERTYEX(1, 'Status') AS f,
       DATABASEPROPERTYEX('tempdb', 'Status') AS g;
-- (database names are not selected: the harness rewrites "master")
SELECT k, DATABASEPROPERTYEX(d, 'Recovery') AS r, DATABASEPROPERTYEX(d, 'IsFulltextEnabled') AS f,
       DATABASEPROPERTYEX(d, 'Version') AS v, DATABASEPROPERTYEX(d, 'Status') AS st
FROM (VALUES (1, 'master'), (2, 'tempdb'), (3, 'model'), (4, 'msdb'), (5, 'bitsql_prop_db')) AS x(k, d);
-- @step batch
SELECT DATABASEPROPERTYEX('master');
-- @step batch
DROP DATABASE bitsql_prop_db;
