-- Completion of DML statements failing at run time: INFO 3621 follows
-- statement-terminating errors (also WHERE errors, which complete with the
-- DML CurCmd); batch-aborting errors (245, XACT_ABORT) complete with 253
-- unless an OUTPUT result set was already started.
-- @step setup
CREATE TABLE t(id INT PRIMARY KEY, n INT, v varchar(10));
INSERT INTO t VALUES(10,7,'a'),(20,8,'b');
-- @step batch
UPDATE t SET n=(SELECT id FROM t)
-- @step batch
DELETE t WHERE n/0=1
-- @step batch
INSERT INTO t(id,n) SELECT id+100, n/0 FROM t
-- @step batch
MERGE t USING (VALUES(10)) s(id) ON t.id=s.id WHEN MATCHED THEN UPDATE SET n=1/0;
-- @step batch
MERGE t USING (VALUES(10)) s(id) ON t.id=s.id WHEN MATCHED THEN UPDATE SET n=1/0 OUTPUT $action, inserted.id;
-- @step batch
UPDATE t SET n=n+2147483647
-- @step batch
DECLARE @t TABLE(a int); INSERT INTO @t VALUES(1/0)
-- @step batch
UPDATE t SET n=CAST(1e30 AS int) OUTPUT inserted.n; SELECT 1 AS after
-- @step batch
UPDATE t SET n=CAST('x' AS int); SELECT 1 AS not_reached
-- @step batch
INSERT INTO t(id,n) VALUES(30, CAST('x' AS int))
-- @step batch
INSERT INTO t(id,n) OUTPUT inserted.id VALUES(30, CAST('x' AS int))
-- @step batch
UPDATE t SET n=CAST('x' AS int) OUTPUT inserted.n
-- @step batch
DELETE t OUTPUT deleted.id WHERE CAST(v AS int)=1
-- @step batch
DELETE t WHERE CAST(v AS int)=1
-- @step batch
SET XACT_ABORT ON; UPDATE t SET n=1/0; SELECT 1 AS x
-- @step batch
SET XACT_ABORT ON; UPDATE t SET n=1/0 OUTPUT inserted.id; SELECT 1 AS x
-- @step batch
SET XACT_ABORT OFF; SELECT id, n, v FROM t ORDER BY id
