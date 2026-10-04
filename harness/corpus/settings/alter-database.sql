-- ALTER DATABASE: completion tokens, compile-time vs statement errors,
-- SET options reflected in sys.databases and DATABASEPROPERTYEX.
-- @step batch
SELECT DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS c, collation_name, compatibility_level, is_read_committed_snapshot_on, user_access_desc, is_read_only, is_local_cursor_default FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 100
-- @step batch
SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 99; SELECT 1 AS after15048
-- @step batch
ALTER DATABASE CURRENT COLLATE Nonsense_Coll; SELECT 1 AS after448
-- @step batch
ALTER DATABASE nosuchdb SET COMPATIBILITY_LEVEL = 110; SELECT 1 AS after5069
-- @step batch
BEGIN TRAN; ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 110; SELECT 1 AS after226, @@TRANCOUNT AS tc
-- @step batch
IF @@TRANCOUNT > 0 ROLLBACK
-- @step batch
ALTER DATABASE CURRENT SET SINGLE_USER; SELECT DATABASEPROPERTYEX(DB_NAME(), 'UserAccess') AS ua, user_access, user_access_desc FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET MULTI_USER WITH ROLLBACK IMMEDIATE
-- @step batch
ALTER DATABASE CURRENT SET CURSOR_DEFAULT LOCAL; SELECT DATABASEPROPERTYEX(DB_NAME(), 'IsLocalCursorsDefault') AS lc, is_local_cursor_default FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET CURSOR_DEFAULT GLOBAL
-- @step batch
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE; SELECT DATABASEPROPERTYEX(DB_NAME(), 'IsReadCommittedSnapshotOn') AS p, is_read_committed_snapshot_on FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT OFF
-- @step batch
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON; SELECT snapshot_isolation_state, snapshot_isolation_state_desc FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION OFF
-- @step batch
CREATE TABLE s (a int)
-- @step batch
ALTER DATABASE CURRENT SET READ_ONLY; SELECT DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS u, is_read_only FROM sys.databases WHERE name = DB_NAME()
-- @step batch
INSERT s VALUES (1); SELECT 1 AS after_insert
-- @step batch
CREATE TABLE s2 (a int)
-- @step batch
CREATE TABLE #tmp (a int); INSERT #tmp VALUES (1); DECLARE @t TABLE (a int); INSERT @t VALUES (2); SELECT (SELECT a FROM #tmp) AS t1, (SELECT a FROM @t) AS t2, (SELECT COUNT(*) FROM s) AS n
-- @step batch
ALTER DATABASE CURRENT SET READ_WRITE
-- @step batch
INSERT s VALUES (1); SELECT a FROM s
-- @step batch
ALTER DATABASE CURRENT SET ANSI_NULLS ON, ANSI_PADDING ON; SELECT DATABASEPROPERTYEX(DB_NAME(), 'IsAnsiNullsEnabled') AS a, is_ansi_nulls_on, is_ansi_padding_on FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET ANSI_NULLS OFF, ANSI_PADDING OFF
-- @step batch
ALTER DATABASE CURRENT SET AUTO_CLOSE OFF
-- @step batch
ALTER DATABASE CURRENT SET BOGUS_OPTION ON
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160, RECOVERY SIMPLE; SELECT compatibility_level, recovery_model, recovery_model_desc, DATABASEPROPERTYEX(DB_NAME(), 'Recovery') AS r FROM sys.databases WHERE name = DB_NAME()
-- @step batch
ALTER DATABASE CURRENT SET RECOVERY FULL, COMPATIBILITY_LEVEL = 170
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL 150
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170
-- @step batch
DECLARE @d sysname = DB_NAME(); EXEC('ALTER DATABASE [' + @d + '] SET COMPATIBILITY_LEVEL = 140'); SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME(); EXEC('ALTER DATABASE [' + @d + '] SET COMPATIBILITY_LEVEL = 170')
