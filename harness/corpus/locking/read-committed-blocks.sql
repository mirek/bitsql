-- READ COMMITTED (locking, the default with READ_COMMITTED_SNAPSHOT OFF):
-- a plain SELECT of a row another transaction modified waits for COMMIT.
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, v int);
INSERT t VALUES (1, 1);
-- @step batch
BEGIN TRAN; UPDATE t SET v = 10 WHERE id = 1;
-- @step batch conn=2 async
SELECT v FROM t WHERE id = 1;
-- @step batch
UPDATE t SET v = 11 WHERE id = 1; COMMIT;
-- @step await conn=2
