-- READ_COMMITTED_SNAPSHOT: plain READ COMMITTED reads take no S lock and see
-- the last committed state at statement start; READCOMMITTEDLOCK, UPDLOCK
-- and writers still wait (LOCK_TIMEOUT 0 makes waits observable as 1222).
-- The option is switched on before the second connection exists (it needs
-- the database to itself).
-- @step setup
CREATE TABLE r (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT r VALUES (1, 10), (2, 20);
-- @step batch
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON
-- @step batch
SET LOCK_TIMEOUT 0; SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = DB_NAME(); DBCC USEROPTIONS WITH NO_INFOMSGS
-- @step batch conn=2
BEGIN TRAN; UPDATE r SET v = 12 WHERE id = 1; SELECT v FROM r WHERE id = 1
-- @step batch
SELECT id, v FROM r ORDER BY id
-- @step batch
SELECT v FROM r WITH (READCOMMITTEDLOCK) WHERE id = 1
-- @step batch
UPDATE r SET v = 13 WHERE id = 1
-- @step batch
SELECT v FROM r WITH (UPDLOCK) WHERE id = 1
-- @step batch
BEGIN TRAN; SELECT v AS first_read FROM r WHERE id = 1
-- @step batch conn=2
COMMIT
-- @step batch
SELECT v AS second_read FROM r WHERE id = 1; COMMIT
-- @step batch
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; BEGIN TRAN; SELECT v FROM r WHERE id = 2
-- @step batch conn=2
SET LOCK_TIMEOUT 0; UPDATE r SET v = 21 WHERE id = 2
-- @step batch
COMMIT; SET TRANSACTION ISOLATION LEVEL READ COMMITTED
-- @step batch conn=2
BEGIN TRAN; DELETE r WHERE id = 2; INSERT r VALUES (3, 30)
-- @step batch
SELECT id, v FROM r ORDER BY id; SELECT COUNT(*) AS n FROM r
-- @step batch conn=2
COMMIT
-- @step batch
SELECT id, v FROM r ORDER BY id
