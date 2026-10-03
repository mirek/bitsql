-- Classic deadlock: each transaction holds one row and wants the other's.
-- One session gets 1205 (transaction rolled back, batch aborted); the other
-- completes.
-- @step setup
CREATE TABLE a (id int PRIMARY KEY, v int);
CREATE TABLE b (id int PRIMARY KEY, v int);
INSERT a VALUES (1, 0); INSERT b VALUES (1, 0);
-- @step batch
BEGIN TRAN; UPDATE a SET v = 1 WHERE id = 1;
-- @step batch conn=2
BEGIN TRAN; UPDATE b SET v = 2 WHERE id = 1;
-- @step batch async
UPDATE b SET v = 1 WHERE id = 1; SELECT 'conn1 continues' AS r;
-- @step batch conn=2
UPDATE a SET v = 2 WHERE id = 1; SELECT 'conn2 continues' AS r;
-- @step await conn=1
-- @step batch
SELECT @@TRANCOUNT AS tc;
-- @step batch conn=2
SELECT @@TRANCOUNT AS tc;
IF @@TRANCOUNT > 0 COMMIT;
-- @step batch
IF @@TRANCOUNT > 0 COMMIT;
SELECT (SELECT v FROM a) AS a, (SELECT v FROM b) AS b;
