-- ALLOW_SNAPSHOT_ISOLATION: SNAPSHOT transactions read their start state
-- without blocking; without the option the first data access fails 3952,
-- ends the batch and rolls back. Runs in a database of its own (master,
-- the case database of process-isolated emulator runs, allows snapshot
-- isolation).
-- @step setup
IF DB_ID('bitsql_settings_snapshot') IS NOT NULL DROP DATABASE bitsql_settings_snapshot;
CREATE DATABASE bitsql_settings_snapshot;
-- @step batch
USE bitsql_settings_snapshot; CREATE TABLE s (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT s VALUES (1, 10), (2, 20);
-- @step batch
SELECT snapshot_isolation_state, snapshot_isolation_state_desc FROM sys.databases WHERE name = DB_NAME()
-- @step batch
SET TRANSACTION ISOLATION LEVEL SNAPSHOT; SELECT 1 AS no_access; SELECT v FROM s WHERE id = 1; SELECT 2 AS not_reached
-- @step batch
BEGIN TRAN; SELECT 3 AS in_tran; SELECT v FROM s WHERE id = 1; SELECT 4 AS not_reached
-- @step batch
SELECT @@TRANCOUNT AS tc; SET TRANSACTION ISOLATION LEVEL READ COMMITTED
-- @step batch
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON
-- @step batch
SET LOCK_TIMEOUT 0; SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRAN; SELECT v AS start_value FROM s WHERE id = 1
-- @step batch conn=2
USE bitsql_settings_snapshot; UPDATE s SET v = 11 WHERE id = 1
-- @step batch
SELECT v AS still_start FROM s WHERE id = 1
-- @step batch
COMMIT; SELECT v AS after_commit FROM s WHERE id = 1
-- @step batch conn=2
BEGIN TRAN; UPDATE s SET v = 22 WHERE id = 2
-- @step batch
SELECT v AS no_block FROM s WHERE id = 2
-- @step batch conn=2
ROLLBACK
-- @step setup conn=2
USE master
-- @step setup
SET TRANSACTION ISOLATION LEVEL READ COMMITTED; USE master; DROP DATABASE bitsql_settings_snapshot
